/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Windows established-socket transport (plans/native-ui-winui/CORE.md §5).
// One manual-reset network event is associated with the socket through
// WSAEventSelect(FD_READ | FD_WRITE | FD_CLOSE). Winsock allows one such
// association per socket, but the worker and the peer-closure observer wait
// independently, so whichever waiter wakes on the network event "pumps" it
// (WSAEnumNetworkEvents, which also resets it), records FD_CLOSE as sticky
// peer closure and fans the change out to both waiters' own events. Readiness
// itself is always taken level-triggered from a zero-timeout select(), so a
// record consumed by the other waiter can never hide readable data.
#include <viewer/platform/SocketTransport.h>
#include "WinIO.h"

#include <network/Socket.h>
#include <rdr/FdInStream.h>
#include <rdr/FdOutStream.h>
#include <atomic>
#include <mutex>
#include <stdexcept>

namespace viewer {
namespace {
using Clock = SessionTransport::Clock;
using TimePoint = SessionTransport::TimePoint;
using winio::Event;
using winio::failSocket;

struct State {
  explicit State(std::unique_ptr<network::Socket> socket_)
    : socket(std::move(socket_)), fd(socket ? static_cast<SOCKET>(socket->getFd()) : INVALID_SOCKET),
      network(true), workerNetwork(true), peerNetwork(true)
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
    if (::WSAEventSelect(fd, network.value, FD_READ | FD_WRITE | FD_CLOSE) == SOCKET_ERROR)
      failSocket("transport event registration");
  }
  ~State()
  {
    // Drop the association before the socket closes with the stream objects.
    ::WSAEventSelect(fd, nullptr, 0);
  }
  void cancel() noexcept
  {
    if (!cancelled.exchange(true)) ::shutdown(fd, SD_BOTH);
    workerWake.signal(); peerWake.signal();
  }
  // Either waiter; serialised so records are consumed exactly once.
  void pump()
  {
    std::lock_guard<std::mutex> lock(pumpMutex);
    WSANETWORKEVENTS events;
    if (::WSAEnumNetworkEvents(fd, network.value, &events) == SOCKET_ERROR) {
      if (cancelled.load()) { workerNetwork.signal(); peerNetwork.signal(); return; }
      failSocket("transport network events");
    }
    if (events.lNetworkEvents & FD_CLOSE) peerClosed.store(true);
    workerNetwork.signal(); peerNetwork.signal();
  }
  // Level-triggered readiness; never consumes or peeks at protocol bytes.
  void level(bool wantWrite, bool& readable, bool& writable, bool& failed)
  {
    fd_set read, write, error;
    FD_ZERO(&read); FD_ZERO(&write); FD_ZERO(&error);
    FD_SET(fd, &read); FD_SET(fd, &error);
    if (wantWrite) FD_SET(fd, &write);
    timeval zero = {0, 0};
    const int count = ::select(0, &read, wantWrite ? &write : nullptr, &error, &zero);
    if (count == SOCKET_ERROR) {
      if (cancelled.load()) { readable = writable = failed = false; return; }
      failSocket("transport wait");
    }
    readable = FD_ISSET(fd, &read) != 0;
    writable = wantWrite && FD_ISSET(fd, &write) != 0;
    failed = FD_ISSET(fd, &error) != 0;
  }
  std::unique_ptr<network::Socket> socket;
  const SOCKET fd;
  Event network, workerNetwork, peerNetwork, workerWake, peerWake;
  std::mutex pumpMutex;
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
      // Reset before sampling: a pump by the observer after this point
      // re-signals it, so the wait below cannot miss a change.
      state->workerNetwork.reset();
      bool failed = false;
      state->level(wantWrite, result.readable, result.writable, failed);
      result.peerClosed = state->peerClosed.load() || failed;
      result.cancelled = state->cancelled.load();
      if (result.readable || result.writable || result.peerClosed || result.cancelled) return result;
      HANDLE handles[] = {state->network.value, state->workerNetwork.value, state->workerWake.value};
      const DWORD ready = ::WaitForMultipleObjects(3, handles, FALSE, winio::timeoutMillis(deadline));
      if (ready == WAIT_OBJECT_0) { state->pump(); continue; }
      if (ready == WAIT_OBJECT_0 + 1) continue;
      if (ready == WAIT_OBJECT_0 + 2) {
        result.woken = true;
        state->level(wantWrite, result.readable, result.writable, failed);
        result.peerClosed = state->peerClosed.load() || failed;
        result.cancelled = state->cancelled.load();
        return result;
      }
      if (ready == WAIT_TIMEOUT) {
        if (Clock::now() < deadline) continue;
        result.timedOut = true; result.cancelled = state->cancelled.load();
        return result;
      }
      winio::failWin32("transport wait");
    }
  }

  TransportReady waitPeerClosure(TimePoint deadline) override
  {
    for (;;) {
      TransportReady result;
      if (state->cancelled.load()) { result.cancelled = true; return result; }
      if (state->peerClosed.load()) { result.peerClosed = true; return result; }
      state->peerNetwork.reset();
      if (state->peerClosed.load()) { result.peerClosed = true; return result; }
      HANDLE handles[] = {state->network.value, state->peerNetwork.value, state->peerWake.value};
      const DWORD ready = ::WaitForMultipleObjects(3, handles, FALSE, winio::timeoutMillis(deadline));
      if (ready == WAIT_OBJECT_0) state->pump();
      else if (ready == WAIT_TIMEOUT) {
        result.cancelled = state->cancelled.load();
        result.peerClosed = state->peerClosed.load();
        result.timedOut = !result.cancelled && !result.peerClosed && Clock::now() >= deadline;
        if (result.cancelled || result.peerClosed || result.timedOut) return result;
      } else if (ready != WAIT_OBJECT_0 + 1 && ready != WAIT_OBJECT_0 + 2) {
        winio::failWin32("transport peer wait");
      }
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
