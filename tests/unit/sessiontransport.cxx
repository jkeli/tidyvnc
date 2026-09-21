/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/platform/SocketTransport.h>
#include <viewer/core/SessionScheduler.h>
#include <network/Socket.h>
#include <rdr/InStream.h>
#include <rdr/OutStream.h>
#include <cerrno>
#include <future>
#include <system_error>
#include <thread>
#include <vector>
#include <fcntl.h>
#include <poll.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

using namespace viewer;
using namespace std::chrono;
namespace {
void require(bool okay) { if (!okay) throw std::runtime_error("Socket fixture failed"); }
struct Descriptor {
  explicit Descriptor(int value_ = -1) : value(value_) {}
  ~Descriptor() { if (value >= 0) ::close(value); }
  int value;
};
class TestSocket : public network::Socket {
public:
  explicit TestSocket(int fd) : Socket(fd) {}
  const char* getPeerAddress() override { return "fixture"; }
  const char* getPeerEndpoint() override { return "fixture"; }
};
struct Pair {
  Pair()
  {
    int fds[2];
    require(::socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
    Descriptor client(fds[0]); peer.value = fds[1]; raw = client.value;
    std::unique_ptr<network::Socket> socket(new TestSocket(client.value));
    client.value = -1;
    transport = adoptSocketTransport(std::move(socket));
  }
  void send(uint8_t byte) { require(::send(peer.value, &byte, 1, 0) == 1); }
  Descriptor peer;
  int raw = -1;
  std::unique_ptr<SessionTransport> transport;
};
}

TEST(SessionTransport, OwnsNonblockingSocketAndExchangesBytes)
{
  Pair pair;
  EXPECT_NE(::fcntl(pair.raw, F_GETFL) & O_NONBLOCK, 0);
  EXPECT_NE(::fcntl(pair.raw, F_GETFD) & FD_CLOEXEC, 0);
  pair.send(17);
  auto ready = pair.transport->wait(steady_clock::now() + seconds(2));
  EXPECT_TRUE(ready.readable); EXPECT_FALSE(ready.writable);
  ASSERT_TRUE(pair.transport->input().hasData(1));
  EXPECT_EQ(pair.transport->input().readU8(), 17);
  pair.transport->output().writeU8(42);
  EXPECT_TRUE(pair.transport->outputPending());
  pair.transport->flush(); EXPECT_FALSE(pair.transport->outputPending());
  uint8_t reply = 0;
  ASSERT_EQ(::recv(pair.peer.value, &reply, 1, 0), 1); EXPECT_EQ(reply, 42);
  const int owned = pair.raw;
  pair.transport.reset();
  EXPECT_EQ(::fcntl(owned, F_GETFD), -1); EXPECT_EQ(errno, EBADF);
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
  // Pipe capacity is bounded; extra wake notifications may be coalesced.
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
  require(::shutdown(pair.peer.value, SHUT_WR) == 0);
  ASSERT_EQ(observer.wait_for(seconds(1)), std::future_status::ready);
  EXPECT_TRUE(observer.get().peerClosed);
  EXPECT_TRUE(pair.transport->waitPeerClosure(steady_clock::now()).peerClosed);
  auto ready = pair.transport->wait(steady_clock::now());
  EXPECT_TRUE(ready.peerClosed); EXPECT_TRUE(ready.readable);
  ASSERT_TRUE(pair.transport->input().hasData(1));
  EXPECT_EQ(pair.transport->input().readU8(), 73); // Observer consumed no bytes.
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
  require(::shutdown(pair.peer.value, SHUT_RDWR) == 0);
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

TEST(SessionTransport, OldControlCannotCancelReusedDescriptor)
{
  std::shared_ptr<TransportControl> stale;
  int oldFd;
  {
    Pair old;
    oldFd = old.raw; stale = old.transport->control();
  }
  Pair next;
  ASSERT_EQ(next.raw, oldFd); // Exercise an actual OS descriptor reuse.
  stale->wake(); stale->cancel(); stale->cancel();
  EXPECT_TRUE(next.transport->wait(steady_clock::now()).timedOut);
  next.send(11);
  ASSERT_TRUE(next.transport->input().hasData(1));
  EXPECT_EQ(next.transport->input().readU8(), 11);
}

TEST(SessionTransport, ControlDoesNotKeepResourcesAliveAndRacesDestructionSafely)
{
  Pair pair;
  const int fd = pair.raw;
  auto token = pair.transport->control();
  auto producer = std::async(std::launch::async, [&] {
    for (int i = 0; i < 10000; ++i) { token->wake(); token->cancel(); }
  });
  pair.transport.reset(); producer.get();
  EXPECT_EQ(::fcntl(fd, F_GETFD), -1); EXPECT_EQ(errno, EBADF);
  token->wake(); token->cancel();
}

TEST(SessionTransport, BackpressureDrainsOnlyOnWritableInterest)
{
  Pair pair;
  int size = 4096;
  require(::setsockopt(pair.raw, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) == 0);
  std::vector<uint8_t> bytes(2 * 1024 * 1024);
  for (size_t i = 0; i < bytes.size(); ++i) bytes[i] = i % 251;
  pair.transport->output().writeBytes(bytes.data(), bytes.size());
  pair.transport->flush(); ASSERT_TRUE(pair.transport->outputPending());
  EXPECT_TRUE(pair.transport->wait(steady_clock::now()).timedOut);
  auto receiver = std::async(std::launch::async, [&] {
    std::vector<uint8_t> received(bytes.size());
    size_t count = 0;
    while (count < received.size()) {
      pollfd event{pair.peer.value, POLLIN, 0};
      require(::poll(&event, 1, 3000) == 1);
      auto got = ::recv(pair.peer.value, received.data() + count, received.size() - count, 0);
      require(got > 0); count += got;
    }
    return received;
  });
  const auto deadline = steady_clock::now() + seconds(3);
  while (pair.transport->outputPending()) {
    const auto ready = pair.transport->wait(deadline, true);
    ASSERT_FALSE(ready.timedOut); ASSERT_TRUE(ready.writable);
    pair.transport->flush();
  }
  EXPECT_EQ(receiver.get(), bytes);
}

TEST(SessionTransport, FailedAdoptionClosesOwnedSocket)
{
  EXPECT_THROW(adoptSocketTransport(nullptr), std::invalid_argument);
  int fd = ::socket(AF_INET, SOCK_STREAM, 0); ASSERT_GE(fd, 0);
  EXPECT_THROW(adoptSocketTransport(std::unique_ptr<network::Socket>(new TestSocket(fd))), std::system_error);
  EXPECT_EQ(::fcntl(fd, F_GETFD), -1); EXPECT_EQ(errno, EBADF);
  int fds[2]; ASSERT_EQ(::socketpair(AF_UNIX, SOCK_DGRAM, 0, fds), 0);
  Descriptor peer(fds[1]);
  EXPECT_THROW(adoptSocketTransport(std::unique_ptr<network::Socket>(new TestSocket(fds[0]))), std::invalid_argument);
  EXPECT_EQ(::fcntl(fds[0], F_GETFD), -1); EXPECT_EQ(errno, EBADF);
}

TEST(SessionTransport, RejectsDescriptorsUnsafeForLegacyStreams)
{
  Pair pair;
  int high = ::fcntl(pair.raw, F_DUPFD, FD_SETSIZE);
  if (high < 0) GTEST_SKIP() << "Process descriptor limit below FD_SETSIZE";
  EXPECT_THROW(adoptSocketTransport(std::unique_ptr<network::Socket>(new TestSocket(high))), std::invalid_argument);
  EXPECT_EQ(::fcntl(high, F_GETFD), -1); EXPECT_EQ(errno, EBADF);
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
