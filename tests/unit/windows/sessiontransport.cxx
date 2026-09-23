/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Windows counterpart of tests/unit/sessiontransport.cxx: the same contract
// cases against viewer/platform/windows/SocketTransport.cxx, using loopback
// TCP pairs (Winsock has no socketpair). Descriptor checks become Winsock
// handle checks: closed means WSAENOTSOCK, private means not inheritable.
#include <gtest/gtest.h>
#include <viewer/platform/SocketTransport.h>
#include <viewer/core/SessionScheduler.h>
#include <network/Socket.h>
#include <rdr/InStream.h>
#include <rdr/OutStream.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <future>
#include <system_error>
#include <thread>
#include <vector>

using namespace viewer;
using namespace std::chrono;
namespace {
void require(bool okay) { if (!okay) throw std::runtime_error("Socket fixture failed"); }
struct Descriptor {
  explicit Descriptor(SOCKET value_ = INVALID_SOCKET) : value(value_) {}
  ~Descriptor() { if (value != INVALID_SOCKET) ::closesocket(value); }
  SOCKET value;
};
class TestSocket : public network::Socket {
public:
  explicit TestSocket(int fd) : Socket(fd) {}
  const char* getPeerAddress() override { return "fixture"; }
  const char* getPeerEndpoint() override { return "fixture"; }
};
bool closedHandle(SOCKET socket)
{
  int type = 0, size = sizeof(type);
  return ::getsockopt(socket, SOL_SOCKET, SO_TYPE, reinterpret_cast<char*>(&type), &size) == SOCKET_ERROR &&
    ::WSAGetLastError() == WSAENOTSOCK;
}
// Connected loopback TCP pair; the client end is adopted by the transport.
void connectedPair(SOCKET& client, SOCKET& server)
{
  network::initSockets();
  Descriptor listener(::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)); require(listener.value != INVALID_SOCKET);
  sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  require(::bind(listener.value, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
  int length = sizeof(address);
  require(::getsockname(listener.value, reinterpret_cast<sockaddr*>(&address), &length) == 0);
  require(::listen(listener.value, 1) == 0);
  Descriptor out(::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)); require(out.value != INVALID_SOCKET);
  require(::connect(out.value, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
  server = ::accept(listener.value, nullptr, nullptr); require(server != INVALID_SOCKET);
  client = out.value; out.value = INVALID_SOCKET;
}
struct Pair {
  Pair()
  {
    SOCKET client, server;
    connectedPair(client, server);
    peer.value = server; raw = client;
    std::unique_ptr<network::Socket> socket(new TestSocket(static_cast<int>(client)));
    transport = adoptSocketTransport(std::move(socket));
  }
  void send(uint8_t byte) { require(::send(peer.value, reinterpret_cast<const char*>(&byte), 1, 0) == 1); }
  Descriptor peer;
  SOCKET raw = INVALID_SOCKET;
  std::unique_ptr<SessionTransport> transport;
};
}

TEST(SessionTransport, OwnsNonblockingSocketAndExchangesBytes)
{
  Pair pair;
  DWORD flags = 0;
  ASSERT_TRUE(::GetHandleInformation(reinterpret_cast<HANDLE>(pair.raw), &flags));
  EXPECT_EQ(flags & HANDLE_FLAG_INHERIT, 0u);
  pair.send(17);
  auto ready = pair.transport->wait(steady_clock::now() + seconds(2));
  EXPECT_TRUE(ready.readable); EXPECT_FALSE(ready.writable);
  ASSERT_TRUE(pair.transport->input().hasData(1));
  EXPECT_EQ(pair.transport->input().readU8(), 17);
  pair.transport->output().writeU8(42);
  EXPECT_TRUE(pair.transport->outputPending());
  pair.transport->flush(); EXPECT_FALSE(pair.transport->outputPending());
  char reply = 0;
  ASSERT_EQ(::recv(pair.peer.value, &reply, 1, 0), 1); EXPECT_EQ(reply, 42);
  const SOCKET owned = pair.raw;
  pair.transport.reset();
  EXPECT_TRUE(closedHandle(owned));
  EXPECT_EQ(::recv(pair.peer.value, &reply, 1, 0), 0);
}

TEST(SessionTransport, WritableInterestIsExplicitAndDeadlinesAreAbsolute)
{
  Pair pair;
  auto ready = pair.transport->wait(SessionTransport::TimePoint::min());
  EXPECT_TRUE(ready.timedOut); EXPECT_FALSE(ready.writable);
  ready = pair.transport->wait(steady_clock::now(), true);
  EXPECT_TRUE(ready.writable); EXPECT_FALSE(ready.timedOut);
  const auto deadline = steady_clock::now() + milliseconds(20);
  ready = pair.transport->wait(deadline);
  EXPECT_TRUE(ready.timedOut); EXPECT_GE(steady_clock::now(), deadline);
  EXPECT_TRUE(pair.transport->waitPeerClosure(SessionTransport::TimePoint::min()).timedOut);
}

TEST(SessionTransport, WakeBeforeWaitAndFloodedNotificationsAreBounded)
{
  Pair pair;
  auto token = pair.transport->control();
  for (int i = 0; i < 100000; ++i) token->wake();
  auto ready = pair.transport->wait(steady_clock::now());
  EXPECT_TRUE(ready.woken); EXPECT_FALSE(ready.readable);
  // Auto-reset events coalesce every earlier notification into one.
  int drains = 0;
  while (pair.transport->wait(steady_clock::now()).woken && drains < 128) ++drains;
  EXPECT_LT(drains, 128);
  token->wake(); EXPECT_TRUE(pair.transport->wait(steady_clock::now()).woken);
}

TEST(SessionTransport, WakeInterruptsSleepingWorkerAndSchedulerUsesSameControl)
{
  Pair pair;
  SessionScheduler scheduler(4, pair.transport->control());
  std::promise<void> started;
  auto worker = std::async(std::launch::async, [&] {
    started.set_value();
    return pair.transport->wait(steady_clock::now() + seconds(3));
  });
  started.get_future().wait();
  bool called = false;
  scheduler.scheduleAt(steady_clock::now(), [&] { called = true; });
  ASSERT_EQ(worker.wait_for(seconds(1)), std::future_status::ready);
  EXPECT_TRUE(worker.get().woken);
  EXPECT_EQ(scheduler.dispatchDue(steady_clock::now()), 1u); EXPECT_TRUE(called);
}

TEST(SessionTransport, PeerObserverIgnoresUnreadDataAndWorkerWakeThenDetectsFin)
{
  Pair pair;
  pair.send(73);
  auto observer = std::async(std::launch::async, [&] {
    return pair.transport->waitPeerClosure(steady_clock::now() + seconds(3));
  });
  pair.transport->control()->wake();
  EXPECT_EQ(observer.wait_for(milliseconds(30)), std::future_status::timeout);
  require(::shutdown(pair.peer.value, SD_SEND) == 0);
  ASSERT_EQ(observer.wait_for(seconds(1)), std::future_status::ready);
  EXPECT_TRUE(observer.get().peerClosed);
  EXPECT_TRUE(pair.transport->waitPeerClosure(steady_clock::now()).peerClosed);
  auto ready = pair.transport->wait(steady_clock::now());
  EXPECT_TRUE(ready.peerClosed); EXPECT_TRUE(ready.readable);
  ASSERT_TRUE(pair.transport->input().hasData(1));
  EXPECT_EQ(pair.transport->input().readU8(), 73); // Observer consumed no bytes.
}

TEST(SessionTransport, PeerObserverSeesFinWhileWorkerWaits)
{
  // Both waiters share one Winsock event association; whichever pumps it
  // must hand the change to the other.
  Pair pair;
  const auto deadline = steady_clock::now() + seconds(3);
  auto worker = std::async(std::launch::async, [&] { return pair.transport->wait(deadline); });
  auto observer = std::async(std::launch::async, [&] { return pair.transport->waitPeerClosure(deadline); });
  std::this_thread::sleep_for(milliseconds(20));
  require(::shutdown(pair.peer.value, SD_SEND) == 0);
  ASSERT_EQ(observer.wait_for(seconds(1)), std::future_status::ready);
  ASSERT_EQ(worker.wait_for(seconds(1)), std::future_status::ready);
  EXPECT_TRUE(observer.get().peerClosed);
  const auto ready = worker.get();
  EXPECT_TRUE(ready.readable || ready.peerClosed);
}

TEST(SessionTransport, PeerDeadlineDoesNotConsumeQueuedBytes)
{
  Pair pair;
  pair.send(5);
  const auto deadline = steady_clock::now() + milliseconds(20);
  EXPECT_TRUE(pair.transport->waitPeerClosure(deadline).timedOut);
  EXPECT_GE(steady_clock::now(), deadline);
  ASSERT_TRUE(pair.transport->input().hasData(1));
  EXPECT_EQ(pair.transport->input().readU8(), 5);
  require(::shutdown(pair.peer.value, SD_BOTH) == 0);
  EXPECT_TRUE(pair.transport->waitPeerClosure(steady_clock::now() + seconds(1)).peerClosed);
}

TEST(SessionTransport, CancellationWakesBothWaitersAndRemainsSticky)
{
  Pair pair;
  auto deadline = steady_clock::now() + seconds(3);
  auto worker = std::async(std::launch::async, [&] { return pair.transport->wait(deadline); });
  auto observer = std::async(std::launch::async, [&] { return pair.transport->waitPeerClosure(deadline); });
  auto token = pair.transport->control();
  std::vector<std::thread> producers;
  for (int i = 0; i < 8; ++i)
    producers.emplace_back([&] { for (int j = 0; j < 100; ++j) { token->cancel(); token->wake(); } });
  for (auto& producer : producers) producer.join();
  ASSERT_EQ(worker.wait_for(seconds(1)), std::future_status::ready);
  ASSERT_EQ(observer.wait_for(seconds(1)), std::future_status::ready);
  EXPECT_TRUE(worker.get().cancelled); EXPECT_TRUE(observer.get().cancelled);
  EXPECT_TRUE(pair.transport->wait(SessionTransport::TimePoint::max()).cancelled);
  EXPECT_TRUE(pair.transport->waitPeerClosure(SessionTransport::TimePoint::max()).cancelled);
}

TEST(SessionTransport, OldControlCannotCancelLaterTransports)
{
  // Windows does not promise immediate handle reuse (the POSIX case asserts
  // it); a stale control must still be harmless for whatever comes next.
  std::shared_ptr<TransportControl> stale;
  {
    Pair old;
    stale = old.transport->control();
  }
  Pair next;
  stale->wake(); stale->cancel(); stale->cancel();
  EXPECT_TRUE(next.transport->wait(steady_clock::now()).timedOut);
  next.send(11);
  ASSERT_TRUE(next.transport->input().hasData(1) ||
              next.transport->wait(steady_clock::now() + seconds(1)).readable);
  ASSERT_TRUE(next.transport->input().hasData(1));
  EXPECT_EQ(next.transport->input().readU8(), 11);
}

TEST(SessionTransport, ControlDoesNotKeepResourcesAliveAndRacesDestructionSafely)
{
  Pair pair;
  const SOCKET fd = pair.raw;
  auto token = pair.transport->control();
  auto producer = std::async(std::launch::async, [&] {
    for (int i = 0; i < 10000; ++i) { token->wake(); token->cancel(); }
  });
  pair.transport.reset(); producer.get();
  EXPECT_TRUE(closedHandle(fd));
  token->wake(); token->cancel();
}

TEST(SessionTransport, BackpressureDrainsOnlyOnWritableInterest)
{
  Pair pair;
  int size = 4096;
  require(::setsockopt(pair.raw, SOL_SOCKET, SO_SNDBUF, reinterpret_cast<const char*>(&size), sizeof(size)) == 0);
  require(::setsockopt(pair.peer.value, SOL_SOCKET, SO_RCVBUF, reinterpret_cast<const char*>(&size), sizeof(size)) == 0);
  std::vector<uint8_t> bytes(16 * 1024 * 1024);
  for (size_t i = 0; i < bytes.size(); ++i) bytes[i] = static_cast<uint8_t>(i % 251);
  pair.transport->output().writeBytes(bytes.data(), bytes.size());
  pair.transport->flush(); ASSERT_TRUE(pair.transport->outputPending());
  EXPECT_TRUE(pair.transport->wait(steady_clock::now()).timedOut);
  auto receiver = std::async(std::launch::async, [&] {
    std::vector<uint8_t> received(bytes.size());
    size_t count = 0;
    while (count < received.size()) {
      WSAPOLLFD event{pair.peer.value, POLLRDNORM, 0};
      require(::WSAPoll(&event, 1, 3000) == 1);
      const int chunk = static_cast<int>(std::min<size_t>(received.size() - count, 1 << 20));
      auto got = ::recv(pair.peer.value, reinterpret_cast<char*>(received.data() + count), chunk, 0);
      require(got > 0); count += static_cast<size_t>(got);
    }
    return received;
  });
  const auto deadline = steady_clock::now() + seconds(10);
  while (pair.transport->outputPending()) {
    const auto ready = pair.transport->wait(deadline, true);
    ASSERT_FALSE(ready.timedOut); ASSERT_TRUE(ready.writable);
    pair.transport->flush();
  }
  EXPECT_EQ(receiver.get(), bytes);
}

TEST(SessionTransport, FailedAdoptionClosesOwnedSocket)
{
  network::initSockets();
  EXPECT_THROW(adoptSocketTransport(nullptr), std::invalid_argument);
  const SOCKET unconnected = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP); ASSERT_NE(unconnected, INVALID_SOCKET);
  EXPECT_THROW(adoptSocketTransport(std::unique_ptr<network::Socket>(new TestSocket(static_cast<int>(unconnected)))),
               std::system_error);
  EXPECT_TRUE(closedHandle(unconnected));
  const SOCKET datagram = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP); ASSERT_NE(datagram, INVALID_SOCKET);
  EXPECT_THROW(adoptSocketTransport(std::unique_ptr<network::Socket>(new TestSocket(static_cast<int>(datagram)))),
               std::invalid_argument);
  EXPECT_TRUE(closedHandle(datagram));
}

