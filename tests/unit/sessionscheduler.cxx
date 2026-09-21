/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/core/SessionScheduler.h>
#include <gtest/gtest.h>
#include <atomic>
#include <future>
#include <thread>
#include <vector>

using namespace viewer;
namespace {
const SessionScheduler::TimePoint epoch{};
const auto tick = std::chrono::milliseconds(1);
struct Wake : SchedulerWakeup {
  std::atomic<unsigned> count{0};
  std::function<void()> inspect;
  void wake() noexcept override { ++count; if (inspect) inspect(); }
};
struct OnDestroy {
  std::function<void()> action;
  ~OnDestroy() { action(); }
};
}

TEST(SessionScheduler, DeadlineOrderAndEqualDeadlineFifo)
{
  SessionScheduler scheduler;
  std::vector<int> order;
  scheduler.scheduleAt(epoch + 3*tick, [&] { order.push_back(3); });
  scheduler.scheduleAt(epoch + tick, [&] { order.push_back(1); });
  scheduler.scheduleAt(epoch + tick, [&] { order.push_back(2); });
  SessionScheduler::TimePoint deadline;
  ASSERT_TRUE(scheduler.nextDeadline(deadline)); EXPECT_EQ(deadline, epoch + tick);
  EXPECT_EQ(scheduler.dispatchDue(epoch), 0u);
  EXPECT_EQ(scheduler.dispatchDue(epoch + tick), 2u);
  EXPECT_EQ(order, (std::vector<int>{1, 2}));
  EXPECT_EQ(scheduler.dispatchDue(epoch + 3*tick), 1u);
  EXPECT_EQ(order, (std::vector<int>{1, 2, 3}));
  EXPECT_FALSE(scheduler.nextDeadline(deadline));
}

TEST(SessionScheduler, CapacityCancellationAndTokenIdentity)
{
  SessionScheduler first(1), second(1);
  int calls = 0;
  const auto one = first.scheduleAt(epoch, [&] { ++calls; });
  const auto two = second.scheduleAt(epoch, [&] { ++calls; });
  EXPECT_FALSE(first.scheduleAt(epoch, [] {}));
  EXPECT_TRUE(one.pending()); EXPECT_TRUE(one.cancel()); EXPECT_FALSE(one.cancel());
  EXPECT_TRUE(two.pending());
  const auto replacement = first.scheduleAt(epoch, [&] { ++calls; });
  EXPECT_FALSE(one.cancel()); EXPECT_TRUE(replacement.pending());
  EXPECT_EQ(first.dispatchDue(epoch), 1u); EXPECT_EQ(second.dispatchDue(epoch), 1u);
  EXPECT_EQ(calls, 2); EXPECT_FALSE(two.pending()); EXPECT_FALSE(two.cancel());
}

TEST(SessionScheduler, ReusableCancellationAndPermanentShutdown)
{
  SessionScheduler scheduler;
  const auto old = scheduler.scheduleAt(epoch, [] { ADD_FAILURE(); });
  scheduler.cancelAll();
  EXPECT_FALSE(old.pending());
  const auto next = scheduler.scheduleAt(epoch, [] { ADD_FAILURE(); });
  EXPECT_TRUE(next); EXPECT_FALSE(old.cancel());
  scheduler.shutdown(); scheduler.shutdown();
  EXPECT_FALSE(next.cancel()); EXPECT_EQ(scheduler.pending(), 0u);
  EXPECT_FALSE(scheduler.scheduleAt(epoch, [] { ADD_FAILURE(); }));
  EXPECT_EQ(scheduler.dispatchDue(epoch), 0u);
}

TEST(SessionScheduler, RetainedTokenDoesNotRetainSchedulerOrCaptures)
{
  SessionScheduler::Token token;
  std::weak_ptr<int> capture;
  {
    SessionScheduler scheduler;
    auto value = std::make_shared<int>(1); capture = value;
    token = scheduler.scheduleAt(epoch, [value] {});
    value.reset(); EXPECT_FALSE(capture.expired());
  }
  EXPECT_TRUE(capture.expired()); EXPECT_FALSE(token.pending()); EXPECT_FALSE(token.cancel());
}

