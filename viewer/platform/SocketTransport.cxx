/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/platform/SocketTransport.h>
#include <viewer/platform/detail/SocketIO.h>

#include <network/Socket.h>
#include <rdr/FdInStream.h>
#include <rdr/FdOutStream.h>
#include <atomic>
#include <cerrno>
#include <climits>
#include <stdexcept>
#include <system_error>
#include <fcntl.h>
#include <poll.h>
#include <sys/select.h>
#include <sys/socket.h>
#ifdef __APPLE__
#include <sys/event.h>
#endif
#include <unistd.h>

namespace viewer {
namespace {
using Clock = SessionTransport::Clock;
using TimePoint = SessionTransport::TimePoint;

using detail::Descriptor;
using detail::WakePipe;
using detail::configure;
using detail::fail;
using detail::timeoutMillis;

struct State {
  explicit State(std::unique_ptr<network::Socket> socket_)
    : socket(std::move(socket_)), fd(socket ? socket->getFd() : -1)
  {
    // Legacy FdStreams use select internally even though our reactor uses poll.
    if (fd < 0 || fd >= FD_SETSIZE)
      throw std::invalid_argument("Transport socket exceeds stream descriptor range");
    int type;
    socklen_t size = sizeof(type);
    if (::getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) < 0)
      fail("transport socket type");
    if (type != SOCK_STREAM)
      throw std::invalid_argument("Transport requires a stream socket");
    sockaddr_storage peer;
    size = sizeof(peer);
    if (::getpeername(fd, reinterpret_cast<sockaddr*>(&peer), &size) < 0)
      fail("transport connected peer");
    configure(fd, true);
#ifdef SO_NOSIGPIPE
    const int one = 1;
    if (::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) < 0)
      fail("transport suppress broken pipe");
#endif
#ifdef __APPLE__
    queue.value = ::kqueue();
    if (queue.value < 0) fail("transport peer queue");
    configure(queue.value, false);
    struct kevent changes[2];
    // Edge delivery is essential: unread prompt-era data must not make the
    // observer spin, and FIN must still be visible behind those unread bytes.
    EV_SET(&changes[0], fd, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, nullptr);
    EV_SET(&changes[1], peerWake.read.value, EVFILT_READ, EV_ADD, 0, 0, nullptr);
    if (::kevent(queue.value, changes, 2, nullptr, 0, nullptr) < 0)
      fail("transport peer registration");
#endif
  }
  void cancel() noexcept
  {
    if (!cancelled.exchange(true)) ::shutdown(fd, SHUT_RDWR);
    workerWake.signal(); peerWake.signal();
  }
  void closed() noexcept
  {
    peerClosed.store(true);
    workerWake.signal();
  }
  std::unique_ptr<network::Socket> socket;
  const int fd;
  WakePipe workerWake, peerWake;
#ifdef __APPLE__
  Descriptor queue;
#endif
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
      short interest = POLLIN;
      if (wantWrite) interest |= POLLOUT;
#ifdef POLLRDHUP
      interest |= POLLRDHUP;
#endif
      pollfd events[] = {{state->fd, interest, 0},
                        {state->workerWake.read.value, POLLIN, 0}};
      int count = ::poll(events, 2, timeoutMillis(deadline));
      if (count < 0) { if (errno == EINTR) continue; fail("transport wait"); }
      if (events[0].revents & POLLNVAL) fail("transport invalid socket", EBADF);
      result.readable = events[0].revents & POLLIN;
      result.writable = events[0].revents & POLLOUT;
      short closed = POLLHUP | POLLERR;
#ifdef POLLRDHUP
      closed |= POLLRDHUP;
#endif
      result.peerClosed = state->peerClosed.load() || (events[0].revents & closed);
      if (events[1].revents & POLLIN) {
        state->workerWake.consume(); result.woken = true;
      }
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
#ifdef __APPLE__
      timespec timeout;
      timespec* timeoutPointer = nullptr;
      if (deadline != TimePoint::max()) {
        const auto now = Clock::now();
        const auto left = deadline <= now ? Clock::duration::zero() : deadline - now;
        const auto seconds = std::chrono::duration_cast<std::chrono::seconds>(left);
        timeout.tv_sec = seconds.count();
        timeout.tv_nsec = std::chrono::duration_cast<std::chrono::nanoseconds>(left - seconds).count();
        timeoutPointer = &timeout;
      }
      struct kevent events[2];
      int count = ::kevent(state->queue.value, nullptr, 0, events, 2, timeoutPointer);
      if (count < 0) { if (errno == EINTR) continue; fail("transport peer wait"); }
      for (int i = 0; i < count; ++i) {
        if (events[i].flags & EV_ERROR) fail("transport peer event", events[i].data);
        if (events[i].ident == static_cast<uintptr_t>(state->fd) &&
            (events[i].flags & EV_EOF)) state->closed();
      }
#else
      pollfd events[] = {{state->fd, POLLRDHUP, 0},
                        {state->peerWake.read.value, POLLIN, 0}};
      int count = ::poll(events, 2, timeoutMillis(deadline));
      if (count < 0) { if (errno == EINTR) continue; fail("transport peer wait"); }
      if (events[0].revents & POLLNVAL) fail("transport invalid peer socket", EBADF);
      if (events[0].revents & (POLLRDHUP | POLLHUP | POLLERR)) state->closed();
#endif
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
