/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_SESSION_SCHEDULER_H
#define TIDYVNC_SESSION_SCHEDULER_H

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <viewer/platform/SessionWakeup.h>

namespace viewer {
class SessionScheduler {
  struct State;
public:
  using Clock = std::chrono::steady_clock;
  using TimePoint = Clock::time_point;
  using Callback = std::function<void()>;

  // Tokens are copyable cancellation capabilities, scoped to their scheduler.
  // Destruction does not cancel. Retaining one does not retain the scheduler,
  // callback or its captures. cancel() is safe after scheduler destruction.
  class Token {
  public:
    Token() = default;
    bool cancel() const;
    bool pending() const;
    explicit operator bool() const { return id != 0; }
  private:
    friend class SessionScheduler;
    Token(std::weak_ptr<State> owner_, uint64_t id_) : owner(owner_), id(id_) {}
    std::weak_ptr<State> owner;
    uint64_t id = 0;
  };

  explicit SessionScheduler(size_t capacity = 64,
                            std::shared_ptr<SchedulerWakeup> wakeup = nullptr);
  ~SessionScheduler();
  SessionScheduler(const SessionScheduler&) = delete;
  SessionScheduler& operator=(const SessionScheduler&) = delete;

  // Any producer thread. One-shot callbacks, earliest deadline first, FIFO for
  // equal deadlines. Invalid token means full/shutdown/ID exhaustion; no callback
  // was accepted. Empty callbacks are invalid. Allocation failure propagates.
  // Capacity bounds queued captures by count, not their caller-selected bytes.
  Token scheduleAt(TimePoint deadline, Callback callback);
  bool nextDeadline(TimePoint& deadline) const;
  size_t pending() const;
  void cancelAll(); // Reusable; accepted IDs are never reused.
  void shutdown();  // Irreversible, idempotent. Cancels queued callbacks.

  // Sole executor only. Invokes at most budget due callbacks outside locks.
  // Concurrent/reentrant dispatch is rejected. Dequeue is the start boundary:
  // cancellation wins only before dequeue; an already-started callback finishes.
  // A thrown callback is consumed and propagates, leaving other timers queued.
  // Callbacks may schedule/cancel/shutdown, but must not destroy this scheduler.
  // Shutdown/destruction is not a join; drain the host executor before destruction.
  size_t dispatchDue(TimePoint now, size_t budget = 64);

private:
  std::shared_ptr<State> state;
};
}
#endif
