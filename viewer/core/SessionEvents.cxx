/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "SessionEvents.h"
#include <algorithm>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <vector>

namespace viewer {
struct SessionEvents::Impl {
  struct Operation { uint64_t id, generation, origin; };
  Impl(SessionSnapshot initial, size_t capacity_) : capacity(capacity_), current(initial) {
    if (capacity < 2 || capacity > 65536 || !initial.generation)
      throw std::invalid_argument("Invalid session event capacity/generation");
    events.reserve(capacity);
    operations.reserve(capacity);
    append(SessionEventKind::Snapshot,current);
  }
  const size_t capacity;
  mutable std::mutex mutex;
  std::weak_ptr<MailboxWakeup> wakeup;
  SessionSnapshot current;
  std::vector<SessionEvent> events;
  std::vector<Operation> operations;
  uint64_t sequence = 0, operationId = 0;
  bool stopped = false, overflowPending = false;
  SessionEvent overflowEvent;
  void append(SessionEventKind kind, SessionSnapshot value, uint64_t id = 0,
              OperationResult result = OperationResult::Succeeded, uint64_t origin = 0,
              OperationFailure failure = OperationFailure::None, uint32_t nativeResult = 0) {
    SessionEvent event;
    event.kind = kind; event.snapshot = value; event.sequence = ++sequence;
    event.operation = id; event.result = result; event.origin = origin;
    event.failure = failure; event.nativeResult = nativeResult; events.push_back(event);
  }
  bool room() const { return events.size() + operations.size() < capacity; }
  bool sequenceExhausted() const {
    // Keep sequence space for all reserved completions and the terminal fault.
    return sequence >= std::numeric_limits<uint64_t>::max() - capacity - 1;
  }
  // Removing obsolete statistics preserves the order of every reliable event.
  void removeStatistics() {
    events.erase(std::remove_if(events.begin(),events.end(),[](const SessionEvent& event) {
      return event.kind == SessionEventKind::Statistics;
    }),events.end());
  }
  void finishOperations(OperationResult result) {
    for (const auto& operation : operations) {
      auto value = current; value.generation = operation.generation;
      append(SessionEventKind::Completion,value,operation.id,result,operation.origin);
    }
    operations.clear();
  }
  void overflow() {
    stopped = true;
    current.state = SessionState::Failed;
    current.endReason = SessionEndReason::EventOverflow;
    current.nativeError = 0;
    finishOperations(OperationResult::Failed);
    overflowEvent.kind = SessionEventKind::Overflow;
    overflowEvent.snapshot = current;
    overflowEvent.result = OperationResult::Failed;
    overflowEvent.sequence = ++sequence;
    overflowPending = true;
  }
};
SessionEvents::SessionEvents(SessionSnapshot initial, size_t capacity)
  : impl(new Impl(initial,capacity)) {}
SessionEvents::~SessionEvents() = default;
void SessionEvents::setWakeup(std::weak_ptr<MailboxWakeup> wakeup) {
  MailboxNotification notify;
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->wakeup = std::move(wakeup); notify.target = impl->wakeup.lock();
}
bool SessionEvents::take(SessionEvent& event) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (!impl->events.empty()) {
    event = impl->events.front(); impl->events.erase(impl->events.begin()); return true;
  }
  if (impl->overflowPending) {
    event = impl->overflowEvent; impl->overflowPending = false; return true;
  }
  return false;
}
SessionSnapshot SessionEvents::snapshot() const {
  std::lock_guard<std::mutex> lock(impl->mutex); return impl->current;
}
uint64_t SessionEvents::reserve(uint64_t generation, uint64_t origin) {
  MailboxNotification notify;
  std::lock_guard<std::mutex> lock(impl->mutex);
  const bool prepared = generation > impl->current.generation &&
    !impl->operations.empty() && impl->operations.front().generation == generation;
  if (impl->stopped || (generation != impl->current.generation && !prepared) ||
      std::any_of(impl->operations.begin(), impl->operations.end(),
        [&](const Impl::Operation& operation) { return operation.generation != generation; }) ||
      impl->operationId == std::numeric_limits<uint64_t>::max()) return 0;
  if (impl->sequenceExhausted()) { impl->overflow(); notify.target = impl->wakeup.lock(); return 0; }
  if (!impl->room()) impl->removeStatistics();
  if (!impl->room()) return 0;
  const uint64_t id = ++impl->operationId;
  impl->operations.push_back({id,generation,origin}); return id;
}
bool SessionEvents::complete(uint64_t id, OperationResult result, OperationFailure failure, uint32_t nativeResult) {
  MailboxNotification notify;
  std::lock_guard<std::mutex> lock(impl->mutex);
  const auto operation = std::find_if(impl->operations.begin(),impl->operations.end(),
    [&](const Impl::Operation& value) { return value.id == id; });
  if (operation == impl->operations.end()) return false;
  auto value = impl->current; value.generation = operation->generation;
  impl->append(SessionEventKind::Completion,value,id,result,operation->origin,failure,nativeResult);
  impl->operations.erase(operation); notify.target = impl->wakeup.lock(); return true;
}
uint64_t SessionEvents::reserveAttempt(uint64_t generation) {
  MailboxNotification notify;
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (impl->stopped || generation <= impl->current.generation ||
      !impl->operations.empty() || impl->operationId == std::numeric_limits<uint64_t>::max()) return 0;
  if (impl->sequenceExhausted()) { impl->overflow(); notify.target = impl->wakeup.lock(); return 0; }
  if (!impl->room()) impl->removeStatistics();
  if (!impl->room()) return 0;
  const uint64_t id = ++impl->operationId;
  impl->operations.push_back({id, generation, 0}); return id;
}
bool SessionEvents::pending(uint64_t id, uint64_t generation) const {
  std::lock_guard<std::mutex> lock(impl->mutex);
  return std::any_of(impl->operations.begin(),impl->operations.end(),
    [&](const Impl::Operation& value) { return value.id == id && value.generation == generation; });
}
bool SessionEvents::publish(SessionEventKind kind, SessionSnapshot value) {
  MailboxNotification notify;
  if (kind == SessionEventKind::Snapshot || kind == SessionEventKind::Completion ||
      kind == SessionEventKind::Overflow)
    throw std::invalid_argument("Reserved session event kind");
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (impl->stopped || value.generation < impl->current.generation) return false;
  notify.target = impl->wakeup.lock();
  if (impl->sequenceExhausted()) { impl->overflow(); return false; }
  if (value.generation > impl->current.generation &&
      std::any_of(impl->operations.begin(), impl->operations.end(),
        [&](const Impl::Operation& operation) { return operation.generation != value.generation; }))
    throw std::logic_error("Finish operations before advancing generation");
  impl->current = value;
  if (kind == SessionEventKind::Statistics || !impl->room()) impl->removeStatistics();
  if (!impl->room()) {
    if (kind == SessionEventKind::Statistics) return true; // Snapshot retains latest counters.
    impl->overflow(); return false;
  }
  impl->append(kind,value); return true;
}
void SessionEvents::seal(OperationResult result) {
  MailboxNotification notify;
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (impl->stopped) return;
  notify.target = impl->wakeup.lock();
  impl->finishOperations(result); impl->stopped = true;
}
void SessionEvents::cancelPending(OperationResult result) {
  MailboxNotification notify;
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (!impl->operations.empty()) notify.target = impl->wakeup.lock();
  impl->finishOperations(result);
}
bool SessionEvents::sealed() const {
  std::lock_guard<std::mutex> lock(impl->mutex); return impl->stopped;
}
}
