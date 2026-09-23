/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Windows connection attempts (plans/native-ui-winui/CORE.md §5): cancellable
// GetAddrInfoExW lookups, nonblocking connects completed through FD_CONNECT,
// IPv4/IPv6 policy through hints, numeric scope IDs and AF_UNIX endpoints
// (DECISIONS.md D18). Native error values are Winsock/Win32 codes.
#include <viewer/platform/SocketConnector.h>
#include <viewer/platform/SocketTransport.h>
#include "WinIO.h"

#include <network/TcpSocket.h>
#include <afunix.h>
#include <iphlpapi.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>

namespace viewer {
namespace {
using Clock = SessionTransport::Clock;
using TimePoint = SessionTransport::TimePoint;
struct Address { sockaddr_storage storage{}; int length = 0; };
struct Addresses { std::array<Address, 16> values; size_t count = 0; };

struct State {
  winio::Event wake;
  std::atomic<bool> cancelled{false}, started{false};
  void check(ConnectionPhase phase) const {
    if (cancelled.load()) throw ConnectionError(ConnectionErrorCode::Cancelled, phase);
  }
  // Returns the index of the signalled handle (after the wake event), or
  // throws on cancellation and deadline expiry.
  size_t wait(HANDLE handle, TimePoint deadline, ConnectionPhase phase) {
    for (;;) {
      check(phase);
      if (Clock::now() >= deadline) throw ConnectionError(ConnectionErrorCode::TimedOut, phase, WSAETIMEDOUT);
      HANDLE handles[] = {wake.value, handle};
      const DWORD ready = ::WaitForMultipleObjects(2, handles, FALSE, winio::timeoutMillis(deadline));
      check(phase);
      if (ready == WAIT_OBJECT_0 + 1) return 1;
      if (ready == WAIT_OBJECT_0 || ready == WAIT_TIMEOUT) continue;
      winio::failWin32("connection wait");
    }
  }
};

class Control final : public TransportControl {
public:
  explicit Control(const std::shared_ptr<State>& state_) : state(state_) {}
  void wake() noexcept override { if (auto live = state.lock()) live->wake.signal(); }
  void cancel() noexcept override {
    if (auto live = state.lock()) { live->cancelled.store(true); live->wake.signal(); }
  }
private:
  std::weak_ptr<State> state;
};

uint32_t scopeIndex(const std::string& scope)
{
  if (scope.empty()) return 0;
  uint32_t value = 0;
  const bool numeric = std::all_of(scope.begin(), scope.end(), [](char c) { return c >= '0' && c <= '9'; });
  if (!numeric) {
    // Windows interface names (the NDIS alias, e.g. "ethernet_32769").
    value = ::if_nametoindex(scope.c_str());
    if (!value) throw ConnectionError(ConnectionErrorCode::InvalidAddress, ConnectionPhase::Connecting, ERROR_NOT_FOUND);
    return value;
  }
  for (char c : scope) {
    if (value > (std::numeric_limits<uint32_t>::max() - static_cast<uint32_t>(c - '0')) / 10)
      throw ConnectionError(ConnectionErrorCode::InvalidAddress, ConnectionPhase::Connecting, WSAEINVAL);
    value = value * 10 + static_cast<uint32_t>(c - '0');
  }
  return value;
}

bool literal(const Endpoint& endpoint, const SocketConnectOptions& options, Addresses& out)
{
  Address address;
  auto* v4 = reinterpret_cast<sockaddr_in*>(&address.storage);
  if (::inet_pton(AF_INET, endpoint.host().c_str(), &v4->sin_addr) == 1) {
    if (!options.ipv4 || !endpoint.scope().empty())
      throw ConnectionError(ConnectionErrorCode::InvalidAddress, ConnectionPhase::Connecting, WSAEAFNOSUPPORT);
    v4->sin_family = AF_INET; v4->sin_port = htons(endpoint.port()); address.length = sizeof(*v4);
  } else {
    auto* v6 = reinterpret_cast<sockaddr_in6*>(&address.storage);
    if (::inet_pton(AF_INET6, endpoint.host().c_str(), &v6->sin6_addr) != 1) return false;
    if (!options.ipv6) throw ConnectionError(ConnectionErrorCode::InvalidAddress, ConnectionPhase::Connecting, WSAEAFNOSUPPORT);
    v6->sin6_family = AF_INET6; v6->sin6_port = htons(endpoint.port());
    v6->sin6_scope_id = scopeIndex(endpoint.scope()); address.length = sizeof(*v6);
  }
  out.values[out.count++] = address; return true;
}

// Asynchronous lookup shared with the system's completion callback. After an
// abandoned (cancelled or expired) lookup, whichever side finishes last frees
// it, so run() returns promptly without waiting for the resolver.
struct Lookup {
  ~Lookup() { if (result) ::FreeAddrInfoExW(result); }
  std::wstring name;
  ADDRINFOEXW hints{};
  ADDRINFOEXW* result = nullptr;
  HANDLE cancel = nullptr;
  std::atomic<int> error{WSA_IO_PENDING};
  winio::Event completed{true};
};
struct Pending {
  OVERLAPPED overlapped{};
  std::shared_ptr<Lookup> lookup;
};
void CALLBACK resolved(DWORD error, DWORD, LPWSAOVERLAPPED overlapped) noexcept
{
  std::unique_ptr<Pending> pending(CONTAINING_RECORD(overlapped, Pending, overlapped));
  pending->lookup->error.store(static_cast<int>(error));
  pending->lookup->completed.signal();
}

void collect(const ADDRINFOEXW* list, uint16_t port, Addresses& output)
{
  for (auto* entry = list; entry && output.count < output.values.size(); entry = entry->ai_next) {
    if ((entry->ai_family != AF_INET && entry->ai_family != AF_INET6) || !entry->ai_addr ||
        entry->ai_addrlen > sizeof(sockaddr_storage)) continue;
    Address next;
    std::memcpy(&next.storage, entry->ai_addr, entry->ai_addrlen);
    next.length = static_cast<int>(entry->ai_addrlen);
    if (entry->ai_family == AF_INET) reinterpret_cast<sockaddr_in*>(&next.storage)->sin_port = htons(port);
    else reinterpret_cast<sockaddr_in6*>(&next.storage)->sin6_port = htons(port);
    output.values[output.count++] = next;
  }
}

void resolve(State& state, const Endpoint& endpoint, const SocketConnectOptions& options, Addresses& output)
{
  network::initSockets();
  const auto deadline = Clock::now() + options.resolveTimeout;
  auto lookup = std::make_shared<Lookup>();
  try { lookup->name = winio::widen(endpoint.host()); }
  catch (const std::invalid_argument&) {
    throw ConnectionError(ConnectionErrorCode::InvalidAddress, ConnectionPhase::Resolving, WSAEINVAL);
  }
  lookup->hints.ai_family = options.ipv4 && options.ipv6 ? AF_UNSPEC : options.ipv4 ? AF_INET : AF_INET6;
  lookup->hints.ai_socktype = SOCK_STREAM;
  lookup->hints.ai_protocol = IPPROTO_TCP;
  std::unique_ptr<Pending> pending(new Pending);
  pending->lookup = lookup;
  state.check(ConnectionPhase::Resolving);
  const INT started = ::GetAddrInfoExW(lookup->name.c_str(), nullptr, NS_ALL, nullptr, &lookup->hints,
                                       &lookup->result, nullptr, &pending->overlapped, resolved,
                                       &lookup->cancel);
  if (started != WSA_IO_PENDING) {
    // Completed (or failed) synchronously: the callback will not run.
    if (started != NO_ERROR) throw ConnectionError(ConnectionErrorCode::Resolution, ConnectionPhase::Resolving, started);
  } else {
    // From here only resolved() releases the pending holder.
    pending.release();
    try { state.wait(lookup->completed.value, deadline, ConnectionPhase::Resolving); }
    catch (...) {
      ::GetAddrInfoExCancel(&lookup->cancel);
      throw;
    }
    const int error = lookup->error.load();
    state.check(ConnectionPhase::Resolving);
    if (error != NO_ERROR) throw ConnectionError(ConnectionErrorCode::Resolution, ConnectionPhase::Resolving, error);
  }
  collect(lookup->result, endpoint.port(), output);
  if (!output.count) throw ConnectionError(ConnectionErrorCode::Resolution, ConnectionPhase::Resolving, WSAHOST_NOT_FOUND);
}

class LocalSocket final : public network::Socket {
public:
  LocalSocket(int fd, std::string path_) : Socket(fd), path(std::move(path_)) {}
  const char* getPeerAddress() override { return path.c_str(); }
  const char* getPeerEndpoint() override { return path.c_str(); }
private:
  const std::string path;
};

class Connector final : public ConnectionAttempt {
public:
  Connector(const Endpoint& endpoint_, const Endpoint& identity_, const SocketConnectOptions& options_)
    : endpoint(endpoint_), identity(identity_), options(options_), state(std::make_shared<State>()),
      token(std::make_shared<Control>(state))
  {
    for (auto timeout : {options.resolveTimeout, options.connectTimeout, options.addressTimeout})
      if (timeout.count() < 1 || timeout > std::chrono::seconds(60))
        throw std::invalid_argument("Invalid connection timeout");
    if (endpoint.transport() == EndpointTransport::Tcp && !options.ipv4 && !options.ipv6)
      throw std::invalid_argument("No connection address family enabled");
  }
  std::string serverName() const override { return identity.transport() == EndpointTransport::Tcp ? identity.host() : identity.path(); }
  std::shared_ptr<TransportControl> control() const override { return token; }
  std::unique_ptr<SessionTransport> run(const Progress& progress) override
  {
    if (state->started.exchange(true)) throw std::logic_error("Connection attempt already started");
    ConnectionPhase phase = ConnectionPhase::Connecting;
    try {
      state->check(phase);
      if (!endpoint.route().empty()) throw ConnectionError(ConnectionErrorCode::Unsupported, phase);
      Addresses addresses;
      if (endpoint.transport() == EndpointTransport::UnixSocket) {
        Address address;
        auto* local = reinterpret_cast<SOCKADDR_UN*>(&address.storage);
        // AF_UNIX paths are narrow; Windows interprets them in the ANSI code
        // page, so only ASCII paths are accepted (a stated D18 limit).
        const auto& path = endpoint.path();
        if (path.size() >= sizeof(local->sun_path))
          throw ConnectionError(ConnectionErrorCode::InvalidAddress, phase, WSAENAMETOOLONG);
        if (std::any_of(path.begin(), path.end(), [](char c) { return static_cast<unsigned char>(c) >= 0x80; }))
          throw ConnectionError(ConnectionErrorCode::InvalidAddress, phase, WSAEINVAL);
        local->sun_family = AF_UNIX;
        std::memcpy(local->sun_path, path.c_str(), path.size() + 1);
        address.length = static_cast<int>(sizeof(SOCKADDR_UN));
        addresses.values[addresses.count++] = address;
      } else if (!literal(endpoint, options, addresses)) {
        phase = ConnectionPhase::Resolving;
        if (progress) progress(phase);
        state->check(phase);
        if (!endpoint.scope().empty()) throw ConnectionError(ConnectionErrorCode::InvalidAddress, phase);
        resolve(*state, endpoint, options, addresses);
      }
      phase = ConnectionPhase::Connecting;
      state->check(phase);
      if (progress) progress(phase);
      const auto deadline = Clock::now() + options.connectTimeout;
      int lastError = WSAECONNREFUSED;
      for (size_t i = 0; i < addresses.count; ++i) {
        state->check(phase);
        if (Clock::now() >= deadline) throw ConnectionError(ConnectionErrorCode::TimedOut, phase, WSAETIMEDOUT);
        const auto& address = addresses.values[i];
        const int family = address.storage.ss_family;
        winio::Socket socket;
        try { socket.value = winio::openSocket(family, SOCK_STREAM, family == AF_UNIX ? 0 : IPPROTO_TCP); }
        catch (const std::system_error& error) { lastError = error.code().value(); continue; }
        winio::Event connected(true);
        if (::WSAEventSelect(socket.value, connected.value, FD_CONNECT) == SOCKET_ERROR)
          winio::failSocket("connect event registration");
        int error = 0;
        if (::connect(socket.value, reinterpret_cast<const sockaddr*>(&address.storage), address.length) == SOCKET_ERROR)
          error = ::WSAGetLastError();
        if (error == WSAEWOULDBLOCK) {
          try { state->wait(connected.value, std::min(deadline, Clock::now() + options.addressTimeout), phase); }
          catch (const ConnectionError& waitError) {
            if (waitError.code != ConnectionErrorCode::TimedOut) throw;
            lastError = WSAETIMEDOUT; continue;
          }
          WSANETWORKEVENTS events;
          if (::WSAEnumNetworkEvents(socket.value, connected.value, &events) == SOCKET_ERROR) error = ::WSAGetLastError();
          else error = (events.lNetworkEvents & FD_CONNECT) ? events.iErrorCode[FD_CONNECT_BIT] : WSAECONNREFUSED;
        }
        if (error) { lastError = error; continue; }
        // The transport registers its own events; drop this association.
        if (::WSAEventSelect(socket.value, nullptr, 0) == SOCKET_ERROR) winio::failSocket("connect event release");
        state->check(phase);
        const int fd = winio::sharedDescriptor(socket.value);
        std::unique_ptr<network::Socket> owned;
        if (family == AF_UNIX) owned.reset(new LocalSocket(fd, endpoint.path()));
        else owned.reset(new network::TcpSocket(fd));
        socket.release();
        return adoptSocketTransport(std::move(owned));
      }
      throw ConnectionError(lastError == WSAETIMEDOUT ? ConnectionErrorCode::TimedOut : ConnectionErrorCode::Connection,
                            phase, lastError);
    } catch (const std::system_error& error) {
      throw ConnectionError(phase == ConnectionPhase::Resolving ? ConnectionErrorCode::Resolution : ConnectionErrorCode::Connection,
                            phase, error.code().value());
    }
  }
private:
  const Endpoint endpoint, identity;
  const SocketConnectOptions options;
  std::shared_ptr<State> state;
  std::shared_ptr<TransportControl> token;
};
}
std::unique_ptr<ConnectionAttempt> prepareSocketConnection(const Endpoint& endpoint, const SocketConnectOptions& options)
{
  return std::unique_ptr<ConnectionAttempt>(new Connector(endpoint, endpoint, options));
}
std::unique_ptr<ConnectionAttempt> prepareRoutedSocketConnection(
  const Endpoint& target, const Endpoint& local, const SocketConnectOptions& options)
{
  if (target.transport() != EndpointTransport::Tcp || target.route().empty() ||
      !local.route().empty() || !local.scope().empty())
    throw std::invalid_argument("Invalid tunnel endpoint");
  if (local.transport() == EndpointTransport::Tcp &&
      (local.port() == 0 || (local.host() != "127.0.0.1" && local.host() != "::1")))
    throw std::invalid_argument("Invalid tunnel forwarding address");
  return std::unique_ptr<ConnectionAttempt>(new Connector(local, target, options));
}
}
