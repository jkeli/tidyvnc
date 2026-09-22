/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/platform/SocketConnector.h>
#include <viewer/core/SessionWorker.h>
#include <rfb/PixelFormat.h>
#include <rdr/InStream.h>
#include <rdr/OutStream.h>
#include <rdr/MemOutStream.h>
#include <array>
#include <cerrno>
#include <cstring>
#include <thread>
#include <vector>
#include <arpa/inet.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

using namespace viewer;
using namespace std::chrono;
namespace {
void require(bool okay) { if (!okay) throw std::runtime_error("Connector fixture failed"); }
struct Descriptor {
  explicit Descriptor(int value_ = -1) : value(value_) {}
  ~Descriptor() { if (value >= 0) ::close(value); }
  Descriptor(const Descriptor&) = delete;
  Descriptor& operator=(const Descriptor&) = delete;
  int value;
};
struct Listener {
  explicit Listener(int family = AF_INET, bool listening = true) : fd(::socket(family, SOCK_STREAM, 0)) {
    require(fd.value >= 0);
    sockaddr_storage address{};
    socklen_t length;
    if (family == AF_INET) {
      auto* v4 = reinterpret_cast<sockaddr_in*>(&address);
      v4->sin_family = AF_INET; v4->sin_addr.s_addr = htonl(INADDR_LOOPBACK); length = sizeof(*v4);
    } else {
      int one = 1;
      require(::setsockopt(fd.value, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof(one)) == 0);
      auto* v6 = reinterpret_cast<sockaddr_in6*>(&address);
      v6->sin6_family = AF_INET6; v6->sin6_addr = in6addr_loopback; length = sizeof(*v6);
    }
    require(::bind(fd.value, reinterpret_cast<sockaddr*>(&address), length) == 0);
    require(::getsockname(fd.value, reinterpret_cast<sockaddr*>(&address), &length) == 0);
    port = ntohs(family == AF_INET ? reinterpret_cast<sockaddr_in*>(&address)->sin_port :
                                  reinterpret_cast<sockaddr_in6*>(&address)->sin6_port);
    if (listening) require(::listen(fd.value, 4) == 0);
  }
  int accept() {
    pollfd event{fd.value, POLLIN, 0}; require(::poll(&event, 1, 3000) == 1);
    int peer = ::accept(fd.value, nullptr, nullptr); require(peer >= 0); return peer;
  }
  Descriptor fd;
  uint16_t port = 0;
};
void exchange(SessionTransport& transport, int peer)
{
  const uint8_t byte = 37;
  require(::send(peer, &byte, 1, 0) == 1);
  EXPECT_TRUE(transport.wait(steady_clock::now() + seconds(2)).readable);
  ASSERT_TRUE(transport.input().hasData(1)); EXPECT_EQ(transport.input().readU8(), byte);
  transport.output().writeU8(91); transport.flush();
  pollfd event{peer, POLLIN, 0}; ASSERT_EQ(::poll(&event, 1, 2000), 1);
  uint8_t reply = 0; ASSERT_EQ(::recv(peer, &reply, 1, 0), 1); EXPECT_EQ(reply, 91);
}
template<class F> bool until(F predicate)
{
  const auto deadline = steady_clock::now() + seconds(3);
  do { if (predicate()) return true; std::this_thread::sleep_for(milliseconds(1)); }
  while (steady_clock::now() < deadline);
  return predicate();
}
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
    exchange(*transport,peer.value); // setup cancellation cannot close an admitted transport
  }
}

