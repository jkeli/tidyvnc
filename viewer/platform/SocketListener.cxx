/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/platform/SocketListener.h>
#include <viewer/platform/SocketTransport.h>
#include <viewer/platform/detail/SocketIO.h>
#include <network/TcpSocket.h>
#include <array>
#include <atomic>
#include <cstring>
#include <arpa/inet.h>
#include <net/if.h>
#include <poll.h>
#include <sys/socket.h>
namespace viewer {
namespace {
struct State {
  detail::WakePipe wake;
  std::atomic<bool> cancelled{false};
  void check() const { if (cancelled.load()) throw ListenerError(ListenerErrorCode::Cancelled); }
};
class Control final : public TransportControl {
public:
  explicit Control(const std::shared_ptr<State>& live) : state(live) {}
  void wake() noexcept override { if (auto live = state.lock()) live->wake.signal(); }
  void cancel() noexcept override { if (auto live = state.lock()) { live->cancelled.store(true); live->wake.signal(); } }
private:
  std::weak_ptr<State> state;
};
ListenerAddress describe(const sockaddr_storage& address)
{
  char buffer[INET6_ADDRSTRLEN]; ListenerAddress result;
  if (address.ss_family == AF_INET) {
    const auto& v4 = reinterpret_cast<const sockaddr_in&>(address);
    if (!inet_ntop(AF_INET,&v4.sin_addr,buffer,sizeof(buffer))) detail::fail("listener address");
    result.host = buffer; result.port = ntohs(v4.sin_port);
  } else {
    const auto& v6 = reinterpret_cast<const sockaddr_in6&>(address);
    if (!inet_ntop(AF_INET6,&v6.sin6_addr,buffer,sizeof(buffer))) detail::fail("listener address");
    result.host = buffer; result.port = ntohs(v6.sin6_port);
    if (v6.sin6_scope_id) result.host += "%" + std::to_string(v6.sin6_scope_id);
  }
  return result;
}
class Source final : public ListenerSource {
public:
  explicit Source(SocketListenOptions options_) : options(std::move(options_)), state(new State), token(new Control(state)) {
    if ((!options.ipv4 && !options.ipv6) || !options.backlog || options.backlog > 64 || options.address.size() > 255 ||
        options.address.find('\0') != std::string::npos)
      throw std::invalid_argument("Invalid listener options");
    if (!options.address.empty()) {
      sockaddr_storage storage{};
      if (inet_pton(AF_INET,options.address.c_str(),&reinterpret_cast<sockaddr_in&>(storage).sin_addr) == 1) family = AF_INET;
      else if (inet_pton(AF_INET6,options.address.c_str(),&reinterpret_cast<sockaddr_in6&>(storage).sin6_addr) == 1) family = AF_INET6;
      else throw std::invalid_argument("Listener address must be numeric IPv4 or IPv6");
      if ((family == AF_INET && !options.ipv4) || (family == AF_INET6 && !options.ipv6))
        throw std::invalid_argument("Listener address family disabled");
    }
  }
  std::shared_ptr<TransportControl> control() const override { return token; }
  std::vector<ListenerAddress> start() override {
    if (started) throw std::logic_error("Listener source already started");
    started = true;
    try {
      state->check(); std::vector<ListenerAddress> addresses; addresses.reserve(2);
      uint16_t port = options.port;
      int unavailable = EAFNOSUPPORT;
      for (int current : {AF_INET,AF_INET6}) {
        if ((family && family != current) || (current == AF_INET ? !options.ipv4 : !options.ipv6)) continue;
        auto& fd = sockets[count];
        try {
          fd.value = ::socket(current,SOCK_STREAM,0);
          if (fd.value < 0) detail::fail("listener socket");
          detail::configure(fd.value,true); int one = 1;
          if (::setsockopt(fd.value,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one)) < 0) detail::fail("listener reuse");
          if (current == AF_INET6 && ::setsockopt(fd.value,IPPROTO_IPV6,IPV6_V6ONLY,&one,sizeof(one)) < 0)
            detail::fail("listener IPv6 isolation");
          sockaddr_storage address{}; socklen_t length;
          if (current == AF_INET) {
            auto& v4 = reinterpret_cast<sockaddr_in&>(address);
            v4.sin_family = AF_INET; v4.sin_port = htons(port); length = sizeof(v4);
            if (family) inet_pton(AF_INET,options.address.c_str(),&v4.sin_addr);
          } else {
            auto& v6 = reinterpret_cast<sockaddr_in6&>(address);
            v6.sin6_family = AF_INET6; v6.sin6_port = htons(port); length = sizeof(v6);
            if (family) inet_pton(AF_INET6,options.address.c_str(),&v6.sin6_addr);
          }
          state->check();
          if (::bind(fd.value,reinterpret_cast<sockaddr*>(&address),length) < 0) detail::fail("listener bind");
          if (::listen(fd.value,options.backlog) < 0) detail::fail("listener listen");
          if (::getsockname(fd.value,reinterpret_cast<sockaddr*>(&address),&length) < 0) detail::fail("listener endpoint");
          auto endpoint = describe(address); port = endpoint.port;
          addresses.push_back(std::move(endpoint)); ++count;
        } catch (const std::system_error& error) {
          if (error.code().value() != EAFNOSUPPORT && error.code().value() != EADDRNOTAVAIL) throw;
          unavailable = error.code().value();
          if (fd.value >= 0) { ::close(fd.value); fd.value = -1; }
        }
      }
      if (!count) throw ListenerError(ListenerErrorCode::Bind,unavailable);
      state->check(); return addresses;
    } catch (const std::system_error& error) {
      closeSockets(); throw ListenerError(ListenerErrorCode::Bind,error.code().value());
    } catch (...) { closeSockets(); throw; }
  }
  std::unique_ptr<IncomingTransport> wait(SessionTransport::TimePoint deadline) override {
    if (!started || !count) throw std::logic_error("Listener source is not listening");
    try {
      for (;;) {
        state->check();
        pollfd events[3] = {{state->wake.read.value,POLLIN,0},{sockets[0].value,POLLIN,0},{sockets[1].value,POLLIN,0}};
        const auto ready = ::poll(events,count+1,detail::timeoutMillis(deadline));
        if (ready < 0) { if (errno == EINTR) continue; detail::fail("listener wait"); }
        state->check();
        if (events[0].revents & POLLIN) { state->wake.consume(); return {}; }
        if (!ready) return {};
        for (size_t n = 0; n < count; ++n) {
          const size_t i = (next + n) % count;
          if (events[i+1].revents & (POLLERR|POLLHUP|POLLNVAL)) detail::fail("listener readiness",EIO);
          if (!(events[i+1].revents & POLLIN)) continue;
          sockaddr_storage address{}; socklen_t length = sizeof(address);
          detail::Descriptor peer(::accept(sockets[i].value,reinterpret_cast<sockaddr*>(&address),&length));
          if (peer.value < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR || errno == ECONNABORTED) continue;
            detail::fail("listener accept");
          }
          next = (i+1)%count; state->check(); detail::configure(peer.value,true);
          std::unique_ptr<IncomingTransport> incoming(new IncomingTransport);
          incoming->peer = describe(address);
          std::unique_ptr<network::Socket> socket(new network::TcpSocket(peer.value)); peer.value = -1;
          incoming->transport = adoptSocketTransport(std::move(socket)); state->check(); return incoming;
        }
        if (SessionTransport::Clock::now() >= deadline) return {};
      }
    } catch (const std::system_error& error) { throw ListenerError(ListenerErrorCode::Accept,error.code().value()); }
  }
private:
  void closeSockets() noexcept { for (auto& fd : sockets) if (fd.value >= 0) { ::close(fd.value); fd.value = -1; } count = 0; }
  const SocketListenOptions options;
  std::shared_ptr<State> state;
  std::shared_ptr<TransportControl> token;
  std::array<detail::Descriptor,2> sockets;
  size_t count = 0, next = 0;
  int family = 0;
  bool started = false;
};
}
std::unique_ptr<ListenerSource> prepareSocketListener(const SocketListenOptions& options)
{ return std::unique_ptr<ListenerSource>(new Source(options)); }
}
