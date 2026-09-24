// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
//
// Test stand-in for core/Timer.h in the touch gesture equivalence test
// (tests/unit/windows/touchgestures.cxx): the retained GestureHandler's
// timers run on the test's scripted clock instead of the wall clock.

#ifndef __CORE_TIMER_H__
#define __CORE_TIMER_H__

#include <stdint.h>

#include <algorithm>
#include <vector>

namespace touchtest {
// Milliseconds of the scripted clock (defined in touchgestures.cxx).
extern uint64_t now;
}

namespace core {

struct Timer {
  struct Callback {
    virtual void handleTimeout(Timer* t) = 0;
    virtual ~Callback() {}
  };

  Timer(Callback* cb_) : cb(cb_) { all().push_back(this); }
  ~Timer()
  {
    stop();
    auto& timers = all();
    timers.erase(std::remove(timers.begin(), timers.end(), this), timers.end());
  }

  void start(int timeoutMs)
  {
    started = true;
    due = touchtest::now + (uint64_t)timeoutMs;
  }
  void stop() { started = false; }
  bool isStarted() { return started; }

  // Fires every started timer due by the scripted clock, earliest first.
  static void fireDue()
  {
    for (;;) {
      Timer* next = nullptr;
      for (Timer* timer : all())
        if (timer->started && timer->due <= touchtest::now && (next == nullptr || timer->due < next->due))
          next = timer;
      if (next == nullptr)
        return;
      next->stop();
      next->cb->handleTimeout(next);
    }
  }

private:
  static std::vector<Timer*>& all()
  {
    static std::vector<Timer*> timers;
    return timers;
  }

  Callback* cb;
  bool started = false;
  uint64_t due = 0;
};

} // namespace core

#endif