TEST(SocketConnector, RoutedAdmissionRejectsMissingIdentityAndNonlocalForwarders)
{
  const auto target = Endpoint::parse("remote.invalid",false,"ssh:gateway");
  const auto local = Endpoint::parse("127.0.0.1::5901");
  EXPECT_THROW(prepareRoutedSocketConnection(Endpoint::parse("remote.invalid"),local),std::invalid_argument);
  EXPECT_THROW(prepareRoutedSocketConnection(Endpoint::parse("/tmp/remote",true,"route"),local),std::invalid_argument);
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
  char pattern[] = "/tmp/tidyvnc-connect-XXXXXX";
  char* created = ::mkdtemp(pattern); ASSERT_NE(created, nullptr);
  const std::string directory = created, path = directory + "/peer.sock";
  struct Cleanup {
    std::string directory, path;
    ~Cleanup() { ::unlink(path.c_str()); ::rmdir(directory.c_str()); }
  } cleanup{directory, path};
  Descriptor listener(::socket(AF_UNIX, SOCK_STREAM, 0)); ASSERT_GE(listener.value, 0);
  sockaddr_un address{}; address.sun_family = AF_UNIX;
  ASSERT_LT(path.size(), sizeof(address.sun_path)); std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
  ASSERT_EQ(::bind(listener.value, reinterpret_cast<sockaddr*>(&address), sizeof(address)), 0);
  ASSERT_EQ(::listen(listener.value, 1), 0);
  auto attempt = prepareSocketConnection(Endpoint::parse(path));
  auto transport = attempt->run({});
  Descriptor peer(::accept(listener.value, nullptr, nullptr)); ASSERT_GE(peer.value, 0);
  EXPECT_EQ(attempt->serverName(), path); exchange(*transport, peer.value);
  auto routed = prepareRoutedSocketConnection(Endpoint::parse("REMOTE.invalid:2",false,"ssh:gateway"),Endpoint::parse(path));
  EXPECT_EQ(routed->serverName(),"remote.invalid");
  auto forwarded = routed->run({});
  Descriptor forwardedPeer(::accept(listener.value,nullptr,nullptr)); ASSERT_GE(forwardedPeer.value,0);
  exchange(*forwarded,forwardedPeer.value);
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
  // A bound-but-not-listening socket silently drops SYNs on macOS. Close it to
  // exercise refusal; the held version is used for pending-dial tests below.
  require(::close(reserved.fd.value) == 0); reserved.fd.value = -1;
  auto attempt = prepareSocketConnection(Endpoint::parse("127.0.0.1::" + std::to_string(reserved.port)));
  try { attempt->run({}); FAIL() << "Expected refused connection"; }
  catch (const ConnectionError& error) {
    EXPECT_EQ(error.code, ConnectionErrorCode::Connection); EXPECT_EQ(error.phase, ConnectionPhase::Connecting);
    EXPECT_EQ(error.nativeError, ECONNREFUSED);
    EXPECT_EQ(std::string(error.what()).find("127.0.0.1"), std::string::npos);
  }
}

TEST(SocketConnector, RejectsUnsupportedRouteInvalidPathAndScope)
{
  const auto route = Endpoint::parse("localhost", true, "tunnel-identity");
  auto routed = prepareSocketConnection(route);
  try { routed->run({}); FAIL() << "Expected unsupported route"; }
  catch (const ConnectionError& error) { EXPECT_EQ(error.code, ConnectionErrorCode::Unsupported); }
  for (const auto& value : {"/tmp/" + std::string(200, 'x'), std::string("[::1%4294967296]"),
                            std::string("[::1%tidyvnc-no-such-interface]")}) {
    auto attempt = prepareSocketConnection(Endpoint::parse(value));
    try { attempt->run({}); FAIL() << "Expected invalid endpoint"; }
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

#ifdef __APPLE__
TEST(SocketConnector, PendingLocalConnectHonorsMonotonicAddressDeadline)
{
  Listener reserved(AF_INET, false);
  SocketConnectOptions options;
  options.addressTimeout = milliseconds(25); options.connectTimeout = milliseconds(100);
  auto attempt = prepareSocketConnection(Endpoint::parse("127.0.0.1::" + std::to_string(reserved.port)), options);
  const auto before = steady_clock::now();
  try { attempt->run({}); FAIL() << "Expected pending connect timeout"; }
  catch (const ConnectionError& error) {
    EXPECT_EQ(error.code, ConnectionErrorCode::TimedOut); EXPECT_EQ(error.nativeError, ETIMEDOUT);
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
  SocketConnectOptions options; options.resolveTimeout = milliseconds(2000);
  auto attempt = prepareSocketConnection(Endpoint::parse("localhost::" + std::to_string(listener.port)), options);
  std::vector<ConnectionPhase> phases;
  auto transport = attempt->run([&](ConnectionPhase phase) { phases.push_back(phase); });
  Descriptor peer(listener.accept()); exchange(*transport, peer.value);
  EXPECT_EQ(phases, (std::vector<ConnectionPhase>{ConnectionPhase::Resolving, ConnectionPhase::Connecting}));
}
#else
TEST(SocketConnector, HostnamesWithoutCancellableResolverAreExplicitlyUnsupported)
{
  auto attempt = prepareSocketConnection(Endpoint::parse("localhost"));
  try { attempt->run({}); FAIL() << "Expected unsupported hostname resolver"; }
  catch (const ConnectionError& error) {
    EXPECT_EQ(error.code, ConnectionErrorCode::Unsupported); EXPECT_EQ(error.phase, ConnectionPhase::Resolving);
  }
}
#endif

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
  ASSERT_EQ(::send(peer.value, wire.data(), wire.length(), 0), static_cast<ssize_t>(wire.length()));
  ASSERT_TRUE(until([&] { return worker->events()->snapshot().state == SessionState::Connected; }));
  pollfd event{peer.value, POLLIN, 0}; ASSERT_EQ(::poll(&event, 1, 1000), 1);
  std::array<uint8_t, 12> version{};
  ASSERT_EQ(::recv(peer.value, version.data(), version.size(), MSG_WAITALL), 12);
  EXPECT_EQ(std::string(version.begin(), version.end()), "RFB 003.008\n");
  auto done = worker->closeAndDrain(); ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(done.get().code, WorkerResultCode::Cancelled);
}
