/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Windows reverse-connection listener (plans/native-ui-winui/CORE.md §5).
// SO_EXCLUSIVEADDRUSE instead of SO_REUSEADDR (which on Windows would let
// another process steal the port), IPV6_V6ONLY for separate family sockets,
// and FD_ACCEPT events waited together with the control's wake event.
#include <viewer/platform/SocketListener.h>
#include <viewer/platform/SocketTransport.h>
#include "WinIO.h"

#include <network/TcpSocket.h>
#include <array>
#include <atomic>
#include <cstring>

namespace viewer {
namespace {
struct State {
  winio::Event wake;
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
    if (!inet_ntop(AF_INET,&v4.sin_addr,buffer,sizeof(buffer))) winio::failSocket("listener address");
    result.host = buffer; result.port = ntohs(v4.sin_port);
  } else {
    const auto& v6 = reinterpret_cast<const sockaddr_in6&>(address);
    if (!inet_ntop(AF_INET6,&v6.sin6_addr,buffer,sizeof(buffer))) winio::failSocket("listener address");
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
  ~Source() override { closeSockets(); }
  std::shared_ptr<TransportControl> control() const override { return token; }
  std::vector<ListenerAddress> start() override {
    if (started) throw std::logic_error("Listener source already started");
    started = true;
    try {
      state->check(); std::vector<ListenerAddress> addresses; addresses.reserve(2);
      uint16_t port = options.port;
      int unavailable = WSAEAFNOSUPPORT;
      for (int current : {AF_INET,AF_INET6}) {
        if ((family && family != current) || (current == AF_INET ? !options.ipv4 : !options.ipv6)) continue;
        auto& socket = sockets[count];
        try {
          socket.value = winio::openSocket(current,SOCK_STREAM,IPPROTO_TCP);
          const BOOL one = TRUE;
          if (::setsockopt(socket.value,SOL_SOCKET,SO_EXCLUSIVEADDRUSE,reinterpret_cast<const char*>(&one),sizeof(one)) == SOCKET_ERROR)
            winio::failSocket("listener exclusive address");
          if (current == AF_INET6 &&
              ::setsockopt(socket.value,IPPROTO_IPV6,IPV6_V6ONLY,reinterpret_cast<const char*>(&one),sizeof(one)) == SOCKET_ERROR)
            winio::failSocket("listener IPv6 isolation");
          sockaddr_storage address{}; int length;
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
          if (::bind(socket.value,reinterpret_cast<sockaddr*>(&address),length) == SOCKET_ERROR) winio::failSocket("listener bind");
          if (::listen(socket.value,static_cast<int>(options.backlog)) == SOCKET_ERROR) winio::failSocket("listener listen");
          if (::getsockname(socket.value,reinterpret_cast<sockaddr*>(&address),&length) == SOCKET_ERROR) winio::failSocket("listener endpoint");
          if (::WSAEventSelect(socket.value,accepts[count].value,FD_ACCEPT) == SOCKET_ERROR) winio::failSocket("listener events");
          auto endpoint = describe(address); port = endpoint.port;
          addresses.push_back(std::move(endpoint)); ++count;
        } catch (const std::system_error& error) {
          if (error.code().value() != WSAEAFNOSUPPORT && error.code().value() != WSAEADDRNOTAVAIL) throw;
          unavailable = error.code().value();
          socket.reset();
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
        // Accept is attempted on every socket each round (round-robin start),
        // so an FD_ACCEPT record consumed earlier cannot strand a peer.
        for (size_t n = 0; n < count; ++n) {
          const size_t i = (next + n) % count;
          WSANETWORKEVENTS events;
          if (::WSAEnumNetworkEvents(sockets[i].value,accepts[i].value,&events) == SOCKET_ERROR)
            winio::failSocket("listener readiness");
          if ((events.lNetworkEvents & FD_ACCEPT) && events.iErrorCode[FD_ACCEPT_BIT])
            winio::fail("listener readiness",events.iErrorCode[FD_ACCEPT_BIT]);
          sockaddr_storage address{}; int length = sizeof(address);
          winio::Socket peer(::accept(sockets[i].value,reinterpret_cast<sockaddr*>(&address),&length));
          if (peer.value == INVALID_SOCKET) {
            const int error = ::WSAGetLastError();
            if (error == WSAEWOULDBLOCK || error == WSAECONNRESET || error == WSAEINTR) continue;
            winio::fail("listener accept",error);
          }
          next = (i+1)%count; state->check();
          // Accepted sockets inherit the listener's event association; the
          // transport replaces it with its own.
          if (::WSAEventSelect(peer.value,nullptr,0) == SOCKET_ERROR) winio::failSocket("listener peer events");
          if (!::SetHandleInformation(reinterpret_cast<HANDLE>(peer.value),HANDLE_FLAG_INHERIT,0))
            winio::failWin32("listener peer inheritance");
          std::unique_ptr<IncomingTransport> incoming(new IncomingTransport);
          incoming->peer = describe(address);
          std::unique_ptr<network::Socket> socket(new network::TcpSocket(winio::sharedDescriptor(peer.value)));
          peer.release();
          incoming->transport = adoptSocketTransport(std::move(socket)); state->check(); return incoming;
        }
        HANDLE handles[3] = {state->wake.value,accepts[0].value,accepts[1].value};
        const DWORD ready = ::WaitForMultipleObjects(static_cast<DWORD>(count+1),handles,FALSE,winio::timeoutMillis(deadline));
        state->check();
        if (ready == WAIT_OBJECT_0) return {};
        if (ready == WAIT_TIMEOUT) { if (SessionTransport::Clock::now() >= deadline) return {}; continue; }
        if (ready > WAIT_OBJECT_0 + count) winio::failWin32("listener wait");
      }
    } catch (const std::system_error& error) { throw ListenerError(ListenerErrorCode::Accept,error.code().value()); }
  }
private:
  void closeSockets() noexcept {
    for (size_t i = 0; i < sockets.size(); ++i) {
      if (sockets[i].value != INVALID_SOCKET) ::WSAEventSelect(sockets[i].value,nullptr,0);
      sockets[i].reset();
    }
    count = 0;
  }
  const SocketListenOptions options;
  std::shared_ptr<State> state;
  std::shared_ptr<TransportControl> token;
  std::array<winio::Socket,2> sockets;
  std::array<winio::Event,2> accepts{{winio::Event(true),winio::Event(true)}};
  size_t count = 0, next = 0;
  int family = 0;
  bool started = false;
};
}
std::unique_ptr<ListenerSource> prepareSocketListener(const SocketListenOptions& options)
{ return std::unique_ptr<ListenerSource>(new Source(options)); }
}
