/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/SessionEvents.h>
#include <future>
#include <vector>
using namespace viewer;
namespace {
std::vector<SessionEvent> drain(SessionEvents& queue) {
  std::vector<SessionEvent> events;
  SessionEvent event;
  while (queue.take(event)) events.push_back(event);
  return events;
}
}
TEST(SessionEvents, StartsWithOwnedCurrentSnapshot)
{
  SessionSnapshot state; state.generation=4; state.width=640; state.state=SessionState::Connected;
  SessionEvents queue(state); state.width=42;
  auto events=drain(queue); ASSERT_EQ(events.size(),1u);
  EXPECT_EQ(events[0].kind,SessionEventKind::Snapshot);
  EXPECT_EQ(events[0].snapshot.width,640u); EXPECT_EQ(events[0].snapshot.generation,4u);
  EXPECT_EQ(queue.snapshot().width,640u);
}
TEST(SessionEvents, StatisticsCoalesceWithoutReorderingReliableEvents)
{
  SessionSnapshot state;
  SessionEvents queue(state,4); drain(queue);
  state.frames=1; queue.publish(SessionEventKind::Statistics,state);
  state.bells=1; queue.publish(SessionEventKind::Bell,state);
  state.frames=2; queue.publish(SessionEventKind::Statistics,state);
  state.frames=3; queue.publish(SessionEventKind::Statistics,state);
  auto events=drain(queue); ASSERT_EQ(events.size(),2u);
  EXPECT_EQ(events[0].kind,SessionEventKind::Bell); EXPECT_EQ(events[0].snapshot.frames,1u);
  EXPECT_EQ(events[1].kind,SessionEventKind::Statistics); EXPECT_EQ(events[1].snapshot.frames,3u);
  EXPECT_LT(events[0].sequence,events[1].sequence);
}
TEST(SessionEvents, ReservesCompletionBeforeAcceptingOperation)
{
  SessionEvents queue({},2);
  const auto operation=queue.reserve(1); ASSERT_NE(operation,0u);
  EXPECT_EQ(queue.reserve(1),0u); // Initial snapshot plus reserved completion fill capacity.
  EXPECT_TRUE(queue.complete(operation,OperationResult::Succeeded));
  EXPECT_FALSE(queue.complete(operation,OperationResult::Failed));
  auto events=drain(queue); ASSERT_EQ(events.size(),2u);
  EXPECT_EQ(events[1].operation,operation); EXPECT_EQ(events[1].kind,SessionEventKind::Completion);
  EXPECT_EQ(events[1].result,OperationResult::Succeeded);
}
TEST(SessionEvents, OverflowRetainsCompletionsAndReportsOneTerminalFault)
{
  SessionEvents queue({},3);
  const auto first=queue.reserve(1), second=queue.reserve(1);
  ASSERT_NE(first,0u); ASSERT_NE(second,0u);
  EXPECT_FALSE(queue.publish(SessionEventKind::Bell,{}));
  EXPECT_TRUE(queue.sealed()); EXPECT_EQ(queue.reserve(1),0u);
  EXPECT_FALSE(queue.complete(first,OperationResult::Succeeded));
  auto events=drain(queue); ASSERT_EQ(events.size(),4u);
  EXPECT_EQ(events[0].kind,SessionEventKind::Snapshot);
  EXPECT_EQ(events[1].operation,first); EXPECT_EQ(events[2].operation,second);
  EXPECT_EQ(events[1].result,OperationResult::Failed); EXPECT_EQ(events[2].result,OperationResult::Failed);
  EXPECT_EQ(events[3].kind,SessionEventKind::Overflow);
  EXPECT_EQ(queue.snapshot().state,SessionState::Failed);
  for (size_t i=1;i<events.size();++i) EXPECT_LT(events[i-1].sequence,events[i].sequence);
  EXPECT_TRUE(drain(queue).empty());
}
TEST(SessionEvents, ReplaceableStatisticsCannotConsumeCompletionReservations)
{
  SessionEvents queue({},2);
  const auto operation=queue.reserve(1);
  SessionSnapshot state; state.frames=100;
  EXPECT_TRUE(queue.publish(SessionEventKind::Statistics,state));
  EXPECT_FALSE(queue.sealed()); EXPECT_EQ(queue.snapshot().frames,100u);
  EXPECT_TRUE(queue.complete(operation,OperationResult::Succeeded));
  auto events=drain(queue); ASSERT_EQ(events.size(),2u);
  EXPECT_EQ(events[1].kind,SessionEventKind::Completion);
}
TEST(SessionEvents, AdmissionCanReclaimStatistics)
{
  SessionEvents queue({},2);
  queue.publish(SessionEventKind::Statistics,{});
  auto operation=queue.reserve(1); ASSERT_NE(operation,0u);
  queue.seal(OperationResult::Cancelled); queue.seal(OperationResult::Failed);
  auto events=drain(queue); ASSERT_EQ(events.size(),2u);
  EXPECT_EQ(events[1].operation,operation); EXPECT_EQ(events[1].result,OperationResult::Cancelled);
}
TEST(SessionEvents, ReconnectRejectsStaleOperationsAndRequiresPreviousCompletions)
{
  SessionEvents queue({},8);
  auto first=queue.reserve(1);
  SessionSnapshot next; next.generation=2;
  EXPECT_THROW(queue.publish(SessionEventKind::State,next),std::logic_error);
  queue.cancelPending(OperationResult::Cancelled);
  EXPECT_TRUE(queue.publish(SessionEventKind::State,next));
  EXPECT_EQ(queue.reserve(1),0u); EXPECT_FALSE(queue.publish(SessionEventKind::Bell,{}));
  auto second=queue.reserve(2); EXPECT_GT(second,first);
  EXPECT_FALSE(queue.complete(first,OperationResult::Succeeded));
  EXPECT_TRUE(queue.complete(second,OperationResult::Succeeded));
  auto events=drain(queue); ASSERT_EQ(events.size(),4u);
  EXPECT_EQ(events[1].snapshot.generation,1u); EXPECT_EQ(events[3].snapshot.generation,2u);
}
TEST(SessionEvents, ValidatesCapacityAndReservedKinds)
{
  EXPECT_THROW((SessionEvents({},1)),std::invalid_argument);
  EXPECT_THROW((SessionEvents({},65537)),std::invalid_argument);
  SessionSnapshot state; state.generation=0;
  EXPECT_THROW((SessionEvents(state)),std::invalid_argument);
  SessionEvents queue({});
  EXPECT_THROW(queue.publish(SessionEventKind::Completion,{}),std::invalid_argument);
  EXPECT_THROW(queue.publish(SessionEventKind::Overflow,{}),std::invalid_argument);
}
TEST(SessionEvents, ConcurrentStatisticsProducerAndConsumerObserveOrderedSnapshots)
{
  SessionEvents queue({},8);
  auto producer=std::async(std::launch::async,[&] {
    SessionSnapshot state;
    for (unsigned i=1;i<=10000;++i) { state.frames=i; queue.publish(SessionEventKind::Statistics,state); }
    queue.seal(OperationResult::Cancelled);
  });
  uint64_t sequence=0, frames=0;
  SessionEvent event;
  do {
    while (queue.take(event)) {
      EXPECT_GT(event.sequence,sequence); EXPECT_GE(event.snapshot.frames,frames);
      sequence=event.sequence; frames=event.snapshot.frames;
    }
  } while (producer.wait_for(std::chrono::milliseconds(0))!=std::future_status::ready);
  producer.get();
  while (queue.take(event)) { EXPECT_GT(event.sequence,sequence); sequence=event.sequence; frames=event.snapshot.frames; }
  EXPECT_EQ(frames,10000u); EXPECT_TRUE(queue.sealed());
}
