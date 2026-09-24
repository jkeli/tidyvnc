// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
//
// Windows touch gesture equivalence (plans/native-ui-winui TODO W6.7,
// DESKTOP.md section 6): the retained vncviewer/GestureHandler and
// BaseTouchHandler and the helper DLL's extracted TouchGestures replay the
// same touch streams on the same scripted clock and must produce identical
// fake mouse and key events.
//
// The retained sources are compiled into this file with gettimeofday() and
// core::msSince() redirected to the scripted clock and core::Timer replaced by
// a stub (windows/touch-stub/core/Timer.h).

#ifndef _USE_MATH_DEFINES
#define _USE_MATH_DEFINES
#endif
#include <windows.h>

#include <math.h>
#include <stdint.h>
#include <string.h>

#include <new>
#include <random>
#include <string>
#include <vector>

#include <sys/time.h>
#include <core/time.h>

#include <gtest/gtest.h>

#include "TouchGestures.h"

namespace touchtest {
uint64_t now = 0;
}

static int scriptedGettimeofday(struct timeval* tv, void*)
{
  tv->tv_sec = (long)(touchtest::now / 1000);
  tv->tv_usec = (long)((touchtest::now % 1000) * 1000);
  return 0;
}

namespace core {
static unsigned scriptedMsSince(const struct timeval* then)
{
  uint64_t start = (uint64_t)then->tv_sec * 1000 + (uint64_t)then->tv_usec / 1000;
  return (unsigned)(touchtest::now - start);
}
}

#define gettimeofday scriptedGettimeofday
#define msSince scriptedMsSince
#include <core/Timer.h>
#include "GestureHandler.cxx"
#include "BaseTouchHandler.cxx"
#undef msSince
#undef gettimeofday

using tidyvnc::windows::TouchAction;
using tidyvnc::windows::TouchGestures;

namespace tidyvnc::windows {
// Found by argument-dependent lookup for std::vector comparison.
bool operator==(const TouchAction& a, const TouchAction& b)
{
  return a.kind == b.kind && a.press == b.press && a.button == b.button && a.keysym == b.keysym && a.x == b.x && a.y == b.y;
}
}

