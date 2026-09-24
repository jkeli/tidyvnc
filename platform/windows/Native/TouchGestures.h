// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
//
// Touch gestures for the WinUI desktop view (plans/native-ui-winui
// DESKTOP.md section 6, TODO W6.7): vncviewer/GestureHandler and
// vncviewer/BaseTouchHandler extracted without core timers or the wall clock.
// The host passes a millisecond clock with every call and calls timeout() at
// or after deadline(). The output is the retained viewer's fake mouse and key
// events: tap = left click, two-finger tap = right, three-finger tap = middle,
// drag = left drag, long press = right drag, two-finger drag = wheel 4-7,
// pinch = Ctrl with wheel 4/5. The equivalence test (tests/unit/windows/
// touchgestures.cxx) replays touch streams against the retained classes.

#pragma once

#include <cstdint>
#include <map>
#include <set>
#include <vector>

namespace tidyvnc::windows {

struct TouchAction {
  enum Kind : uint32_t { Motion = 0, Button = 1, Key = 2 };
  Kind kind;
  bool press;
  int button;       // 1..7 for Button
  uint32_t keysym;  // for Key
  double x, y;      // the gesture position, in the caller's coordinates
};

class TouchGestures {
public:
  static constexpr uint64_t NoDeadline = UINT64_MAX;

  explicit TouchGestures(uint64_t now);

  void begin(int id, double x, double y, uint64_t now);
  void update(int id, double x, double y, uint64_t now);
  void end(int id, uint64_t now);
  // Fires every timer due at now, earliest first.
  void timeout(uint64_t now);
  uint64_t deadline() const;

  // Actions produced since the last call.
  std::vector<TouchAction> take();

private:
  enum EventType { Begin, Update, End };
  enum Gesture { OneTap, TwoTap, ThreeTap, Drag, LongPress, TwoDrag, Pinch };
  struct Event {
    double eventX, eventY, magnitudeX, magnitudeY;
    Gesture gesture;
    EventType type;
  };
  struct Touch {
    uint64_t started;
    bool active;
    double firstX, firstY, lastX, lastY;
    int angle;
  };
  struct Timer {
    bool started = false;
    uint64_t due = 0;
    void start(uint64_t now, unsigned ms) { started = true; due = now + ms; }
    void stop() { started = false; }
  };

  // GestureHandler
  bool hasDetectedGesture() const;
  void longpressTimeout(uint64_t now);
  void twoTouchTimeout(uint64_t now);
  void pushEvent(EventType type, uint64_t now);
  static Gesture stateToGesture(unsigned char state);
  void getPosition(double* firstX, double* firstY, double* lastX, double* lastY) const;
  void getAverageMovement(double* h, double* v) const;
  void getAverageDistance(double* firstX, double* firstY, double* lastX, double* lastY) const;

  // BaseTouchHandler
  void handleGestureEvent(const Event& event, uint64_t now);
  void handleTapEvent(const Event& event, int button, uint64_t now);
  void motion(const Event& event);
  void button(bool press, int button, const Event& event);
  void key(bool press, uint32_t keysym, const Event& event);

  unsigned char state;
  std::map<int, Touch> tracked;
  std::set<int> ignored;
  bool waitingRelease = false;
  uint64_t releaseStart = 0;
  Timer longpressTimer, twoTouchTimer;

  double lastMagnitudeX = 0, lastMagnitudeY = 0;
  Event firstDoubleTapEvent{};
  uint64_t lastTapTime;

  std::vector<TouchAction> actions;
};

} // namespace tidyvnc::windows