TEST(SessionScheduler, CaptureDestructorsAndWakeupsRunOutsideLocks)
{
  auto wake = std::make_shared<Wake>();
  SessionScheduler scheduler(1, wake);
  wake->inspect = [&] { EXPECT_LE(scheduler.pending(), 1u); };
  auto probe = std::make_shared<OnDestroy>();
  unsigned destroyed = 0;
  probe->action = [&] { EXPECT_EQ(scheduler.pending(), 0u); ++destroyed; };
  auto token = scheduler.scheduleAt(epoch, [probe] {});
  probe.reset();
  EXPECT_TRUE(token.cancel()); EXPECT_EQ(destroyed, 1u);
  token = scheduler.scheduleAt(epoch, [] {});
  auto rejected = std::make_shared<OnDestroy>();
  rejected->action = [&] { EXPECT_EQ(scheduler.pending(), 1u); ++destroyed; };
  // Only the rejected callback owns this probe when it is discarded.
  EXPECT_FALSE(scheduler.scheduleAt(epoch, [rejected = std::move(rejected)] {}));
  EXPECT_EQ(destroyed, 2u);
  scheduler.cancelAll();
  EXPECT_GE(wake->count.load(), 3u);
  wake->inspect = {};
}

TEST(SessionScheduler, CallbackReentryAndDispatchBudget)
{
  SessionScheduler scheduler(1);
  unsigned calls = 0;
  std::function<void()> repeat;
  repeat = [&] {
    ++calls;
    EXPECT_THROW(scheduler.dispatchDue(epoch), std::logic_error);
    EXPECT_TRUE(scheduler.scheduleAt(epoch, repeat));
  };
  scheduler.scheduleAt(epoch, repeat);
  EXPECT_EQ(scheduler.dispatchDue(epoch, 3), 3u); EXPECT_EQ(calls, 3u);
  EXPECT_EQ(scheduler.pending(), 1u);
  EXPECT_EQ(scheduler.dispatchDue(epoch, 2), 2u); EXPECT_EQ(calls, 5u);
  scheduler.cancelAll();
}

TEST(SessionScheduler, CallbackFailureConsumesOnlyItsTask)
{
  SessionScheduler scheduler;
  int calls = 0;
  const auto bad = scheduler.scheduleAt(epoch, [] { throw std::runtime_error("fixture"); });
  scheduler.scheduleAt(epoch, [&] { ++calls; });
  EXPECT_THROW(scheduler.dispatchDue(epoch), std::runtime_error);
  EXPECT_FALSE(bad.pending()); EXPECT_EQ(calls, 0);
  EXPECT_EQ(scheduler.dispatchDue(epoch), 1u); EXPECT_EQ(calls, 1);
}

TEST(SessionScheduler, CancelAndShutdownDoNotWaitForStartedCallback)
{
  SessionScheduler scheduler, other;
  std::promise<void> started, release;
  auto ready = started.get_future(); auto gate = release.get_future();
  auto token = scheduler.scheduleAt(epoch, [&] { started.set_value(); gate.wait(); });
  auto worker = std::async(std::launch::async, [&] { return scheduler.dispatchDue(epoch); });
  EXPECT_EQ(ready.wait_for(std::chrono::seconds(5)), std::future_status::ready);
  EXPECT_FALSE(token.pending()); EXPECT_FALSE(token.cancel());
  EXPECT_THROW(scheduler.dispatchDue(epoch), std::logic_error);
  scheduler.shutdown();
  unsigned calls = 0;
  other.scheduleAt(epoch, [&] { ++calls; });
  EXPECT_EQ(other.dispatchDue(epoch), 1u); EXPECT_EQ(calls, 1u);
  release.set_value();
  EXPECT_EQ(worker.get(), 1u);
}

TEST(SessionScheduler, ConcurrentProductionCancellationAndDispatch)
{
  SessionScheduler scheduler(16);
  std::atomic<unsigned> admitted{0}, cancelled{0}, executed{0}, finished{0};
  auto producer = [&] {
    for (int i = 0; i < 2000; ++i) {
      const auto token = scheduler.scheduleAt(epoch, [&] { ++executed; });
      if (token) { ++admitted; if (i % 2 && token.cancel()) ++cancelled; }
    }
    ++finished;
  };
  auto first = std::async(std::launch::async, producer);
  auto second = std::async(std::launch::async, producer);
  while (finished != 2 || scheduler.pending()) {
    scheduler.dispatchDue(epoch, 8);
    std::this_thread::yield();
  }
  first.get(); second.get();
  EXPECT_EQ(admitted.load(), cancelled.load() + executed.load());
  EXPECT_GT(admitted.load(), 0u);
}

TEST(SessionScheduler, RejectsInvalidConfigurationAndEmptyCallbacks)
{
  EXPECT_THROW(SessionScheduler(0), std::invalid_argument);
  EXPECT_THROW(SessionScheduler(4097), std::invalid_argument);
  SessionScheduler scheduler;
  EXPECT_THROW(scheduler.scheduleAt(epoch, {}), std::invalid_argument);
  EXPECT_THROW(scheduler.dispatchDue(epoch, 0), std::invalid_argument);
}
