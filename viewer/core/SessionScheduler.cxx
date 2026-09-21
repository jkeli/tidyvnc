/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/core/SessionScheduler.h>
#include <algorithm>
#include <limits>
#include <list>
#include <mutex>
#include <stdexcept>
#include <utility>

namespace viewer {
struct SessionScheduler::State {
  struct Task { uint64_t id; TimePoint deadline; Callback callback; };
  explicit State(size_t limit, std::shared_ptr<SchedulerWakeup> notifier)
    : capacity(limit), wakeup(std::move(notifier)) {}
  void notify() const { if (wakeup) wakeup->wake(); }
  std::list<Task>::iterator earliest() {
    return std::min_element(tasks.begin(), tasks.end(), [](const Task& a, const Task& b) {
      return a.deadline < b.deadline; // stable list order breaks ties
    });
  }
  const size_t capacity;
  const std::shared_ptr<SchedulerWakeup> wakeup;
  mutable std::mutex mutex;
  std::list<Task> tasks;
  uint64_t nextId = 0;
  bool stopped = false, dispatching = false;
};

SessionScheduler::SessionScheduler(size_t capacity, std::shared_ptr<SchedulerWakeup> wakeup)
{
  if (!capacity || capacity > 4096) throw std::invalid_argument("Invalid timer capacity");
  state = std::make_shared<State>(capacity, std::move(wakeup));
}
SessionScheduler::~SessionScheduler() { shutdown(); }

SessionScheduler::Token SessionScheduler::scheduleAt(TimePoint deadline, Callback callback)
{
  if (!callback) throw std::invalid_argument("Empty timer callback");
  // Allocate before locking so allocation failure cannot destroy captures under
  // the mutex. Admission transfers an already-constructed list node without IO.
  std::list<State::Task> incoming;
  incoming.push_back({0, deadline, std::move(callback)});
  uint64_t id;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->stopped || state->tasks.size() == state->capacity ||
        state->nextId == std::numeric_limits<uint64_t>::max()) return {};
    id = state->nextId + 1;
    incoming.front().id = id;
    state->tasks.splice(state->tasks.end(), incoming);
    state->nextId = id;
  }
  state->notify();
  return Token(state, id);
}
bool SessionScheduler::Token::cancel() const
{
  auto live = owner.lock();
  if (!live) return false;
  std::list<State::Task> retired;
  {
    std::lock_guard<std::mutex> lock(live->mutex);
    const auto found = std::find_if(live->tasks.begin(), live->tasks.end(),
      [&](const State::Task& task) { return task.id == id; });
    if (found == live->tasks.end()) return false;
    retired.splice(retired.end(), live->tasks, found);
  }
  live->notify();
  // Captured objects are destroyed outside the mutex, including on cancellation.
  return true;
}
bool SessionScheduler::Token::pending() const
{
  auto live = owner.lock();
  if (!live) return false;
  std::lock_guard<std::mutex> lock(live->mutex);
  return std::any_of(live->tasks.begin(), live->tasks.end(),
    [&](const State::Task& task) { return task.id == id; });
}
bool SessionScheduler::nextDeadline(TimePoint& deadline) const
{
  std::lock_guard<std::mutex> lock(state->mutex);
  const auto next = state->earliest();
  if (next == state->tasks.end()) return false;
  deadline = next->deadline;
  return true;
}
size_t SessionScheduler::pending() const
{
  std::lock_guard<std::mutex> lock(state->mutex);
  return state->tasks.size();
}
void SessionScheduler::cancelAll()
{
  std::list<State::Task> retired;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    retired.splice(retired.end(), state->tasks);
  }
  state->notify();
}
void SessionScheduler::shutdown()
{
  std::list<State::Task> retired;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->stopped) return;
    state->stopped = true;
    retired.splice(retired.end(), state->tasks);
  }
  state->notify();
}
size_t SessionScheduler::dispatchDue(TimePoint now, size_t budget)
{
  if (!budget) throw std::invalid_argument("Zero timer dispatch budget");
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->dispatching) throw std::logic_error("Reentrant timer dispatch");
    state->dispatching = true;
  }
  struct Reset {
    std::shared_ptr<State> value;
    ~Reset() { std::lock_guard<std::mutex> lock(value->mutex); value->dispatching = false; }
  } reset{state};
  size_t count = 0;
  while (count < budget) {
    std::list<State::Task> running;
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      auto next = state->earliest();
      if (next == state->tasks.end() || next->deadline > now) break;
      running.splice(running.end(), state->tasks, next);
    }
    ++count;
    running.front().callback();
  }
  return count;
}
}