TEST(SessionTransport, RejectsListeningSockets)
{
  network::initSockets();
  const SOCKET listening = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP); ASSERT_NE(listening, INVALID_SOCKET);
  sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  ASSERT_EQ(::bind(listening, reinterpret_cast<sockaddr*>(&address), sizeof(address)), 0);
  ASSERT_EQ(::listen(listening, 1), 0);
  EXPECT_THROW(adoptSocketTransport(std::unique_ptr<network::Socket>(new TestSocket(static_cast<int>(listening)))),
               std::system_error);
  EXPECT_TRUE(closedHandle(listening));
}

TEST(SessionTransport, SessionsAndConcurrentSocketInitializationAreIndependent)
{
  std::vector<std::future<void>> workers;
  for (int i = 0; i < 8; ++i) workers.push_back(std::async(std::launch::async, [] {
    for (int j = 0; j < 20; ++j) {
      Pair a, b;
      a.transport->control()->cancel();
      require(a.transport->wait(steady_clock::now()).cancelled);
      b.send(27);
      require(b.transport->wait(steady_clock::now() + seconds(1)).readable);
      require(b.transport->input().hasData(1));
      require(b.transport->input().readU8() == 27);
    }
  }));
  for (auto& worker : workers) EXPECT_NO_THROW(worker.get());
}
