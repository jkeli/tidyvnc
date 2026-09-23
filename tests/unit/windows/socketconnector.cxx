/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Windows counterpart of tests/unit/socketconnector.cxx for
// viewer/platform/windows/SocketConnector.cxx: numeric and resolved
// endpoints through GetAddrInfoExW, routed local forwarders, AF_UNIX (D18),
// cancellation at each stage and Winsock error codes.
#include <gtest/gtest.h>
#include <viewer/platform/SocketConnector.h>
#include <viewer/core/SessionWorker.h>
#include <rfb/PixelFormat.h>
#include <rdr/InStream.h>
#include <rdr/OutStream.h>
#include <rdr/MemOutStream.h>
#include <network/Socket.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <afunix.h>
#include <array>
#include <cstring>
#include <filesystem>
#include <future>
#include <random>
#include <thread>
#include <vector>

using namespace viewer;
using namespace std::chrono;
namespace {
void require(bool okay) { if (!okay) throw std::runtime_error("Connector fixture failed"); }
struct Descriptor {
  explicit Descriptor(SOCKET value_ = INVALID_SOCKET) : value(value_) {}
  ~Descriptor() { if (value != INVALID_SOCKET) ::closesocket(value); }
  Descriptor(const Descriptor&) = delete;
  Descriptor& operator=(const Descriptor&) = delete;
  SOCKET value;
};
int readable(SOCKET socket, int timeout)
{
  WSAPOLLFD event{socket, POLLRDNORM, 0};
  return ::WSAPoll(&event, 1, timeout);
}
struct Listener {
  explicit Listener(int family = AF_INET, bool listening = true) {
    network::initSockets();
    fd.value = ::socket(family, SOCK_STREAM, IPPROTO_TCP);
    require(fd.value != INVALID_SOCKET);
    sockaddr_storage address{};
    int length;
    if (family == AF_INET) {
      auto* v4 = reinterpret_cast<sockaddr_in*>(&address);
      v4->sin_family = AF_INET; v4->sin_addr.s_addr = htonl(INADDR_LOOPBACK); length = sizeof(*v4);
    } else {
      const BOOL one = TRUE;
      require(::setsockopt(fd.value, IPPROTO_IPV6, IPV6_V6ONLY, reinterpret_cast<const char*>(&one), sizeof(one)) == 0);
      auto* v6 = reinterpret_cast<sockaddr_in6*>(&address);
      v6->sin6_family = AF_INET6; v6->sin6_addr = in6addr_loopback; length = sizeof(*v6);
    }
    require(::bind(fd.value, reinterpret_cast<sockaddr*>(&address), length) == 0);
    require(::getsockname(fd.value, reinterpret_cast<sockaddr*>(&address), &length) == 0);
    port = ntohs(family == AF_INET ? reinterpret_cast<sockaddr_in*>(&address)->sin_port :
                                  reinterpret_cast<sockaddr_in6*>(&address)->sin6_port);
    if (listening) require(::listen(fd.value, 4) == 0);
  }
  SOCKET accept() {
    require(readable(fd.value, 3000) == 1);
    const SOCKET peer = ::accept(fd.value, nullptr, nullptr); require(peer != INVALID_SOCKET); return peer;
  }
  void drain() {
    while (readable(fd.value, 0) == 1) {
      const SOCKET peer = ::accept(fd.value, nullptr, nullptr);
      if (peer == INVALID_SOCKET) break;
      ::closesocket(peer);
    }
  }
  Descriptor fd;
  uint16_t port = 0;
};
void exchange(SessionTransport& transport, SOCKET peer)
{
  const char byte = 37;
  require(::send(peer, &byte, 1, 0) == 1);
  EXPECT_TRUE(transport.wait(steady_clock::now() + seconds(2)).readable);
  ASSERT_TRUE(transport.input().hasData(1)); EXPECT_EQ(transport.input().readU8(), byte);
  transport.output().writeU8(91); transport.flush();
  ASSERT_EQ(readable(peer, 2000), 1);
  char reply = 0; ASSERT_EQ(::recv(peer, &reply, 1, 0), 1); EXPECT_EQ(reply, 91);
}
template<class F> bool until(F predicate)
{
  const auto deadline = steady_clock::now() + seconds(3);
  do { if (predicate()) return true; std::this_thread::sleep_for(milliseconds(1)); }
  while (steady_clock::now() < deadline);
  return predicate();
}
// A unique, short directory for AF_UNIX paths (the limit is 108 bytes).
struct TemporaryDirectory {
  TemporaryDirectory() {
    std::random_device random;
    path = std::filesystem::temp_directory_path() / ("tidyvnc-" + std::to_string(random()));
    std::filesystem::create_directory(path);
  }
  ~TemporaryDirectory() { std::error_code ignored; std::filesystem::remove_all(path, ignored); }
  std::filesystem::path path;
};
}

