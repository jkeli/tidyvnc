/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/ListenerWorker.h>
#include <rdr/MemInStream.h>
#include <rdr/MemOutStream.h>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
using namespace viewer;
using namespace std::chrono;
namespace {
struct Probe : TransportControl {
  void wake() noexcept override { std::lock_guard<std::mutex> lock(mutex); woken = true; changed.notify_all(); }
  void cancel() noexcept override { std::lock_guard<std::mutex> lock(mutex); cancelled = true; changed.notify_all(); }
  void release() { std::lock_guard<std::mutex> lock(mutex); holdStart = holdDispose = false; changed.notify_all(); }
  std::mutex mutex;
  std::condition_variable changed;
  bool cancelled = false, woken = false, holdStart = false, holdDispose = false, failStart = false, failWait = false;
  std::deque<std::unique_ptr<IncomingTransport>> incoming;
  std::atomic<bool> started{false}, disposing{false}, destroyed{false};
  std::atomic<unsigned> waits{0};
};
class Transport : public SessionTransport {
public:
  explicit Transport(std::shared_ptr<std::atomic<bool>> destroyed_) : destroyed(std::move(destroyed_)), in(reinterpret_cast<const uint8_t*>(""),0), token(new Probe) {}
  ~Transport() override { *destroyed = true; }
  rdr::InStream& input() override { return in; }
  rdr::OutStream& output() override { return out; }
  bool outputPending() override { return false; }
  void flush() override {}
  std::shared_ptr<TransportControl> control() const override { return token; }
  TransportReady wait(TimePoint, bool) override { TransportReady r; r.peerClosed = true; return r; }
  TransportReady waitPeerClosure(TimePoint) override { TransportReady r; r.peerClosed = true; return r; }
private:
  std::shared_ptr<std::atomic<bool>> destroyed;
  rdr::MemInStream in;
  rdr::MemOutStream out;
  std::shared_ptr<Probe> token;
};
class Source : public ListenerSource {
public:
  explicit Source(std::shared_ptr<Probe> probe_) : probe(std::move(probe_)) {}
  ~Source() override {
    std::unique_lock<std::mutex> lock(probe->mutex); probe->disposing = true;
    probe->changed.wait(lock,[&] { return !probe->holdDispose; }); probe->destroyed = true;
  }
  std::shared_ptr<TransportControl> control() const override { return probe; }
  std::vector<ListenerAddress> start() override {
    std::unique_lock<std::mutex> lock(probe->mutex); probe->started = true;
    probe->changed.wait(lock,[&] { return !probe->holdStart || probe->cancelled; });
    if (probe->cancelled) throw ListenerError(ListenerErrorCode::Cancelled);
    if (probe->failStart) throw ListenerError(ListenerErrorCode::Bind,98);
    ListenerAddress address; address.host = "127.0.0.1"; address.port = 5500; return {address};
  }
  std::unique_ptr<IncomingTransport> wait(SessionTransport::TimePoint deadline) override {
    std::unique_lock<std::mutex> lock(probe->mutex); ++probe->waits;
    probe->changed.wait_until(lock,deadline,[&] { return probe->cancelled || probe->woken || !probe->incoming.empty() || probe->failWait; });
    if (probe->cancelled) throw ListenerError(ListenerErrorCode::Cancelled);
    if (probe->failWait) throw ListenerError(ListenerErrorCode::Accept,5);
    probe->woken = false;
    if (probe->incoming.empty()) return {};
    auto result = std::move(probe->incoming.front()); probe->incoming.pop_front(); return result;
  }
private:
  std::shared_ptr<Probe> probe;
};
std::unique_ptr<ListenerSource> source(const std::shared_ptr<Probe>& probe) { return std::unique_ptr<ListenerSource>(new Source(probe)); }
std::shared_ptr<std::atomic<bool>> feed(const std::shared_ptr<Probe>& probe) {
  auto destroyed = std::make_shared<std::atomic<bool>>(false);
  std::unique_ptr<IncomingTransport> incoming(new IncomingTransport);
  incoming->peer.host = "127.0.0.1"; incoming->peer.port = 12345;
  incoming->transport.reset(new Transport(destroyed));
  std::lock_guard<std::mutex> lock(probe->mutex); probe->incoming.push_back(std::move(incoming)); probe->changed.notify_all(); return destroyed;
}
template<class F> bool until(F predicate) {
  auto deadline = steady_clock::now()+seconds(3);
  do { if (predicate()) return true; std::this_thread::sleep_for(milliseconds(1)); } while (steady_clock::now()<deadline);
  return predicate();
}
std::vector<ListenerEvent> take(const std::shared_ptr<ListenerEvents>& events) {
  std::vector<ListenerEvent> result; ListenerEvent event;
  while (events->take(event)) result.push_back(event);
  return result;
}
uint64_t incoming(const std::shared_ptr<ListenerEvents>& events) {
  uint64_t id = 0;
  until([&] { for (const auto& event : take(events)) if (event.kind == ListenerEventKind::Incoming) id = event.peer->id; return id != 0; });
  return id;
}
struct Release { std::shared_ptr<Probe> probe; ~Release() { probe->release(); } };
}
TEST(ListenerWorker, InitialSnapshotOrderedLifecycleAndRetainedEvents)
{
  ListenerRuntime runtime; auto probe = std::make_shared<Probe>(); probe->holdStart = true;
  auto listener = runtime.listen(source(probe)); auto events = listener->events(); Release release{probe};
  EXPECT_EQ(events->snapshot().state,ListenerState::Starting);
  auto initial = take(events); ASSERT_EQ(initial.size(),1u); EXPECT_EQ(initial[0].sequence,1u);
  probe->release(); ASSERT_TRUE(until([&] { return events->snapshot().state == ListenerState::Listening; }));
  auto addresses = events->snapshot().addresses; ASSERT_EQ(addresses->size(),1u);
  auto done = listener->drained(); listener.reset();
  ASSERT_EQ(done.wait_for(seconds(3)),std::future_status::ready);
  EXPECT_TRUE(probe->destroyed); EXPECT_EQ(done.get().state,ListenerState::Closed);
  auto transitions = take(events); ASSERT_EQ(transitions.size(),3u);
  EXPECT_EQ(transitions[0].snapshot.state,ListenerState::Listening);
  EXPECT_EQ(transitions[1].snapshot.state,ListenerState::Stopping);
  EXPECT_EQ(transitions[2].snapshot.state,ListenerState::Closed);
  EXPECT_EQ(transitions[2].sequence,4u); EXPECT_EQ(addresses->front().port,5500);
  EXPECT_EQ(runtime.active(),0u);
}
TEST(ListenerWorker, ExplicitOwnershipTransferAndDuplicateRejection)
{
  ListenerRuntime runtime; auto probe = std::make_shared<Probe>(); auto listener = runtime.listen(source(probe));
  auto destroyed = feed(probe); auto id = incoming(listener->events()); ASSERT_NE(id,0u);
  auto peer = listener->takePeer(id); EXPECT_EQ(peer.status,PeerAdmission::Accepted); ASSERT_TRUE(peer.transport);
  EXPECT_EQ(peer.peer->address.host,"127.0.0.1"); EXPECT_FALSE(*destroyed);
  EXPECT_EQ(listener->takePeer(id).status,PeerAdmission::NotPending);
  EXPECT_EQ(listener->reject(id),PeerAdmission::NotPending);
  ASSERT_EQ(listener->closeAndDrain().wait_for(seconds(3)),std::future_status::ready);
  EXPECT_FALSE(*destroyed); peer.transport.reset(); EXPECT_TRUE(*destroyed);
}
TEST(ListenerWorker, RejectAndTimeoutCloseOnlyUnclaimedPeers)
{
  ListenerRuntime runtime; ListenerOptions options; options.pendingTimeout = milliseconds(100);
  auto probe = std::make_shared<Probe>(); auto listener = runtime.listen(source(probe),options);
  auto first = feed(probe); auto id = incoming(listener->events()); ASSERT_NE(id,0u);
  EXPECT_EQ(listener->reject(id),PeerAdmission::Accepted); EXPECT_TRUE(*first);
  auto second = feed(probe); auto later = incoming(listener->events()); ASSERT_GT(later,id);
  ASSERT_TRUE(until([&] { return second->load(); }));
  bool expired = false;
  for (const auto& event : take(listener->events())) if (event.kind == ListenerEventKind::Expired) { expired = true; EXPECT_EQ(event.peer->id,later); }
  EXPECT_TRUE(expired); EXPECT_EQ(listener->takePeer(later).status,PeerAdmission::NotPending);
  EXPECT_EQ(listener->events()->snapshot().pending,0u);
}
TEST(ListenerWorker, PendingCapacityPausesAcceptanceUntilHostDecision)
{
  ListenerRuntime runtime; ListenerOptions options; options.pendingCapacity = 1;
  auto probe = std::make_shared<Probe>(); auto listener = runtime.listen(source(probe),options);
  auto first = feed(probe); auto id = incoming(listener->events()); ASSERT_NE(id,0u);
  auto second = feed(probe);
  { std::lock_guard<std::mutex> lock(probe->mutex); EXPECT_EQ(probe->incoming.size(),1u); }
  EXPECT_EQ(listener->events()->snapshot().pending,1u);
  EXPECT_EQ(listener->reject(id),PeerAdmission::Accepted);
  auto next = incoming(listener->events()); ASSERT_GT(next,id); EXPECT_TRUE(*first); EXPECT_FALSE(*second);
  ASSERT_EQ(listener->closeAndDrain().wait_for(seconds(3)),std::future_status::ready); EXPECT_TRUE(*second);
}
TEST(ListenerWorker, EventOverflowPreservesQueuedEventsAndTerminalSlots)
{
  ListenerRuntime runtime; ListenerOptions options; options.eventCapacity = 4;
  auto probe = std::make_shared<Probe>(); auto first = feed(probe); auto second = feed(probe); auto third = feed(probe);
  auto listener = runtime.listen(source(probe),options);
  ASSERT_EQ(listener->drained().wait_for(seconds(3)),std::future_status::ready);
  auto result = listener->drained().get(); EXPECT_EQ(result.state,ListenerState::Failed);
  EXPECT_EQ(result.error,ListenerErrorCode::EventOverflow); EXPECT_TRUE(*first); EXPECT_TRUE(*second); EXPECT_TRUE(*third);
  auto events = take(listener->events()); ASSERT_EQ(events.size(),6u);
  for (size_t i = 0; i < events.size(); ++i) EXPECT_EQ(events[i].sequence,i+1);
  EXPECT_EQ(events[4].snapshot.state,ListenerState::Stopping); EXPECT_EQ(events[5].snapshot.state,ListenerState::Failed);
  EXPECT_EQ(events[5].snapshot.pending,0u);
}
TEST(ListenerWorker, CancellationInterruptsStartingAndDrainWaitsForDisposal)
{
  ListenerRuntime runtime; auto probe = std::make_shared<Probe>(); probe->holdStart = probe->holdDispose = true;
  auto listener = runtime.listen(source(probe)); Release release{probe};
  ASSERT_TRUE(until([&] { return probe->started.load(); }));
  auto done = listener->closeAndDrain();
  ASSERT_TRUE(until([&] { return probe->disposing.load(); }));
  EXPECT_EQ(done.wait_for(milliseconds(10)),std::future_status::timeout);
  EXPECT_EQ(listener->takePeer(1).status,PeerAdmission::Closing);
  probe->release(); ASSERT_EQ(done.wait_for(seconds(3)),std::future_status::ready);
  EXPECT_EQ(done.get().state,ListenerState::Closed); EXPECT_TRUE(probe->destroyed);
  EXPECT_EQ(listener->closeAndDrain().wait_for(milliseconds(0)),std::future_status::ready);
}
TEST(ListenerWorker, BindAndAcceptFailuresRetainTypedNativeCodes)
{
  for (bool bind : {true,false}) {
    ListenerRuntime runtime; auto probe = std::make_shared<Probe>(); probe->failStart = bind; probe->failWait = !bind;
    auto listener = runtime.listen(source(probe));
    ASSERT_EQ(listener->drained().wait_for(seconds(3)),std::future_status::ready);
    auto result = listener->drained().get(); EXPECT_EQ(result.state,ListenerState::Failed);
    EXPECT_EQ(result.error,bind ? ListenerErrorCode::Bind : ListenerErrorCode::Accept);
    EXPECT_EQ(result.nativeError,bind ? 98 : 5); EXPECT_TRUE(probe->destroyed);
  }
}
TEST(ListenerWorker, RuntimeCapacityAndShutdownDrainAllListeners)
{
  ListenerRuntime runtime(2); auto one = runtime.listen(source(std::make_shared<Probe>()));
  auto two = runtime.listen(source(std::make_shared<Probe>())); auto rejected = std::make_shared<Probe>();
  EXPECT_THROW(runtime.listen(source(rejected)),std::length_error); EXPECT_TRUE(rejected->destroyed);
  runtime.shutdown(); EXPECT_THROW(runtime.listen(source(std::make_shared<Probe>())),std::logic_error);
  ASSERT_EQ(runtime.drained().wait_for(seconds(3)),std::future_status::ready);
  EXPECT_EQ(runtime.active(),0u); EXPECT_EQ(one->drained().get().state,ListenerState::Closed);
  EXPECT_EQ(two->drained().get().state,ListenerState::Closed);
}
TEST(ListenerWorker, ConcurrentDecisionsTransferEachPeerExactlyOnce)
{
  ListenerRuntime runtime; ListenerOptions options; options.eventCapacity = 64;
  auto probe = std::make_shared<Probe>(); auto listener = runtime.listen(source(probe),options);
  for (int n = 0; n < 12; ++n) {
    auto destroyed = feed(probe); auto id = incoming(listener->events()); ASSERT_NE(id,0u);
    std::atomic<unsigned> accepted{0};
    auto consume = [&] { auto result = listener->takePeer(id); if (result.status == PeerAdmission::Accepted) ++accepted; };
    std::thread one(consume), two(consume); one.join(); two.join();
    EXPECT_EQ(accepted,1u); EXPECT_TRUE(*destroyed);
  }
}
TEST(ListenerWorker, InvalidOptionsRejectWithoutAdmitting)
{
  EXPECT_THROW(ListenerRuntime(0),std::invalid_argument);
  EXPECT_THROW(ListenerRuntime(17),std::invalid_argument);
  ListenerRuntime runtime;
  for (unsigned variant = 0; variant < 6; ++variant) {
    ListenerOptions options;
    if (variant == 0) options.pendingCapacity = 0;
    if (variant == 1) options.pendingCapacity = 65;
    if (variant == 2) options.eventCapacity = 3;
    if (variant == 3) options.eventCapacity = 4097;
    if (variant == 4) options.pendingTimeout = milliseconds(0);
    if (variant == 5) options.pendingTimeout = milliseconds(60001);
    auto probe = std::make_shared<Probe>();
    EXPECT_THROW(runtime.listen(source(probe),options),std::invalid_argument); EXPECT_TRUE(probe->destroyed);
  }
  EXPECT_THROW(runtime.listen({}),std::invalid_argument); EXPECT_EQ(runtime.active(),0u);
}

