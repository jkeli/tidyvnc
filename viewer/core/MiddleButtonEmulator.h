/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_MIDDLE_BUTTON_EMULATOR_H
#define TIDYVNC_MIDDLE_BUTTON_EMULATOR_H
#include <array>
#include <cstddef>
#include <cstdint>
#include <core/Rect.h>
namespace viewer {
// Executor-confined, allocation-free pointer policy shared by both frontends.
// Hosts own the one-shot 50 ms timer; reset discards pending input without sending.
class MiddleButtonEmulator {
public:
  struct Event { core::Point position; uint16_t buttons; };
  struct Batch {
    std::array<Event, 3> events{};
    size_t count = 0;
    bool timerChanged = false;
  };
  Batch pointer(core::Point position, uint16_t buttons);
  Batch expire();
  bool pending() const { return state == 1 || state == 2; }
  void reset() { *this = MiddleButtonEmulator(); }
private:
  void action(Batch& batch, core::Point position, uint16_t buttons, int action);
  uint16_t mask(uint16_t buttons) const { return (buttons & ~0x5) | emulated; }
  int state = 0;
  uint16_t emulated = 0, lastButtons = 0;
  core::Point original, lastPosition;
};
}
#endif