TEST(SocketConnector, NumericIpv4ConnectsWithoutResolutionAndAttemptIsSingleUse)
{
  Listener listener;
  auto attempt = prepareSocketConnection(Endpoint::parse("127.0.0.1::" + std::to_string(listener.port)));
  std::vector<ConnectionPhase> phases;
  auto transport = attempt->run([&](ConnectionPhase phase) { phases.push_back(phase); });
  Descriptor peer(listener.accept());
  EXPECT_EQ(phases, (std::vector<ConnectionPhase>{ConnectionPhase::Connecting}));
  EXPECT_EQ(attempt->serverName(), "127.0.0.1");
  exchange(*transport, peer.value);
  EXPECT_THROW(attempt->run({}), std::logic_error);
}

TEST(SocketConnector, NumericIpv6AndNumericScopeConnectWithoutDns)
{
  Listener listener(AF_INET6);
  auto attempt = prepareSocketConnection(Endpoint::parse("[::1%0]::" + std::to_string(listener.port)));
  auto transport = attempt->run({}); Descriptor peer(listener.accept());
  EXPECT_EQ(attempt->serverName(), "::1");
  exchange(*transport, peer.value);
}

TEST(SocketConnector, RoutedLocalSocketKeepsRemoteTLSNameWithoutResolvingTarget)
{
  for (int family : {AF_INET, AF_INET6}) {
    Listener listener(family);
    const auto local = Endpoint::parse((family == AF_INET ? "127.0.0.1::" : "[::1]::") + std::to_string(listener.port));
    auto attempt = prepareRoutedSocketConnection(Endpoint::parse("REMOTE.invalid:1",false,"ssh:gateway"),local);
    EXPECT_EQ(attempt->serverName(),"remote.invalid");
    std::vector<ConnectionPhase> phases;
    auto transport = attempt->run([&](ConnectionPhase phase) { phases.push_back(phase); });
    Descriptor peer(listener.accept()); exchange(*transport,peer.value);
    EXPECT_EQ(phases,(std::vector<ConnectionPhase>{ConnectionPhase::Connecting}));
    auto control = attempt->control(); attempt.reset(); control->cancel();
    exchange(*transport,peer.value);
  }
}

TEST(SocketConnector, RoutedAdmissionRejectsMissingIdentityAndNonlocalForwarders)
{
  const auto target = Endpoint::parse("remote.invalid",false,"ssh:gateway");
  const auto local = Endpoint::parse("127.0.0.1::5901");
  EXPECT_THROW(prepareRoutedSocketConnection(Endpoint::parse("remote.invalid"),local),std::invalid_argument);
  EXPECT_THROW(prepareRoutedSocketConnection(Endpoint::parse("C:\\remote",true,"route"),local),std::invalid_argument);
  EXPECT_THROW(prepareRoutedSocketConnection(target,Endpoint::parse("127.0.0.1",false,"nested")),std::invalid_argument);
  for (const auto& value : {"localhost", "192.0.2.1", "[2001:db8::1]", "[::1%0]", "127.0.0.1::0"})
    EXPECT_THROW(prepareRoutedSocketConnection(target,Endpoint::parse(value)),std::invalid_argument);
  auto cancelled = prepareRoutedSocketConnection(target,local);
  cancelled->control()->cancel();
  try { cancelled->run({}); FAIL() << "Expected cancellation"; }
  catch (const ConnectionError& error) { EXPECT_EQ(error.code,ConnectionErrorCode::Cancelled); }
}

