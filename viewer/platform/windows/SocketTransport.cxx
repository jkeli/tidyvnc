/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Windows established-socket transport (plans/native-ui-winui/CORE.md §5).
// The worker waits level-triggered with WSAPoll over the socket and a
// loopback wake socket, exactly like the POSIX poll + wake pipe. Readiness
// events (FD_READ/FD_WRITE) are not used for the worker: FD_WRITE is only
// re-posted after a send fails with WSAEWOULDBLOCK, which the select-guarded
// FdOutStream never provokes, so a blocked writer would sleep forever.
// The peer-closure observer uses WSAEventSelect(FD_CLOSE) alone: Winsock
// signals FD_CLOSE when the FIN arrives, even behind unread bytes, without
// the observer consuming or peeking at protocol data.
#include <viewer/platform/SocketTransport.h>
#include "WinIO.h"

#include <network/Socket.h>
#include <rdr/FdInStream.h>
#include <rdr/FdOutStream.h>
#include <atomic>
#include <stdexcept>

namespace viewer {
namespace {
using Clock = SessionTransport::Clock;
using TimePoint = SessionTransport::TimePoint;
using winio::failSocket;

struct State {
  explicit State(std::unique_ptr<network::Socket> socket_)
    : socket(std::move(socket_)), fd(socket ? static_cast<SOCKET>(socket->getFd()) : INVALID_SOCKET),
      closeEvent(true)
  {
    if (fd == INVALID_SOCKET) throw std::invalid_argument("Transport requires a socket");
    int type = 0, size = sizeof(type);
    if (::getsockopt(fd, SOL_SOCKET, SO_TYPE, reinterpret_cast<char*>(&type), &size) == SOCKET_ERROR)
      failSocket("transport socket type");
    if (type != SOCK_STREAM) throw std::invalid_argument("Transport requires a stream socket");
    sockaddr_storage peer;
    int length = sizeof(peer);
    if (::getpeername(fd, reinterpret_cast<sockaddr*>(&peer), &length) == SOCKET_ERROR)
      failSocket("transport connected peer");
    // Adopted sockets may come from code that did not use WSASocketW's
    // no-inherit flag; the SSH tunnel starts child processes.
    if (!::SetHandleInformation(reinterpret_cast<HANDLE>(fd), HANDLE_FLAG_INHERIT, 0))
      winio::failWin32("transport handle inheritance");
    // Also makes the socket nonblocking, as the POSIX adapter does.
    if (::WSAEventSelect(fd, closeEvent.value, FD_CLOSE) == SOCKET_ERROR)
      failSocket("transport close registration");
  }
  ~State()
  {
    ::WSAEventSelect(fd, nullptr, 0);
  }
  void cancel() noexcept
  {
    if (!cancelled.exchange(true)) ::shutdown(fd, SD_BOTH);
    workerWake.signal(); peerWake.signal();
  }
  void closed() noexcept
  {
    peerClosed.store(true);
    workerWake.signal();
  }
  std::unique_ptr<network::Socket> socket;
  const SOCKET fd;
  winio::Event closeEvent, peerWake;
  winio::WakeSocket workerWake;
  std::atomic<bool> cancelled{false};
  std::atomic<bool> peerClosed{false};
};

class Control final : public TransportControl {
public:
  explicit Control(const std::shared_ptr<State>& state_) : state(state_) {}
  void wake() noexcept override
  {
    if (auto live = state.lock()) live->workerWake.signal();
  }
  void cancel() noexcept override
  {
    if (auto live = state.lock()) live->cancel();
  }
private:
  std::weak_ptr<State> state;
};

class SocketTransport final : public SessionTransport {
public:
  explicit SocketTransport(std::unique_ptr<network::Socket> socket)
    : state(std::make_shared<State>(std::move(socket))),
      token(std::make_shared<Control>(state)) {}
  ~SocketTransport() override { state->cancel(); }
  rdr::InStream& input() override { return state->socket->inStream(); }
  rdr::OutStream& output() override { return state->socket->outStream(); }
  void flush() override { state->socket->outStream().flush(); }
  bool outputPending() override { return state->socket->outStream().hasBufferedData(); }
  std::shared_ptr<TransportControl> control() const override { return token; }

  TransportReady wait(TimePoint deadline, bool wantWrite) override
  {
    for (;;) {
      TransportReady result;
      if (state->cancelled.load()) { result.cancelled = true; return result; }
      WSAPOLLFD events[] = {{state->fd, static_cast<SHORT>(POLLRDNORM | (wantWrite ? POLLWRNORM : 0)), 0},
                            {state->workerWake.socket.value, POLLRDNORM, 0}};
      const int count = ::WSAPoll(events, 2, winio::pollTimeout(deadline));
      if (count == SOCKET_ERROR) {
        if (state->cancelled.load()) { result.cancelled = true; return result; }
        failSocket("transport wait");
      }
      if (events[0].revents & POLLNVAL) winio::fail("transport invalid socket", WSAENOTSOCK);
      result.readable = (events[0].revents & POLLRDNORM) != 0;
      result.writable = (events[0].revents & POLLWRNORM) != 0;
      result.peerClosed = state->peerClosed.load() || (events[0].revents & (POLLHUP | POLLERR));
      if (events[1].revents & POLLRDNORM) { state->workerWake.consume(); result.woken = true; }
      result.cancelled = state->cancelled.load();
      result.timedOut = !count && Clock::now() >= deadline;
      if (count || result.cancelled || result.timedOut) return result;
    }
  }

  TransportReady waitPeerClosure(TimePoint deadline) override
  {
    for (;;) {
      TransportReady result;
      if (state->cancelled.load()) { result.cancelled = true; return result; }
      if (state->peerClosed.load()) { result.peerClosed = true; return result; }
      HANDLE handles[] = {state->closeEvent.value, state->peerWake.value};
      const DWORD ready = ::WaitForMultipleObjects(2, handles, FALSE, winio::timeoutMillis(deadline));
      if (ready == WAIT_OBJECT_0) {
        WSANETWORKEVENTS events;
        if (::WSAEnumNetworkEvents(state->fd, state->closeEvent.value, &events) == SOCKET_ERROR) {
          if (!state->cancelled.load()) failSocket("transport peer events");
        } else if (events.lNetworkEvents & FD_CLOSE) {
          state->closed();
        }
      } else if (ready != WAIT_OBJECT_0 + 1 && ready != WAIT_TIMEOUT) {
        winio::failWin32("transport peer wait");
      }
      result.cancelled = state->cancelled.load();
      result.peerClosed = state->peerClosed.load();
      result.timedOut = !result.cancelled && !result.peerClosed && Clock::now() >= deadline;
      if (result.cancelled || result.peerClosed || result.timedOut) return result;
    }
  }
private:
  std::shared_ptr<State> state;
  std::shared_ptr<TransportControl> token;
};
}

std::unique_ptr<SessionTransport>
adoptSocketTransport(std::unique_ptr<network::Socket> socket)
{
  return std::unique_ptr<SessionTransport>(new SocketTransport(std::move(socket)));
}
}
