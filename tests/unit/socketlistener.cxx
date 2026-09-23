/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/platform/SocketListener.h>
#include <viewer/core/ListenerWorker.h>
#include <rfb/PixelFormat.h>
#include <rdr/MemOutStream.h>
#include <rdr/InStream.h>
#include <rdr/OutStream.h>
#include <atomic>
#include <thread>
#include "test-sockets.h"
using namespace viewer;
using namespace std::chrono;
namespace {
struct Descriptor {
  explicit Descriptor(int value_) : value(value_) {}
  ~Descriptor() { if (value >= 0) testsock::closeSocket(value); }
  Descriptor(const Descriptor&) = delete;
  Descriptor& operator=(const Descriptor&) = delete;
  int value;
};
void require(bool okay) { if (!okay) throw std::runtime_error("Listener fixture failed"); }
int connectTo(uint16_t port, int family = AF_INET) {
  Descriptor peer(testsock::open(family)); require(peer.value >= 0);
  sockaddr_storage address{}; testsock::length_t length;
  if (family == AF_INET) {
    auto& v4 = reinterpret_cast<sockaddr_in&>(address); v4.sin_family = AF_INET;
    v4.sin_port = htons(port); v4.sin_addr.s_addr = htonl(INADDR_LOOPBACK); length = sizeof(v4);
  } else {
    auto& v6 = reinterpret_cast<sockaddr_in6&>(address); v6.sin6_family = AF_INET6;
    v6.sin6_port = htons(port); v6.sin6_addr = in6addr_loopback; length = sizeof(v6);
  }
  require(::connect(peer.value,reinterpret_cast<sockaddr*>(&address),length) == 0);
  const auto fd = peer.value; peer.value = -1; return fd;
}
SocketListenOptions options(int family = AF_INET) {
  SocketListenOptions value; value.port = 0; value.address = family == AF_INET ? "127.0.0.1" : "::1"; return value;
}
std::unique_ptr<IncomingTransport> receive(ListenerSource& source) {
  auto deadline = steady_clock::now()+seconds(3);
  do { auto peer = source.wait(deadline); if (peer) return peer; } while (steady_clock::now()<deadline);
  return {};
}
template<class F> bool until(F predicate) {
  const auto deadline = steady_clock::now()+seconds(3);
  do { if (predicate()) return true; std::this_thread::sleep_for(milliseconds(1)); } while (steady_clock::now()<deadline);
  return predicate();
}
uint64_t incoming(const std::shared_ptr<ListenerWorker>& listener) {
  uint64_t id = 0;
  until([&] {
    ListenerEvent event;
    while (listener->events()->take(event)) {
      if (event.kind == ListenerEventKind::Incoming) id = event.peer->id;
    }
    return id != 0;
  });
  return id;
}
void exchange(SessionTransport& transport,int peer) {
  const char value = 'x'; require(testsock::sendBytes(peer,&value,1) == 1);
  ASSERT_TRUE(transport.wait(steady_clock::now()+seconds(2)).readable);
  ASSERT_TRUE(transport.input().hasData(1)); EXPECT_EQ(transport.input().readU8(),'x');
  transport.output().writeU8('y'); transport.flush();
  ASSERT_EQ(testsock::readable(peer,2000),1);
  char reply = 0; ASSERT_EQ(testsock::recvBytes(peer,&reply,1),1); EXPECT_EQ(reply,'y');
}
}
TEST(SocketListener, NumericIpv4AndIpv6PreserveTransportAndPeerIdentity)
{
  for (int family : {AF_INET,AF_INET6}) {
    auto source = prepareSocketListener(options(family)); auto addresses = source->start();
    ASSERT_EQ(addresses.size(),1u); EXPECT_NE(addresses[0].port,0);
    Descriptor peer(connectTo(addresses[0].port,family)); auto accepted = receive(*source);
    ASSERT_TRUE(accepted); EXPECT_EQ(accepted->peer.host,family == AF_INET ? "127.0.0.1" : "::1");
    EXPECT_NE(accepted->peer.port,0); source.reset(); exchange(*accepted->transport,peer.value);
  }
}
TEST(SocketListener, WildcardFamiliesShareEphemeralPortAndAcceptIndependently)
{
  auto settings = options(); settings.address.clear(); auto source = prepareSocketListener(settings);
  auto addresses = source->start(); ASSERT_EQ(addresses.size(),2u); EXPECT_EQ(addresses[0].port,addresses[1].port);
  Descriptor first(connectTo(addresses[0].port)), second(connectTo(addresses[1].port,AF_INET6));
  auto one = receive(*source), two = receive(*source); ASSERT_TRUE(one); ASSERT_TRUE(two);
  EXPECT_NE(one->peer.host,two->peer.host);
}
TEST(SocketListener, WakeDeadlineAndCancellationAreBoundedAndControlOutlivesSource)
{
  auto source = prepareSocketListener(options()); auto control = source->control(); source->start();
  control->wake(); EXPECT_FALSE(source->wait(steady_clock::now()+seconds(2)));
  auto before = steady_clock::now(); EXPECT_FALSE(source->wait(before+milliseconds(20)));
  EXPECT_GE(steady_clock::now()-before,milliseconds(15));
  std::atomic<bool> cancelled{false};
  std::thread worker([&] { try { source->wait(SessionTransport::TimePoint::max()); }
    catch (const ListenerError& error) { cancelled = error.code == ListenerErrorCode::Cancelled; } });
  control->cancel(); worker.join(); EXPECT_TRUE(cancelled);
  source.reset(); for (int i = 0; i < 1000; ++i) { control->wake(); control->cancel(); }
}
TEST(SocketListener, CancelBeforeStartAndSingleUseAreExplicit)
{
  auto source = prepareSocketListener(options()); source->control()->cancel();
  try { source->start(); FAIL(); } catch (const ListenerError& error) { EXPECT_EQ(error.code,ListenerErrorCode::Cancelled); }
  EXPECT_THROW(source->start(),std::logic_error);
  auto active = prepareSocketListener(options()); active->start(); EXPECT_THROW(active->start(),std::logic_error);
}
TEST(SocketListener, BindFailureHasNativeCodeAndReleasesPartialFamilyBinding)
{
  auto occupiedOptions = options(AF_INET6); occupiedOptions.address.clear(); occupiedOptions.ipv4 = false;
  auto occupied = prepareSocketListener(occupiedOptions); auto bound = occupied->start();
  SocketListenOptions settings; settings.port = bound[0].port;
  auto failing = prepareSocketListener(settings);
  try { failing->start(); FAIL(); } catch (const ListenerError& error) {
    EXPECT_EQ(error.code,ListenerErrorCode::Bind); EXPECT_NE(error.nativeError,0);
  }
  // IPv4 was bound first and must have been rolled back even while failing lives.
  auto v4 = options(); v4.port = bound[0].port;
  auto retry = prepareSocketListener(v4); ASSERT_EQ(retry->start().size(),1u);
}
TEST(SocketListener, InvalidAddressFamiliesAndBacklogRejectBeforeBinding)
{
  for (unsigned variant = 0; variant < 6; ++variant) {
    auto value = options();
    if (variant == 0) value.ipv4 = value.ipv6 = false;
    if (variant == 1) value.backlog = 0;
    if (variant == 2) value.backlog = 65;
    if (variant == 3) value.address = "localhost";
    if (variant == 4) value.ipv4 = false;
    if (variant == 5) value.address = std::string("127.0.0.1\0bad",13);
    EXPECT_THROW(prepareSocketListener(value),std::invalid_argument);
  }
}
TEST(SocketListener, ReversePeerEntersSessionOnlyAfterExplicitAcceptanceAndSurvivesListenerClose)
{
  ListenerRuntime listeners; SessionRuntime sessions;
  auto listener = listeners.listen(prepareSocketListener(options()));
  ASSERT_TRUE(until([&] { return listener->events()->snapshot().state == ListenerState::Listening; }));
  auto port = listener->events()->snapshot().addresses->front().port;
  Descriptor peer(connectTo(port)); auto id = incoming(listener); ASSERT_NE(id,0u);
  rdr::MemOutStream wire;
  wire.writeBytes(reinterpret_cast<const uint8_t*>("RFB 003.008\n"),12);
  wire.writeU8(1); wire.writeU8(rfb::secTypeNone); wire.writeU32(0);
  wire.writeU16(2); wire.writeU16(2); rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0).write(&wire);
  wire.writeU32(4); wire.writeBytes(reinterpret_cast<const uint8_t*>("peer"),4);
  ASSERT_EQ(testsock::sendBytes(peer.value,wire.data(),wire.length()),static_cast<long long>(wire.length()));
  EXPECT_EQ(testsock::readable(peer.value,20),0); // No protocol owner before accept.
  auto session = listener->accept(id,sessions,rfb::SecurityClient({rfb::secTypeNone})); ASSERT_TRUE(session);
  ASSERT_TRUE(until([&] { return session->events()->snapshot().state == SessionState::Connected; }));
  ASSERT_EQ(listener->closeAndDrain().wait_for(seconds(3)),std::future_status::ready);
  EXPECT_EQ(session->events()->snapshot().state,SessionState::Connected);
  EXPECT_EQ(session->events()->snapshot().width,2);
  EXPECT_FALSE(listener->accept(id,sessions,rfb::SecurityClient({rfb::secTypeNone})));
  ASSERT_EQ(session->closeAndDrain().wait_for(seconds(3)),std::future_status::ready);
}
TEST(SocketListener, RuntimeAdmissionFailureClosesConsumedPeerWithoutStoppingListener)
{
  ListenerRuntime listeners; SessionRuntime sessions; sessions.shutdown();
  auto listener = listeners.listen(prepareSocketListener(options()));
  ASSERT_TRUE(until([&] { return listener->events()->snapshot().state == ListenerState::Listening; }));
  Descriptor peer(connectTo(listener->events()->snapshot().addresses->front().port));
  auto id = incoming(listener); ASSERT_NE(id,0u);
  EXPECT_THROW(listener->accept(id,sessions,rfb::SecurityClient({rfb::secTypeNone})),std::logic_error);
  ASSERT_EQ(testsock::readable(peer.value,2000),1);
  char byte; EXPECT_EQ(testsock::recvBytes(peer.value,&byte,1),0);
  EXPECT_EQ(listener->events()->snapshot().state,ListenerState::Listening);
  EXPECT_EQ(listener->takePeer(id).status,PeerAdmission::NotPending);
}
#ifdef _WIN32
// SO_EXCLUSIVEADDRUSE: another socket cannot take over a listening port even
// with SO_REUSEADDR, which on Windows would otherwise allow it.
TEST(SocketListener, WindowsExclusiveAddressRefusesPortHijack)
{
  auto source = prepareSocketListener(options()); auto addresses = source->start();
  const SOCKET other = ::socket(AF_INET,SOCK_STREAM,IPPROTO_TCP); ASSERT_NE(other,INVALID_SOCKET);
  const BOOL one = TRUE;
  ::setsockopt(other,SOL_SOCKET,SO_REUSEADDR,reinterpret_cast<const char*>(&one),sizeof(one));
  sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = htons(addresses[0].port);
  EXPECT_EQ(::bind(other,reinterpret_cast<sockaddr*>(&address),sizeof(address)),SOCKET_ERROR);
  EXPECT_TRUE(::WSAGetLastError() == WSAEACCES || ::WSAGetLastError() == WSAEADDRINUSE);
  ::closesocket(other);
}
#endif
