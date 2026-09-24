// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
//
// Extracted from vncviewer/GestureHandler.cxx (Copyright 2019 Aaron Sowry,
// 2020 Pierre Ossman for Cendio AB) and vncviewer/BaseTouchHandler.cxx
// (Copyright 2019 Aaron Sowry, 2019-2020 Pierre Ossman for Cendio AB), both
// GPL-2.0-or-later. The logic, constants and arithmetic types are unchanged;
// timers and gettimeofday() became an injected millisecond clock.

#ifndef _USE_MATH_DEFINES
#define _USE_MATH_DEFINES
#endif
#include "TouchGestures.h"

#include <assert.h>
#include <math.h>
#include <stdlib.h>

namespace tidyvnc::windows {

namespace {

const unsigned char GH_NOGESTURE = 0;
const unsigned char GH_ONETAP    = 1;
const unsigned char GH_TWOTAP    = 2;
const unsigned char GH_THREETAP  = 4;
const unsigned char GH_DRAG      = 8;
const unsigned char GH_LONGPRESS = 16;
const unsigned char GH_TWODRAG   = 32;
const unsigned char GH_PINCH     = 64;

const unsigned char GH_INITSTATE = 127;

const unsigned GH_MOVE_THRESHOLD = 50;
const unsigned GH_ANGLE_THRESHOLD = 90; // Degrees

// Timeout when waiting for gestures (ms)
const unsigned GH_MULTITOUCH_TIMEOUT = 250;
// Maximum time between press and release for a tap (ms)
const unsigned GH_TAP_TIMEOUT = 1000;
// Timeout when waiting for longpress (ms)
const unsigned GH_LONGPRESS_TIMEOUT = 1000;
// Timeout when waiting to decide between PINCH and TWODRAG (ms)
const unsigned GH_TWOTOUCH_TIMEOUT = 50;

// Sensitivity threshold for gestures
const int ZOOMSENS = 30;
const int SCRLSENS = 50;

const unsigned DOUBLE_TAP_TIMEOUT   = 1000;
const unsigned DOUBLE_TAP_THRESHOLD = 50;

const uint32_t XK_Control_L = 0xffe3;

// core::msSince() semantics: elapsed milliseconds as unsigned.
unsigned since(uint64_t then, uint64_t now) { return (unsigned)(now - then); }

} // namespace

TouchGestures::TouchGestures(uint64_t now) : state(GH_INITSTATE), lastTapTime(now) {}

void TouchGestures::begin(int id, double x, double y, uint64_t now)
{
  Touch ght;

  // Ignore any new touches if there is already an active gesture,
  // or we're in a cleanup state
  if (hasDetectedGesture() || (state == GH_NOGESTURE)) {
    ignored.insert(id);
    return;
  }

  // Did it take too long between touches that we should no longer
  // consider this a single gesture?
  if ((tracked.size() > 0) && (since(tracked.begin()->second.started, now) > GH_MULTITOUCH_TIMEOUT)) {
    state = GH_NOGESTURE;
    ignored.insert(id);
    return;
  }

  // If we're waiting for fingers to release then we should no longer
  // recognize new touches
  if (waitingRelease) {
    state = GH_NOGESTURE;
    ignored.insert(id);
    return;
  }

  ght.started = now;
  ght.active = true;
  ght.lastX = ght.firstX = x;
  ght.lastY = ght.firstY = y;
  ght.angle = 0;

  tracked[id] = ght;

  switch (tracked.size()) {
    case 1:
      longpressTimer.start(now, GH_LONGPRESS_TIMEOUT);
      break;
    case 2:
      state &= ~(GH_ONETAP | GH_DRAG | GH_LONGPRESS);
      longpressTimer.stop();
      break;
    case 3:
      state &= ~(GH_TWOTAP | GH_TWODRAG | GH_PINCH);
      break;
    default:
      state = GH_NOGESTURE;
  }
}

void TouchGestures::update(int id, double x, double y, uint64_t now)
{
  Touch *touch, *prevTouch;
  double deltaX, deltaY, prevDeltaMove;
  unsigned deltaAngle;

  // If this is an update for a touch we're not tracking, ignore it
  if (tracked.count(id) == 0)
    return;

  touch = &tracked[id];

  // Update the touches last position with the event coordinates
  touch->lastX = x;
  touch->lastY = y;

  deltaX = x - touch->firstX;
  deltaY = y - touch->firstY;

  // Update angle when the touch has moved
  if ((touch->firstX != touch->lastX) || (touch->firstY != touch->lastY))
    touch->angle = (int)(atan2(deltaY, deltaX) * 180 / M_PI);

  if (!hasDetectedGesture()) {
    // Ignore moves smaller than the minimum threshold
    if (hypot(deltaX, deltaY) < GH_MOVE_THRESHOLD)
      return;

    // Can't be a tap or long press as we've seen movement
    state &= ~(GH_ONETAP | GH_TWOTAP | GH_THREETAP | GH_LONGPRESS);
    longpressTimer.stop();

    if (tracked.size() != 1)
      state &= ~(GH_DRAG);
    if (tracked.size() != 2)
      state &= ~(GH_TWODRAG | GH_PINCH);

    // We need to figure out which of our different two touch gestures
    // this might be
    if (tracked.size() == 2) {
      // The other touch can be first or last in tracked
      // depending on which event came first
      prevTouch = &tracked.rbegin()->second;
      if (prevTouch == touch)
        prevTouch = &tracked.begin()->second;

      // How far the previous touch point has moved since start
      prevDeltaMove = hypot(prevTouch->firstX - prevTouch->lastX, prevTouch->firstY - prevTouch->lastY);

      // We know that the current touch moved far enough,
      // but unless both touches moved further than their
      // threshold we don't want to disqualify any gestures
      if (prevDeltaMove > GH_MOVE_THRESHOLD) {
        // The angle difference between the direction of the touch points
        deltaAngle = (unsigned)fabs((double)(touch->angle - prevTouch->angle));
        deltaAngle = (unsigned)fabs((double)(((deltaAngle + 180) % 360) - 180));

        // PINCH or TWODRAG can be eliminated depending on the angle
        if (deltaAngle > GH_ANGLE_THRESHOLD)
          state &= ~GH_TWODRAG;
        else
          state &= ~GH_PINCH;

        if (twoTouchTimer.started)
          twoTouchTimer.stop();
      } else if (!twoTouchTimer.started) {
        // We can't determine the gesture right now, let's
        // wait and see if more events are on their way
        twoTouchTimer.start(now, GH_TWOTOUCH_TIMEOUT);
      }
    }

    if (!hasDetectedGesture())
      return;

    pushEvent(Begin, now);
  }

  pushEvent(Update, now);
}

void TouchGestures::end(int id, uint64_t now)
{
  // Check if this is an ignored touch
  if (ignored.count(id)) {
    ignored.erase(id);
    if (ignored.empty() && tracked.empty()) {
      state = GH_INITSTATE;
      waitingRelease = false;
    }
    return;
  }

  // We got a TouchEnd before the timer triggered,
  // this cannot result in a gesture anymore.
  if (!hasDetectedGesture() && twoTouchTimer.started) {
    twoTouchTimer.stop();
    state = GH_NOGESTURE;
  }

  // Some gestures don't trigger until a touch is released
  if (!hasDetectedGesture()) {
    // Can't be a gesture that relies on movement
    state &= ~(GH_DRAG | GH_TWODRAG | GH_PINCH);
    // Or something that relies on more time
    state &= ~GH_LONGPRESS;
    longpressTimer.stop();

    if (!waitingRelease) {
      releaseStart = now;
      waitingRelease = true;

      // Can't be a tap that requires more touches than we current have
      switch (tracked.size()) {
        case 1:
          state &= ~(GH_TWOTAP | GH_THREETAP);
          break;
        case 2:
          state &= ~(GH_ONETAP | GH_THREETAP);
          break;
      }
    }
  }

  // Waiting for all touches to release? (i.e. some tap)
  if (waitingRelease) {
    // Were all touches released at roughly the same time?
    if (since(releaseStart, now) > GH_MULTITOUCH_TIMEOUT)
      state = GH_NOGESTURE;

    // Did too long time pass between press and release?
    for (const auto& [_, touch] : tracked) {
      if (since(touch.started, now) > GH_TAP_TIMEOUT) {
        state = GH_NOGESTURE;
        break;
      }
    }

    tracked[id].active = false;

    // Are we still waiting for more releases?
    if (hasDetectedGesture()) {
      pushEvent(Begin, now);
    } else {
      // Have we reached a dead end?
      if (state != GH_NOGESTURE)
        return;
    }
  }

  if (hasDetectedGesture())
    pushEvent(End, now);

  // Ignore any remaining touches until they are ended
  for (const auto& [touchId, touch] : tracked) {
    if (touch.active)
      ignored.insert(touchId);
  }
  tracked.clear();

  state = GH_NOGESTURE;

  ignored.erase(id);
  if (ignored.empty()) {
    state = GH_INITSTATE;
    waitingRelease = false;
  }
}

void TouchGestures::timeout(uint64_t now)
{
  for (;;) {
    Timer* next = nullptr;
    for (Timer* timer : {&longpressTimer, &twoTouchTimer})
      if (timer->started && timer->due <= now && (next == nullptr || timer->due < next->due))
        next = timer;
    if (next == nullptr)
      return;
    next->stop();
    if (next == &longpressTimer)
      longpressTimeout(now);
    else
      twoTouchTimeout(now);
  }
}

uint64_t TouchGestures::deadline() const
{
  uint64_t due = NoDeadline;
  if (longpressTimer.started && longpressTimer.due < due)
    due = longpressTimer.due;
  if (twoTouchTimer.started && twoTouchTimer.due < due)
    due = twoTouchTimer.due;
  return due;
}

std::vector<TouchAction> TouchGestures::take()
{
  std::vector<TouchAction> result;
  result.swap(actions);
  return result;
}

bool TouchGestures::hasDetectedGesture() const
{
  if (state == GH_NOGESTURE)
    return false;
  // Check to see if the bitmask value is a power of 2
  // (i.e. only one bit set). If it is, we have a state.
  if (state & (state - 1))
    return false;

  // For taps we also need to have all touches released
  // before we've fully detected the gesture
  if (state & (GH_ONETAP | GH_TWOTAP | GH_THREETAP)) {
    // Any touch still active/pressed?
    for (const auto& [_, touch] : tracked) {
      if (touch.active)
        return false;
    }
  }

  return true;
}

void TouchGestures::longpressTimeout(uint64_t now)
{
  assert(!hasDetectedGesture());

  state = GH_LONGPRESS;
  pushEvent(Begin, now);
}

void TouchGestures::twoTouchTimeout(uint64_t now)
{
  double avgMoveH, avgMoveV, fdx, fdy, ldx, ldy, deltaTouchDistance;

  assert(!tracked.empty());

  // How far each touch point has moved since start
  getAverageMovement(&avgMoveH, &avgMoveV);
  avgMoveH = fabs(avgMoveH);
  avgMoveV = fabs(avgMoveV);

  // The difference in the distance between where
  // the touch points started and where they are now
  getAverageDistance(&fdx, &fdy, &ldx, &ldy);
  deltaTouchDistance = fabs(hypot(fdx, fdy) - hypot(ldx, ldy));

  if ((avgMoveV < deltaTouchDistance) && (avgMoveH < deltaTouchDistance))
    state = GH_PINCH;
  else
    state = GH_TWODRAG;

  pushEvent(Begin, now);
  pushEvent(Update, now);
}

void TouchGestures::pushEvent(EventType type, uint64_t now)
{
  Event gev;
  double avgX, avgY;

  gev.type = type;
  gev.gesture = stateToGesture(state);

  // For most gesture events the current (average) position is the
  // most useful
  getPosition(nullptr, nullptr, &avgX, &avgY);

  // However we have a slight distance to detect gestures, so for the
  // first gesture event we want to use the first positions we saw
  if (type == Begin)
    getPosition(&avgX, &avgY, nullptr, nullptr);

  // For these gestures, we always want the event coordinates
  // to be where the gesture began, not the current touch location.
  switch (state) {
    case GH_TWODRAG:
    case GH_PINCH:
      getPosition(&avgX, &avgY, nullptr, nullptr);
      break;
  }

  gev.eventX = avgX;
  gev.eventY = avgY;
  gev.magnitudeX = gev.magnitudeY = 0; // Unused by the other gestures.

  // Some gestures also have a magnitude
  if (state == GH_PINCH) {
    if (type == Begin)
      getAverageDistance(&gev.magnitudeX, &gev.magnitudeY, nullptr, nullptr);
    else
      getAverageDistance(nullptr, nullptr, &gev.magnitudeX, &gev.magnitudeY);
  } else if (state == GH_TWODRAG) {
    if (type == Begin)
      gev.magnitudeX = gev.magnitudeY = 0;
    else
      getAverageMovement(&gev.magnitudeX, &gev.magnitudeY);
  }

  handleGestureEvent(gev, now);
}

TouchGestures::Gesture TouchGestures::stateToGesture(unsigned char state)
{
  switch (state) {
    case GH_ONETAP: return OneTap;
    case GH_TWOTAP: return TwoTap;
    case GH_THREETAP: return ThreeTap;
    case GH_DRAG: return Drag;
    case GH_LONGPRESS: return LongPress;
    case GH_TWODRAG: return TwoDrag;
    case GH_PINCH: return Pinch;
  }
  assert(false);
  return OneTap;
}

void TouchGestures::getPosition(double* firstX, double* firstY, double* lastX, double* lastY) const
{
  double fx = 0, fy = 0, lx = 0, ly = 0;

  assert(!tracked.empty());

  size_t size = tracked.size();
  for (const auto& [_, touch] : tracked) {
    fx += touch.firstX;
    fy += touch.firstY;
    lx += touch.lastX;
    ly += touch.lastY;
  }

  if (firstX) *firstX = fx / size;
  if (firstY) *firstY = fy / size;
  if (lastX) *lastX = lx / size;
  if (lastY) *lastY = ly / size;
}

void TouchGestures::getAverageMovement(double* h, double* v) const
{
  double totalH = 0, totalV = 0;

  assert(!tracked.empty());

  size_t size = tracked.size();
  for (const auto& [_, touch] : tracked) {
    totalH += touch.lastX - touch.firstX;
    totalV += touch.lastY - touch.firstY;
  }

  if (h) *h = totalH / size;
  if (v) *v = totalV / size;
}

void TouchGestures::getAverageDistance(double* firstX, double* firstY, double* lastX, double* lastY) const
{
  double dx, dy;

  assert(!tracked.empty());

  // Distance between the first and last tracked touches
  dx = fabs(tracked.rbegin()->second.firstX - tracked.begin()->second.firstX);
  dy = fabs(tracked.rbegin()->second.firstY - tracked.begin()->second.firstY);
  if (firstX) *firstX = dx;
  if (firstY) *firstY = dy;

  dx = fabs(tracked.rbegin()->second.lastX - tracked.begin()->second.lastX);
  dy = fabs(tracked.rbegin()->second.lastY - tracked.begin()->second.lastY);
  if (lastX) *lastX = dx;
  if (lastY) *lastY = dy;
}

// ---- BaseTouchHandler --------------------------------------------------------------

void TouchGestures::handleGestureEvent(const Event& ev, uint64_t now)
{
  double magnitude;

  switch (ev.type) {
  case Begin:
    switch (ev.gesture) {
    case OneTap: handleTapEvent(ev, 1, now); break;
    case TwoTap: handleTapEvent(ev, 3, now); break;
    case ThreeTap: handleTapEvent(ev, 2, now); break;
    case Drag:
      motion(ev);
      button(true, 1, ev);
      break;
    case LongPress:
      motion(ev);
      button(true, 3, ev);
      break;
    case TwoDrag:
      lastMagnitudeX = ev.magnitudeX;
      lastMagnitudeY = ev.magnitudeY;
      motion(ev);
      break;
    case Pinch:
      lastMagnitudeX = hypot(ev.magnitudeX, ev.magnitudeY);
      motion(ev);
      break;
    }
    break;

  case Update:
    switch (ev.gesture) {
    case OneTap:
    case TwoTap:
    case ThreeTap:
      break;
    case Drag:
    case LongPress:
      motion(ev);
      break;
    case TwoDrag:
      // Always scroll in the same position.
      motion(ev);
      while ((ev.magnitudeY - lastMagnitudeY) > SCRLSENS) {
        button(true, 4, ev);
        button(false, 4, ev);
        lastMagnitudeY += SCRLSENS;
      }
      while ((ev.magnitudeY - lastMagnitudeY) < -SCRLSENS) {
        button(true, 5, ev);
        button(false, 5, ev);
        lastMagnitudeY -= SCRLSENS;
      }
      while ((ev.magnitudeX - lastMagnitudeX) > SCRLSENS) {
        button(true, 6, ev);
        button(false, 6, ev);
        lastMagnitudeX += SCRLSENS;
      }
      while ((ev.magnitudeX - lastMagnitudeX) < -SCRLSENS) {
        button(true, 7, ev);
        button(false, 7, ev);
        lastMagnitudeX -= SCRLSENS;
      }
      break;
    case Pinch:
      // Always scroll in the same position.
      motion(ev);
      magnitude = hypot(ev.magnitudeX, ev.magnitudeY);
      // abs() on a double is the floating-point overload in C++, as in the retained code.
      if (fabs(magnitude - lastMagnitudeX) > ZOOMSENS) {
        key(true, XK_Control_L, ev);

        while ((magnitude - lastMagnitudeX) > ZOOMSENS) {
          button(true, 4, ev);
          button(false, 4, ev);
          lastMagnitudeX += ZOOMSENS;
        }
        while ((magnitude - lastMagnitudeX) < -ZOOMSENS) {
          button(true, 5, ev);
          button(false, 5, ev);
          lastMagnitudeX -= ZOOMSENS;
        }

        key(false, XK_Control_L, ev);
      }
    }
    break;

  case End:
    switch (ev.gesture) {
    case OneTap:
    case TwoTap:
    case ThreeTap:
    case Pinch:
    case TwoDrag:
      break;
    case Drag:
      motion(ev);
      button(false, 1, ev);
      break;
    case LongPress:
      motion(ev);
      button(false, 3, ev);
      break;
    }
    break;
  }
}

void TouchGestures::handleTapEvent(const Event& ev, int buttonEvent, uint64_t now)
{
  Event newEv = ev;

  // If the user quickly taps multiple times we assume they meant to
  // hit the same spot, so slightly adjust coordinates
  if ((since(lastTapTime, now) < DOUBLE_TAP_TIMEOUT) && (firstDoubleTapEvent.type == ev.type)) {
    double dx = firstDoubleTapEvent.eventX - ev.eventX;
    double dy = firstDoubleTapEvent.eventY - ev.eventY;
    double distance = hypot(dx, dy);

    if (distance < DOUBLE_TAP_THRESHOLD) {
      newEv.eventX = firstDoubleTapEvent.eventX;
      newEv.eventY = firstDoubleTapEvent.eventY;
    } else {
      firstDoubleTapEvent = ev;
    }
  } else {
    firstDoubleTapEvent = ev;
  }
  lastTapTime = now;

  motion(newEv);
  button(true, buttonEvent, newEv);
  button(false, buttonEvent, newEv);
}

void TouchGestures::motion(const Event& ev) { actions.push_back({TouchAction::Motion, false, 0, 0, ev.eventX, ev.eventY}); }

void TouchGestures::button(bool press, int button, const Event& ev)
{
  actions.push_back({TouchAction::Button, press, button, 0, ev.eventX, ev.eventY});
}

void TouchGestures::key(bool press, uint32_t keysym, const Event& ev)
{
  actions.push_back({TouchAction::Key, press, 0, keysym, ev.eventX, ev.eventY});
}

} // namespace tidyvnc::windows
