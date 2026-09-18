/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_SESSION_EVENTS_H
#define TIDYVNC_SESSION_EVENTS_H
#include <cstddef>
#include <cstdint>
#include <memory>

namespace viewer {
enum class SessionState { Idle, Negotiating, Connected, Closed, Failed };
enum class SessionEventKind { Snapshot, State, Desktop, Bell, Statistics, Completion, Overflow };
enum class OperationResult { Succeeded, Cancelled, Failed };
struct SessionSnapshot {
  uint64_t generation = 1, frames = 0, bells = 0;
  uint32_t width = 0, height = 0;
  SessionState state = SessionState::Idle;
};
struct SessionEvent {
  SessionEventKind kind = SessionEventKind::Snapshot;
  uint64_t sequence = 0, operation = 0;
  SessionSnapshot snapshot;
  OperationResult result = OperationResult::Succeeded;
};
// One ordered consumer per queue. take/snapshot/sealed may run on any thread;
// producer methods belong to the serialized owning executor. Internal locking
// makes producer/consumer access safe; there are no callbacks. Fixed-size
// payloads and preallocated storage bound memory. Operation
// IDs are queue-local; pair them with the queue identity and event generation.
class SessionEvents {
public:
  explicit SessionEvents(SessionSnapshot initial, size_t capacity = 128);
  ~SessionEvents();
  SessionEvents(const SessionEvents&) = delete;
  SessionEvents& operator=(const SessionEvents&) = delete;
  bool take(SessionEvent& event);
  SessionSnapshot snapshot() const;
  // Zero means rejected: no completion is owed. A nonzero ID reserves capacity
  // for exactly one completion, including when the queue subsequently overflows.
  uint64_t reserve(uint64_t generation);
  bool complete(uint64_t operation, OperationResult result);
  // Statistics are replaceable; other events cannot be dropped. On exhaustion,
  // pending operations fail and one out-of-band Overflow terminates this stream.
  bool publish(SessionEventKind kind, SessionSnapshot snapshot);
  void cancelPending(OperationResult result);
  // Preserve queued events, complete pending operations and seal the stream.
  void seal(OperationResult pendingResult);
  bool sealed() const;
private:
  struct Impl;
  std::unique_ptr<Impl> impl;
};
}
#endif