TEST(ListenerWorker, DecisionEventCapacityRejectsBeforeOwnershipTransfer)
{
  ListenerRuntime runtime; ListenerOptions options; options.eventCapacity = 4;
  auto probe = std::make_shared<Probe>(); auto first = feed(probe); auto second = feed(probe);
  auto listener = runtime.listen(source(probe),options);
  ASSERT_TRUE(until([&] { return listener->events()->snapshot().pending == 2; }));
  auto result = listener->takePeer(1);
  EXPECT_EQ(result.status,PeerAdmission::EventCapacity); EXPECT_FALSE(result.transport);
  ASSERT_EQ(listener->drained().wait_for(seconds(3)),std::future_status::ready);
  EXPECT_EQ(listener->drained().get().error,ListenerErrorCode::EventOverflow);
  EXPECT_TRUE(*first); EXPECT_TRUE(*second);
}
TEST(ListenerWorker, ExpiryReopensFullPendingQueueWithoutHostWake)
{
  ListenerRuntime runtime; ListenerOptions options; options.pendingCapacity = 1; options.pendingTimeout = milliseconds(100);
  auto probe = std::make_shared<Probe>(); auto listener = runtime.listen(source(probe),options);
  auto first = feed(probe); auto id = incoming(listener->events()); ASSERT_NE(id,0u);
  auto second = feed(probe); auto next = incoming(listener->events()); ASSERT_GT(next,id);
  EXPECT_TRUE(*first); EXPECT_FALSE(*second);
  EXPECT_EQ(listener->reject(next),PeerAdmission::Accepted); EXPECT_TRUE(*second);
}