namespace {

std::string describe(const std::vector<TouchAction>& actions)
{
  std::string text;
  for (const TouchAction& a : actions) {
    static const char* kinds[] = {"motion", "button", "key"};
    text += std::string(kinds[a.kind]) + (a.kind == TouchAction::Motion ? "" : a.press ? " press" : " release");
    if (a.kind == TouchAction::Button)
      text += " " + std::to_string(a.button);
    if (a.kind == TouchAction::Key)
      text += " " + std::to_string(a.keysym);
    text += " @" + std::to_string(a.x) + "," + std::to_string(a.y) + "\n";
  }
  return text;
}

class Retained : public GestureHandler, public BaseTouchHandler {
public:
  std::vector<TouchAction> actions;

protected:
  void handleGestureEvent(const GestureEvent& event) override { BaseTouchHandler::handleGestureEvent(event); }
  void fakeMotionEvent(const GestureEvent e) override
  {
    actions.push_back({TouchAction::Motion, false, 0, 0, e.eventX, e.eventY});
  }
  void fakeButtonEvent(bool press, int button, const GestureEvent e) override
  {
    actions.push_back({TouchAction::Button, press, button, 0, e.eventX, e.eventY});
  }
  void fakeKeyEvent(bool press, int keysym, const GestureEvent e) override
  {
    actions.push_back({TouchAction::Key, press, 0, (uint32_t)keysym, e.eventX, e.eventY});
  }
};

enum Phase { Begin, Update, End };
struct Step {
  uint64_t at;
  Phase phase;
  int id;
  double x, y;
};

// Runs a script through both implementations; returns the retained output and checks equality.
std::vector<TouchAction> replay(const std::vector<Step>& steps, uint64_t start = 0)
{
  touchtest::now = start;
  // The retained class leaves firstDoubleTapEvent uninitialised; zeroed storage makes its first
  // comparison deterministic, and the extraction starts from the same zero value.
  alignas(Retained) unsigned char storage[sizeof(Retained)];
  memset(storage, 0, sizeof(storage));
  Retained* retained = new (storage) Retained();
  TouchGestures extracted(start);
  std::vector<TouchAction> fromExtracted;
  auto collect = [&] {
    for (const TouchAction& action : extracted.take())
      fromExtracted.push_back(action);
  };
  for (const Step& step : steps) {
    touchtest::now = step.at;
    core::Timer::fireDue();
    extracted.timeout(step.at);
    collect();
    switch (step.phase) {
    case Begin:
      retained->handleTouchBegin(step.id, step.x, step.y);
      extracted.begin(step.id, step.x, step.y, step.at);
      break;
    case Update:
      retained->handleTouchUpdate(step.id, step.x, step.y);
      extracted.update(step.id, step.x, step.y, step.at);
      break;
    case End:
      retained->handleTouchEnd(step.id);
      extracted.end(step.id, step.at);
      break;
    }
    collect();
  }
  // Let every pending timer fire.
  touchtest::now = (steps.empty() ? start : steps.back().at) + 5000;
  core::Timer::fireDue();
  extracted.timeout(touchtest::now);
  collect();
  std::vector<TouchAction> result = retained->actions;
  retained->~Retained();
  EXPECT_EQ(result.size(), fromExtracted.size()) << "retained:\n" << describe(result) << "extracted:\n" << describe(fromExtracted);
  EXPECT_TRUE(result == fromExtracted) << "retained:\n" << describe(result) << "extracted:\n" << describe(fromExtracted);
  return result;
}

std::vector<int> buttons(const std::vector<TouchAction>& actions)
{
  std::vector<int> result;
  for (const TouchAction& a : actions)
    if (a.kind == TouchAction::Button)
      result.push_back(a.press ? a.button : -a.button);
  return result;
}

} // namespace

TEST(TouchGestures, TapsClickTheButtonForTheirFingerCount)
{
  // Two seconds after construction, so no double-tap adjustment applies.
  EXPECT_EQ(buttons(replay({{2000, Begin, 1, 100, 100}, {2100, End, 1, 100, 100}})), (std::vector<int>{1, -1}));
  EXPECT_EQ(buttons(replay({{2000, Begin, 1, 100, 100}, {2010, Begin, 2, 140, 100},
                            {2100, End, 1, 100, 100}, {2110, End, 2, 140, 100}})), (std::vector<int>{3, -3}));
  EXPECT_EQ(buttons(replay({{2000, Begin, 1, 100, 100}, {2010, Begin, 2, 140, 100}, {2020, Begin, 3, 180, 100},
                            {2100, End, 1, 100, 100}, {2105, End, 2, 140, 100}, {2110, End, 3, 180, 100}})),
            (std::vector<int>{2, -2}));
}

TEST(TouchGestures, DoubleTapsNearTheFirstReuseItsPosition)
{
  auto actions = replay({{2000, Begin, 1, 100, 100}, {2050, End, 1, 100, 100},
                         {2300, Begin, 1, 120, 110}, {2350, End, 1, 120, 110},
                         {2600, Begin, 1, 400, 400}, {2650, End, 1, 400, 400}});
  ASSERT_EQ(actions.size(), 9u);
  EXPECT_EQ(actions[3].x, 100);  // The second tap lands on the first.
  EXPECT_EQ(actions[6].x, 400);  // A distant tap does not.
}

TEST(TouchGestures, DragAndLongPressHoldButtons)
{
  auto drag = replay({{2000, Begin, 1, 100, 100}, {2050, Update, 1, 130, 100}, {2100, Update, 1, 200, 100},
                      {2150, Update, 1, 260, 120}, {2200, End, 1, 260, 120}});
  EXPECT_EQ(buttons(drag), (std::vector<int>{1, -1}));
  auto press = replay({{2000, Begin, 1, 100, 100}, {3200, Update, 1, 180, 100}, {3300, End, 1, 180, 100}});
  EXPECT_EQ(buttons(press), (std::vector<int>{3, -3}));
}

