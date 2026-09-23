/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/platform/SocketConnector.h>
#include <viewer/platform/SocketTransport.h>
#include <viewer/platform/detail/SocketIO.h>
#include <network/TcpSocket.h>
#include <network/UnixSocket.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <limits>
#include <arpa/inet.h>
#include <net/if.h>
#include <poll.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/un.h>
#ifdef __APPLE__
#include <dns_sd.h>
#elif defined(TIDYVNC_HAVE_GETADDRINFO_A)
#include <memory>
#include <netdb.h>
#include <signal.h>
#endif

namespace viewer {
namespace {
using Clock = SessionTransport::Clock;
using TimePoint = SessionTransport::TimePoint;
using detail::Descriptor;
struct Address { sockaddr_storage storage{}; socklen_t length = 0; };
struct Addresses { std::array<Address, 16> values; size_t count = 0; };
struct State {
  detail::WakePipe wake;
  std::atomic<bool> cancelled{false}, started{false};
  void check(ConnectionPhase phase) const {
    if (cancelled.load()) throw ConnectionError(ConnectionErrorCode::Cancelled, phase);
  }
  // events[0] is always the wake pipe. Recompute absolute deadlines after EINTR
  // or unrelated wakes; no callback runs while a lock is held.
  void wait(pollfd* events, size_t count, TimePoint deadline, ConnectionPhase phase) {
    for (;;) {
      check(phase);
      if (Clock::now() >= deadline) throw ConnectionError(ConnectionErrorCode::TimedOut, phase, ETIMEDOUT);
      int ready = ::poll(events, count, detail::timeoutMillis(deadline));
      if (ready < 0) { if (errno == EINTR) continue; detail::fail("connection wait"); }
      check(phase);
      if (events[0].revents & POLLIN) wake.consume();
      for (size_t i = 1; i < count; ++i) if (events[i].revents) return;
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
  bool numeric = std::all_of(scope.begin(), scope.end(), [](char c) { return c >= '0' && c <= '9'; });
  if (!numeric) {
    value = ::if_nametoindex(scope.c_str());
    if (!value) throw ConnectionError(ConnectionErrorCode::InvalidAddress, ConnectionPhase::Connecting, ENODEV);
    return value;
  }
  for (char c : scope) {
    if (value > (std::numeric_limits<uint32_t>::max() - (c - '0')) / 10)
      throw ConnectionError(ConnectionErrorCode::InvalidAddress, ConnectionPhase::Connecting, EINVAL);
    value = value * 10 + c - '0';
  }
  return value;
}
bool literal(const Endpoint& endpoint, const SocketConnectOptions& options, Addresses& out)
{
  Address address;
  auto* v4 = reinterpret_cast<sockaddr_in*>(&address.storage);
  if (::inet_pton(AF_INET, endpoint.host().c_str(), &v4->sin_addr) == 1) {
    if (!options.ipv4 || !endpoint.scope().empty())
      throw ConnectionError(ConnectionErrorCode::InvalidAddress, ConnectionPhase::Connecting, EAFNOSUPPORT);
    v4->sin_family = AF_INET; v4->sin_port = htons(endpoint.port()); address.length = sizeof(*v4);
  } else {
    auto* v6 = reinterpret_cast<sockaddr_in6*>(&address.storage);
    if (::inet_pton(AF_INET6, endpoint.host().c_str(), &v6->sin6_addr) != 1) return false;
    if (!options.ipv6) throw ConnectionError(ConnectionErrorCode::InvalidAddress, ConnectionPhase::Connecting, EAFNOSUPPORT);
    v6->sin6_family = AF_INET6; v6->sin6_port = htons(endpoint.port());
    v6->sin6_scope_id = scopeIndex(endpoint.scope()); address.length = sizeof(*v6);
  }
  out.values[out.count++] = address; return true;
}
#ifdef __APPLE__
struct Query {
  ~Query() { if (ref) DNSServiceRefDeallocate(ref); }
  DNSServiceRef ref = nullptr;
  Addresses* output = nullptr;
  uint16_t port = 0;
  size_t count = 0, limit = 16;
  bool done = false;
  int error = 0;
};
void resolved(DNSServiceRef, DNSServiceFlags flags, uint32_t interfaceIndex,
              DNSServiceErrorType error, const char*, const sockaddr* address,
              uint32_t, void* context) noexcept
{
  auto& query = *static_cast<Query*>(context);
  if (error) { query.error = error; query.done = true; return; }
  if ((flags & kDNSServiceFlagsAdd) && address && query.count < query.limit &&
      query.output->count < query.output->values.size()) {
    Address next;
    if (address->sa_family == AF_INET) {
      next.length = sizeof(sockaddr_in);
      std::memcpy(&next.storage, address, next.length);
      reinterpret_cast<sockaddr_in*>(&next.storage)->sin_port = htons(query.port);
    } else if (address->sa_family == AF_INET6) {
      next.length = sizeof(sockaddr_in6);
      std::memcpy(&next.storage, address, next.length);
      auto* v6 = reinterpret_cast<sockaddr_in6*>(&next.storage);
      v6->sin6_port = htons(query.port);
      if (!v6->sin6_scope_id && IN6_IS_ADDR_LINKLOCAL(&v6->sin6_addr)) v6->sin6_scope_id = interfaceIndex;
    }
    if (next.length) { query.output->values[query.output->count++] = next; ++query.count; }
  }
  if (!(flags & kDNSServiceFlagsMoreComing)) query.done = true;
}
void resolve(State& state, const Endpoint& endpoint, const SocketConnectOptions& options, Addresses& output)
{
  const auto deadline = Clock::now() + options.resolveTimeout;
  std::array<Query, 2> queries;
  const bool enabled[] = {options.ipv6, options.ipv4};
  const DNSServiceProtocol protocols[] = {kDNSServiceProtocol_IPv6, kDNSServiceProtocol_IPv4};
  for (size_t i = 0; i < queries.size(); ++i) {
    auto& query = queries[i]; query.output = &output; query.port = endpoint.port();
    query.limit = options.ipv4 && options.ipv6 ? 8 : 16;
    if (!enabled[i]) { query.done = true; continue; }
    state.check(ConnectionPhase::Resolving);
    query.error = DNSServiceGetAddrInfo(&query.ref, kDNSServiceFlagsTimeout, 0,
      protocols[i], endpoint.host().c_str(), resolved, &query);
    if (query.error) query.done = true;
    else detail::configure(DNSServiceRefSockFD(query.ref), false);
  }
  while (!queries[0].done || !queries[1].done) {
    pollfd events[3] = {{state.wake.read.value, POLLIN, 0}, {-1, POLLIN, 0}, {-1, POLLIN, 0}};
    for (size_t i = 0; i < queries.size(); ++i)
      if (!queries[i].done) events[i + 1].fd = DNSServiceRefSockFD(queries[i].ref);
    try { state.wait(events, 3, deadline, ConnectionPhase::Resolving); }
    catch (const ConnectionError& error) {
      // A slow/unavailable family must not discard usable addresses from the
      // other family when the total resolution budget expires.
      if (error.code == ConnectionErrorCode::TimedOut && output.count) break;
      throw;
    }
    for (size_t i = 0; i < queries.size(); ++i) {
      if (!events[i + 1].revents) continue;
      const auto error = DNSServiceProcessResult(queries[i].ref);
      if (error) { queries[i].error = error; queries[i].done = true; }
    }
  }
  state.check(ConnectionPhase::Resolving);
  if (!output.count) throw ConnectionError(ConnectionErrorCode::Resolution, ConnectionPhase::Resolving,
                                          queries[0].error ? queries[0].error : queries[1].error);
}
#elif defined(TIDYVNC_HAVE_GETADDRINFO_A)
// glibc asynchronous lookup. The request, its strings and result list are shared
// with glibc's notification thread: after an abandoned (cancelled or expired)
// lookup, whichever side finishes last releases them. run() therefore returns
// promptly without joining or detaching a resolver thread of its own.
struct Lookup {
  ~Lookup() { if (request.ar_result) ::freeaddrinfo(request.ar_result); }
  std::string name;
  addrinfo hints{};
  gaicb request{};
  detail::WakePipe completed;
};
void notified(sigval value) noexcept
{
  std::unique_ptr<std::shared_ptr<Lookup>> holder(static_cast<std::shared_ptr<Lookup>*>(value.sival_ptr));
  (*holder)->completed.signal();
}
void resolve(State& state, const Endpoint& endpoint, const SocketConnectOptions& options, Addresses& output)
{
  const auto deadline = Clock::now() + options.resolveTimeout;
  auto lookup = std::make_shared<Lookup>();
  lookup->name = endpoint.host();
  lookup->hints.ai_family = options.ipv4 && options.ipv6 ? AF_UNSPEC : options.ipv4 ? AF_INET : AF_INET6;
  lookup->hints.ai_socktype = SOCK_STREAM;
  lookup->hints.ai_protocol = IPPROTO_TCP;
  lookup->request.ar_name = lookup->name.c_str();
  lookup->request.ar_request = &lookup->hints;
  gaicb* list[] = {&lookup->request};
  std::unique_ptr<std::shared_ptr<Lookup>> holder(new std::shared_ptr<Lookup>(lookup));
  sigevent notification{};
  notification.sigev_notify = SIGEV_THREAD;
  notification.sigev_notify_function = notified;
  notification.sigev_value.sival_ptr = holder.get();
  state.check(ConnectionPhase::Resolving);
  if (const int error = ::getaddrinfo_a(GAI_NOWAIT, list, 1, &notification))
    throw ConnectionError(ConnectionErrorCode::Resolution, ConnectionPhase::Resolving, error);
  // From here only notified() may release the holder, unless glibc confirms that
  // the queued request was removed and will never notify.
  auto* pending = holder.release();
  try {
    pollfd events[] = {{state.wake.read.value, POLLIN, 0}, {lookup->completed.read.value, POLLIN, 0}};
    state.wait(events, 2, deadline, ConnectionPhase::Resolving);
  } catch (...) {
    if (::gai_cancel(&lookup->request) == EAI_CANCELED) delete pending;
    throw;
  }
  const int error = ::gai_error(&lookup->request);
  state.check(ConnectionPhase::Resolving);
  if (error) throw ConnectionError(ConnectionErrorCode::Resolution, ConnectionPhase::Resolving, error);
  for (auto* entry = lookup->request.ar_result; entry && output.count < output.values.size(); entry = entry->ai_next) {
    if ((entry->ai_family != AF_INET && entry->ai_family != AF_INET6) || !entry->ai_addr ||
        entry->ai_addrlen > sizeof(sockaddr_storage)) continue;
    Address next;
    std::memcpy(&next.storage, entry->ai_addr, entry->ai_addrlen);
    next.length = entry->ai_addrlen;
    if (entry->ai_family == AF_INET) reinterpret_cast<sockaddr_in*>(&next.storage)->sin_port = htons(endpoint.port());
    else reinterpret_cast<sockaddr_in6*>(&next.storage)->sin6_port = htons(endpoint.port());
    output.values[output.count++] = next;
  }
  if (!output.count) throw ConnectionError(ConnectionErrorCode::Resolution, ConnectionPhase::Resolving, EAI_NONAME);
}
#endif

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
        auto* local = reinterpret_cast<sockaddr_un*>(&address.storage);
        if (endpoint.path().size() >= sizeof(local->sun_path))
          throw ConnectionError(ConnectionErrorCode::InvalidAddress, phase, ENAMETOOLONG);
        local->sun_family = AF_UNIX;
        std::memcpy(local->sun_path, endpoint.path().c_str(), endpoint.path().size() + 1);
        address.length = sizeof(sockaddr_un);
#ifdef __APPLE__
        local->sun_len = address.length;
#endif
        addresses.values[addresses.count++] = address;
      } else if (!literal(endpoint, options, addresses)) {
        phase = ConnectionPhase::Resolving;
        if (progress) progress(phase);
        state->check(phase);
        if (!endpoint.scope().empty()) throw ConnectionError(ConnectionErrorCode::InvalidAddress, phase);
#if defined(__APPLE__) || defined(TIDYVNC_HAVE_GETADDRINFO_A)
        resolve(*state, endpoint, options, addresses);
#else
        throw ConnectionError(ConnectionErrorCode::Unsupported, phase);
#endif
      }
      phase = ConnectionPhase::Connecting;
      state->check(phase);
      if (progress) progress(phase);
      const auto deadline = Clock::now() + options.connectTimeout;
      int lastError = ECONNREFUSED;
      for (size_t i = 0; i < addresses.count; ++i) {
        state->check(phase);
        if (Clock::now() >= deadline) throw ConnectionError(ConnectionErrorCode::TimedOut, phase, ETIMEDOUT);
        const auto& address = addresses.values[i];
        Descriptor socket(::socket(address.storage.ss_family, SOCK_STREAM, 0));
        if (socket.value < 0) { lastError = errno; continue; }
        if (socket.value >= FD_SETSIZE) throw ConnectionError(ConnectionErrorCode::Connection, phase, EMFILE);
        detail::configure(socket.value, true);
        int result = ::connect(socket.value, reinterpret_cast<const sockaddr*>(&address.storage), address.length);
        int error = result == 0 ? 0 : errno;
        if (error == EINPROGRESS || error == EINTR ||
            (error == EWOULDBLOCK && address.storage.ss_family != AF_UNIX)) {
          pollfd events[] = {{state->wake.read.value, POLLIN, 0}, {socket.value, POLLOUT, 0}};
          try { state->wait(events, 2, std::min(deadline, Clock::now() + options.addressTimeout), phase); }
          catch (const ConnectionError& waitError) {
            if (waitError.code != ConnectionErrorCode::TimedOut) throw;
            lastError = ETIMEDOUT; continue;
          }
          socklen_t size = sizeof(error);
          if (::getsockopt(socket.value, SOL_SOCKET, SO_ERROR, &error, &size) < 0) error = errno;
        }
        if (error) { lastError = error; continue; }
        state->check(phase);
        std::unique_ptr<network::Socket> owned;
        if (address.storage.ss_family == AF_UNIX) owned.reset(new network::UnixSocket(socket.value));
        else owned.reset(new network::TcpSocket(socket.value));
        socket.value = -1;
        return adoptSocketTransport(std::move(owned));
      }
      throw ConnectionError(lastError == ETIMEDOUT ? ConnectionErrorCode::TimedOut : ConnectionErrorCode::Connection,
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
