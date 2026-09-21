/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_SESSION_WAKEUP_H
#define TIDYVNC_SESSION_WAKEUP_H

namespace viewer {
// Coalescing, level-triggered notification of work for a session executor.
// Called on any producer thread, outside locks. Must return promptly, never
// throw or enter protocol processing. No native handle crosses this seam.
class SchedulerWakeup {
public:
  virtual ~SchedulerWakeup() = default;
  virtual void wake() noexcept = 0;
};
}
#endif