TEST(SocketConnector, UnixSocketPathConnectsAndPreservesBytes)
{
  network::initSockets();
  TemporaryDirectory directory;
  // Both separators classify as paths on Windows; the native one is used here.
  const std::string path = (directory.path / "peer.sock").string();
  Descriptor listener(::socket(AF_UNIX, SOCK_STREAM, 0)); ASSERT_NE(listener.value, INVALID_SOCKET);
  SOCKADDR_UN address{}; address.sun_family = AF_UNIX;
  ASSERT_LT(path.size(), sizeof(address.sun_path)); std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
  ASSERT_EQ(::bind(listener.value, reinterpret_cast<sockaddr*>(&address), sizeof(address)), 0);
  ASSERT_EQ(::listen(listener.value, 1), 0);
  auto attempt = prepareSocketConnection(Endpoint::parse(path, true));
  auto transport = attempt->run({});
  Descriptor peer(::accept(listener.value, nullptr, nullptr)); ASSERT_NE(peer.value, INVALID_SOCKET);
  EXPECT_EQ(attempt->serverName(), path); exchange(*transport, peer.value);
  auto forwardSlashes = path; for (auto& c : forwardSlashes) if (c == '\\') c = '/';
  auto routed = prepareRoutedSocketConnection(Endpoint::parse("REMOTE.invalid:2",false,"ssh:gateway"),
                                              Endpoint::parse(forwardSlashes, true));
  EXPECT_EQ(routed->serverName(),"remote.invalid");
  auto forwarded = routed->run({});
  Descriptor forwardedPeer(::accept(listener.value,nullptr,nullptr)); ASSERT_NE(forwardedPeer.value,INVALID_SOCKET);
  exchange(*forwarded,forwardedPeer.value);
}

TEST(SocketConnector, UnixSocketMissingPathIsATypedConnectionError)
{
  TemporaryDirectory directory;
  auto attempt = prepareSocketConnection(Endpoint::parse((directory.path / "absent.sock").string(), true));
  try { attempt->run({}); FAIL() << "Expected a connection error"; }
  catch (const ConnectionError& error) {
    EXPECT_EQ(error.code, ConnectionErrorCode::Connection); EXPECT_NE(error.nativeError, 0);
  }
}

TEST(SocketConnector, CancelBeforeStartIsStickyAndRetainedControlIsSafe)
{
  auto attempt = prepareSocketConnection(Endpoint::parse("localhost"));
  auto control = attempt->control(); control->cancel(); control->cancel();
  bool progressed = false;
  try { attempt->run([&](ConnectionPhase) { progressed = true; }); FAIL() << "Expected cancellation"; }
  catch (const ConnectionError& error) { EXPECT_EQ(error.code, ConnectionErrorCode::Cancelled); }
  EXPECT_FALSE(progressed);
  attempt.reset(); control->wake(); control->cancel();
}

TEST(SocketConnector, OldSetupControlCannotCloseTransferredSocket)
{
  Listener listener;
  auto attempt = prepareSocketConnection(Endpoint::parse("127.0.0.1::" + std::to_string(listener.port)));
  auto old = attempt->control(); auto transport = attempt->run({});
  Descriptor peer(listener.accept()); attempt.reset(); old->cancel(); old->wake();
  exchange(*transport, peer.value);
}

TEST(SocketConnector, RefusedPortHasTypedConnectionErrorWithoutEndpointText)
{
  Listener reserved(AF_INET, false);
  const auto port = reserved.port;
  ::closesocket(reserved.fd.value); reserved.fd.value = INVALID_SOCKET;
  // Windows retries a refused SYN before reporting WSAECONNREFUSED, so the
  // per-address budget is longer than the default here.
  SocketConnectOptions options; options.addressTimeout = milliseconds(8000); options.connectTimeout = milliseconds(10000);
  auto attempt = prepareSocketConnection(Endpoint::parse("127.0.0.1::" + std::to_string(port)), options);
  try { attempt->run({}); FAIL() << "Expected refused connection"; }
  catch (const ConnectionError& error) {
    EXPECT_EQ(error.code, ConnectionErrorCode::Connection); EXPECT_EQ(error.phase, ConnectionPhase::Connecting);
    EXPECT_EQ(error.nativeError, WSAECONNREFUSED);
    EXPECT_EQ(std::string(error.what()).find("127.0.0.1"), std::string::npos);
  }
}

TEST(SocketConnector, RejectsUnsupportedRouteInvalidPathAndScope)
{
  const auto route = Endpoint::parse("localhost", true, "tunnel-identity");
  auto routed = prepareSocketConnection(route);
  try { routed->run({}); FAIL() << "Expected unsupported route"; }
  catch (const ConnectionError& error) { EXPECT_EQ(error.code, ConnectionErrorCode::Unsupported); }
  for (const auto& value : {"C:\\" + std::string(200, 'x'), std::string("C:\\caf\xc3\xa9\\peer.sock"),
                            std::string("[::1%4294967296]"), std::string("[::1%tidyvnc-no-such-interface]")}) {
    auto attempt = prepareSocketConnection(Endpoint::parse(value, true));
    try { attempt->run({}); FAIL() << "Expected invalid endpoint: " << value; }
    catch (const ConnectionError& error) { EXPECT_EQ(error.code, ConnectionErrorCode::InvalidAddress); }
  }
}

