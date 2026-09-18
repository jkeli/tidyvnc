/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "SessionEvents.h"
#include <algorithm>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <vector>

namespace viewer {
struct SessionEvents::Impl {
  struct Operation { uint64_t id, generation; };
  Impl(SessionSnapshot initial, size_t capacity_) : capacity(capacity_), current(initial) {
    if (capacity < 2 || capacity > 65536 || !initial.generation)
      throw std::invalid_argument("Invalid session event capacity/generation");
    events.reserve(capacity);
    operations.reserve(capacity);
    append(SessionEventKind::Snapshot,current);
  }
  const size_t capacity;
  mutable std::mutex mutex;
  SessionSnapshot current;
  std::vector<SessionEvent> events;
  std::vector<Operation> operations;
  uint64_t sequence = 0, operationId = 0;
  bool stopped = false, overflowPending = false;
  SessionEvent overflowEvent;
  void append(SessionEventKind kind, SessionSnapshot value, uint64_t id = 0,
              OperationResult result = OperationResult::Succeeded) {
    SessionEvent event;
    event.kind = kind; event.snapshot = value; event.sequence = ++sequence;
    event.operation = id; event.result = result; events.push_back(event);
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
      append(SessionEventKind::Completion,value,operation.id,result);
    }
    operations.clear();
  }
  void overflow() {
    stopped = true;
    current.state = SessionState::Failed;
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
uint64_t SessionEvents::reserve(uint64_t generation) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (impl->stopped || generation != impl->current.generation ||
      impl->operationId == std::numeric_limits<uint64_t>::max()) return 0;
  if (impl->sequenceExhausted()) { impl->overflow(); return 0; }
  if (!impl->room()) impl->removeStatistics();
  if (!impl->room()) return 0;
  const uint64_t id = ++impl->operationId;
  impl->operations.push_back({id,generation}); return id;
}
bool SessionEvents::complete(uint64_t id, OperationResult result) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  const auto operation = std::find_if(impl->operations.begin(),impl->operations.end(),
    [&](const Impl::Operation& value) { return value.id == id; });
  if (operation == impl->operations.end()) return false;
  auto value = impl->current; value.generation = operation->generation;
  impl->append(SessionEventKind::Completion,value,id,result);
  impl->operations.erase(operation); return true;
}
bool SessionEvents::publish(SessionEventKind kind, SessionSnapshot value) {
  if (kind == SessionEventKind::Snapshot || kind == SessionEventKind::Completion ||
      kind == SessionEventKind::Overflow)
    throw std::invalid_argument("Reserved session event kind");
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (impl->stopped || value.generation < impl->current.generation) return false;
  if (impl->sequenceExhausted()) { impl->overflow(); return false; }
  if (value.generation > impl->current.generation && !impl->operations.empty())
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
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (impl->stopped) return;
  impl->finishOperations(result); impl->stopped = true;
}
void SessionEvents::cancelPending(OperationResult result) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->finishOperations(result);
}
bool SessionEvents::sealed() const {
  std::lock_guard<std::mutex> lock(impl->mutex); return impl->stopped;
}
}