TEST(TouchGestures, TwoFingerDragScrollsAndPinchZoomsWithControl)
{
  auto scroll = replay({{2000, Begin, 1, 100, 100}, {2005, Begin, 2, 200, 100},
                        {2030, Update, 1, 100, 170}, {2035, Update, 2, 200, 170},
                        {2080, Update, 1, 100, 300}, {2085, Update, 2, 200, 300},
                        {2200, End, 1, 100, 300}, {2205, End, 2, 200, 300}});
  EXPECT_FALSE(buttons(scroll).empty());
  for (int b : buttons(scroll))
    EXPECT_EQ(std::abs(b), 4);
  auto pinch = replay({{2000, Begin, 1, 200, 200}, {2005, Begin, 2, 260, 200},
                       {2030, Update, 1, 140, 200}, {2035, Update, 2, 320, 200},
                       {2080, Update, 1, 60, 200}, {2085, Update, 2, 400, 200},
                       {2200, End, 1, 60, 200}, {2205, End, 2, 400, 200}});
  bool control = false;
  for (const TouchAction& a : pinch)
    control = control || (a.kind == TouchAction::Key && a.keysym == 0xffe3);
  EXPECT_TRUE(control);
}

TEST(TouchGestures, SlowOrCrowdedTouchesAreNotGestures)
{
  EXPECT_TRUE(replay({{2000, Begin, 1, 100, 100}, {2400, Begin, 2, 150, 100},
                      {2450, End, 1, 100, 100}, {2460, End, 2, 150, 100}}).empty());
  EXPECT_TRUE(replay({{2000, Begin, 1, 1, 1}, {2001, Begin, 2, 2, 2}, {2002, Begin, 3, 3, 3}, {2003, Begin, 4, 4, 4},
                      {2050, End, 1, 1, 1}, {2051, End, 2, 2, 2}, {2052, End, 3, 3, 3}, {2053, End, 4, 4, 4}}).empty());
  // Held longer than the tap timeout without moving: a long press, never a tap.
  EXPECT_EQ(buttons(replay({{2000, Begin, 1, 100, 100}, {3500, End, 1, 100, 100}})), (std::vector<int>{3, -3}));
}

TEST(TouchGestures, RandomTouchStreamsMatch)
{
  std::mt19937 random(0x7d9a4c1u);
  for (int stream = 0; stream < 3000; stream++) {
    std::vector<Step> steps;
    std::vector<int> down;
    std::vector<std::pair<double, double>> position(5);
    uint64_t at = 1000 + random() % 2000;
    int length = 2 + random() % 24;
    for (int i = 0; i < length; i++) {
      at += random() % 5 == 0 ? random() % 1500 : random() % 120;
      int choice = random() % 3;
      if ((choice == 0 || down.empty()) && down.size() < 5) {
        int id = 0;
        while (std::find(down.begin(), down.end(), id) != down.end())
          id++;
        position[id] = {double(random() % 800), double(random() % 600)};
        down.push_back(id);
        steps.push_back({at, Begin, id, position[id].first, position[id].second});
      } else if (choice == 1) {
        int id = down[random() % down.size()];
        position[id].first += double(int(random() % 161) - 80);
        position[id].second += double(int(random() % 161) - 80);
        steps.push_back({at, Update, id, position[id].first, position[id].second});
      } else {
        size_t index = random() % down.size();
        int id = down[index];
        down.erase(down.begin() + index);
        steps.push_back({at, End, id, position[id].first, position[id].second});
      }
    }
    for (int id : down) {
      at += random() % 100;
      steps.push_back({at, End, id, position[id].first, position[id].second});
    }
    replay(steps, 0);
    if (HasFailure()) {
      ADD_FAILURE() << "stream " << stream;
      return;
    }
  }
}