TEST(ListenerWorker, ConsumerOutputDisposalCanReenterTheEventStream)
{
  ListenerRuntime runtime; auto listener = runtime.listen(source(std::make_shared<Probe>()));
  auto events = listener->events(); bool disposed = false;
  ListenerEvent event;
  event.peer = std::shared_ptr<const IncomingPeer>(new IncomingPeer,[&](const IncomingPeer* peer) {
    events->snapshot(); disposed = true; delete peer;
  });
  ASSERT_TRUE(events->take(event)); EXPECT_TRUE(disposed);
}
TEST(ListenerWorker, ReadinessWakeReentersSnapshotOutsideListenerLocks)
{
  struct Wake : MailboxWakeup {
    std::mutex mutex;
    std::weak_ptr<ListenerEvents> events;
    std::atomic<unsigned> observed{0};
    void wake() noexcept override {
      std::shared_ptr<ListenerEvents> live;
      { std::lock_guard<std::mutex> lock(mutex); live = events.lock(); }
      if (live) { (void)live->snapshot(); ++observed; }
    }
  };
  ListenerRuntime runtime; auto probe = std::make_shared<Probe>(); auto wake = std::make_shared<Wake>();
  ListenerOptions options; options.mailboxWakeup = wake;
  auto listener = runtime.listen(source(probe),options);
  { std::lock_guard<std::mutex> lock(wake->mutex); wake->events = listener->events(); }
  auto disposed = feed(probe); const auto id = incoming(listener->events()); ASSERT_NE(id,0u);
  ASSERT_TRUE(until([&] { return wake->observed.load() > 0; }));
  auto previous = wake->observed.load(); EXPECT_EQ(listener->reject(id),PeerAdmission::Accepted);
  EXPECT_GT(wake->observed.load(),previous); EXPECT_TRUE(disposed->load());
  previous = wake->observed.load(); listener->closeAndDrain().wait();
  EXPECT_GT(wake->observed.load(),previous);
}