TEST(SocketConnector, ValidatesFamilyAndTimeoutPolicy)
{
  const auto endpoint = Endpoint::parse("127.0.0.1");
  SocketConnectOptions options; options.ipv4 = options.ipv6 = false;
  EXPECT_THROW(prepareSocketConnection(endpoint, options), std::invalid_argument);
  options.ipv6 = true;
  auto disabled = prepareSocketConnection(endpoint, options);
  EXPECT_THROW(disabled->run({}), ConnectionError);
  options.resolveTimeout = milliseconds(0);
  EXPECT_THROW(prepareSocketConnection(endpoint, options), std::invalid_argument);
  options.resolveTimeout = milliseconds(10); options.connectTimeout = milliseconds(60001);
  EXPECT_THROW(prepareSocketConnection(endpoint, options), std::invalid_argument);
  options.connectTimeout = milliseconds(10); options.addressTimeout = milliseconds(0);
  EXPECT_THROW(prepareSocketConnection(endpoint, options), std::invalid_argument);
}

// Windows keeps a refused loopback SYN pending while it retries, which gives
// a real pending connect to time out and cancel (macOS uses a bound socket).
TEST(SocketConnector, PendingLocalConnectHonorsMonotonicAddressDeadline)
{
  Listener reserved(AF_INET, false);
  SocketConnectOptions options;
  options.addressTimeout = milliseconds(25); options.connectTimeout = milliseconds(100);
  auto attempt = prepareSocketConnection(Endpoint::parse("127.0.0.1::" + std::to_string(reserved.port)), options);
  const auto before = steady_clock::now();
  try { attempt->run({}); FAIL() << "Expected pending connect timeout"; }
  catch (const ConnectionError& error) {
    EXPECT_EQ(error.code, ConnectionErrorCode::TimedOut); EXPECT_EQ(error.nativeError, WSAETIMEDOUT);
    EXPECT_EQ(error.phase, ConnectionPhase::Connecting);
  }
  EXPECT_GE(steady_clock::now() - before, milliseconds(25));
  EXPECT_LT(steady_clock::now() - before, seconds(2));
}

TEST(SocketConnector, CancellationInterruptsActualPendingConnectWait)
{
  Listener reserved(AF_INET, false);
  SocketConnectOptions options; options.addressTimeout = options.connectTimeout = milliseconds(5000);
  auto attempt = prepareSocketConnection(Endpoint::parse("127.0.0.1::" + std::to_string(reserved.port)), options);
  auto control = attempt->control();
  std::promise<void> entered;
  auto executor = std::async(std::launch::async, [&] {
    try { attempt->run([&](ConnectionPhase) { entered.set_value(); }); }
    catch (const ConnectionError& error) { return error.code; }
    return ConnectionErrorCode::Connection;
  });
  entered.get_future().wait();
  const auto pending = executor.wait_for(milliseconds(20));
  control->cancel();
  EXPECT_EQ(pending, std::future_status::timeout);
  ASSERT_EQ(executor.wait_for(seconds(1)), std::future_status::ready);
  EXPECT_EQ(executor.get(), ConnectionErrorCode::Cancelled);
}

TEST(SocketConnector, SystemAsyncResolverConnectsLocalhost)
{
  Listener listener;
  SocketConnectOptions options; options.resolveTimeout = milliseconds(2000); options.ipv6 = false;
  auto attempt = prepareSocketConnection(Endpoint::parse("localhost::" + std::to_string(listener.port)), options);
  std::vector<ConnectionPhase> phases;
  auto transport = attempt->run([&](ConnectionPhase phase) { phases.push_back(phase); });
  Descriptor peer(listener.accept()); exchange(*transport, peer.value);
  EXPECT_EQ(phases, (std::vector<ConnectionPhase>{ConnectionPhase::Resolving, ConnectionPhase::Connecting}));
}

TEST(SocketConnector, SystemAsyncResolverHonorsSingleAddressFamily)
{
  Listener listener(AF_INET6);
  SocketConnectOptions options; options.ipv4 = false; options.resolveTimeout = milliseconds(2000);
  auto attempt = prepareSocketConnection(Endpoint::parse("localhost::" + std::to_string(listener.port)), options);
  auto transport = attempt->run({});
  Descriptor peer(listener.accept()); exchange(*transport, peer.value);
}

TEST(SocketConnector, ResolutionFailureIsTypedWithTheResolverCode)
{
  SocketConnectOptions options; options.resolveTimeout = milliseconds(5000);
  auto attempt = prepareSocketConnection(Endpoint::parse("tidyvnc-no-such-host.invalid"), options);
  try { attempt->run({}); FAIL() << "Expected a resolution failure"; }
  catch (const ConnectionError& error) {
    EXPECT_TRUE(error.code == ConnectionErrorCode::Resolution || error.code == ConnectionErrorCode::TimedOut);
    EXPECT_EQ(error.phase, ConnectionPhase::Resolving);
    if (error.code == ConnectionErrorCode::Resolution) EXPECT_NE(error.nativeError, 0);
  }
}

// Cancels at varying points around submission and completion. Every outcome is
// a typed cancellation or a usable transport; abandoned lookups are released
// by the resolver's own completion routine.
TEST(SocketConnector, CancellationRacingSystemLookupIsTypedAndOwned)
{
  Listener listener;
  SocketConnectOptions options; options.resolveTimeout = milliseconds(2000); options.ipv6 = false;
  const auto endpoint = Endpoint::parse("localhost::" + std::to_string(listener.port));
  size_t cancelled = 0, connected = 0;
  for (int i = 0; i < 64; ++i) {
    auto attempt = prepareSocketConnection(endpoint, options);
    auto control = attempt->control();
    std::promise<void> resolving;
    auto canceller = std::async(std::launch::async, [&, i] {
      resolving.get_future().wait();
      std::this_thread::sleep_for(microseconds((i % 16) * 50));
      control->cancel();
    });
    try {
      auto transport = attempt->run([&](ConnectionPhase phase) {
        if (phase == ConnectionPhase::Resolving) resolving.set_value();
      });
      Descriptor peer(listener.accept());
      ++connected;
    } catch (const ConnectionError& error) {
      EXPECT_EQ(error.code, ConnectionErrorCode::Cancelled);
      ++cancelled;
    }
    canceller.get();
    listener.drain();
  }
  EXPECT_EQ(cancelled + connected, 64u);
  std::this_thread::sleep_for(milliseconds(250));
}

TEST(SocketConnector, ResolverAndDialProgressCanCancelBeforeBlockingWork)
{
  for (const auto& host : {"localhost", "127.0.0.1"}) {
    auto attempt = prepareSocketConnection(Endpoint::parse(host)); auto token = attempt->control();
    try { attempt->run([&](ConnectionPhase) { token->cancel(); }); FAIL() << "Expected cancellation"; }
    catch (const ConnectionError& error) { EXPECT_EQ(error.code, ConnectionErrorCode::Cancelled); }
  }
}

TEST(SocketConnector, RuntimeConnectsEndpointAndNegotiatesRealRfbSocket)
{
  Listener listener;
  SessionRuntime runtime;
  auto worker = runtime.connect(prepareSocketConnection(Endpoint::parse("127.0.0.1::" + std::to_string(listener.port))),
                                rfb::SecurityClient({rfb::secTypeNone}));
  Descriptor peer(listener.accept());
  rdr::MemOutStream wire;
  wire.writeBytes(reinterpret_cast<const uint8_t*>("RFB 003.008\n"), 12);
  wire.writeU8(1); wire.writeU8(rfb::secTypeNone); wire.writeU32(0);
  wire.writeU16(2); wire.writeU16(2);
  rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0).write(&wire);
  wire.writeU32(4); wire.writeBytes(reinterpret_cast<const uint8_t*>("peer"), 4);
  ASSERT_EQ(::send(peer.value, reinterpret_cast<const char*>(wire.data()), static_cast<int>(wire.length()), 0),
            static_cast<int>(wire.length()));
  ASSERT_TRUE(until([&] { return worker->events()->snapshot().state == SessionState::Connected; }));
  ASSERT_EQ(readable(peer.value, 1000), 1);
  std::array<char, 12> version{};
  ASSERT_EQ(::recv(peer.value, version.data(), static_cast<int>(version.size()), MSG_WAITALL), 12);
  EXPECT_EQ(std::string(version.begin(), version.end()), "RFB 003.008\n");
  auto done = worker->closeAndDrain(); ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(done.get().code, WorkerResultCode::Cancelled);
}
