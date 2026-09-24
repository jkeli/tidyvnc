// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
//
// tvw_touch_*: the touch gesture engine (TouchGestures) behind the helper's C API.

#include <windows.h>

#include <deque>
#include <new>

#include "TouchGestures.h"
#include "tidyvnc_windows.h"

using tidyvnc::windows::TouchAction;
using tidyvnc::windows::TouchGestures;

struct tvw_touch {
  explicit tvw_touch(uint64_t now) : gestures(now) {}
  TouchGestures gestures;
  std::deque<TouchAction> pending;
};

int32_t tvw_touch_create(uint64_t now_ms, tvw_touch** out)
{
  if (!out)
    return E_POINTER;
  *out = new (std::nothrow) tvw_touch(now_ms);
  return *out ? S_OK : E_OUTOFMEMORY;
}

int32_t tvw_touch_handle(tvw_touch* touch, uint32_t phase, int32_t id, double x, double y, uint64_t now_ms,
                         tvw_touch_action* actions, uint32_t capacity, tvw_touch_result* result)
{
  if (!touch || !result || (capacity && !actions))
    return E_POINTER;
  *result = {};
  try {
    switch (phase) {
    case TVW_TOUCH_BEGIN: touch->gestures.begin(id, x, y, now_ms); break;
    case TVW_TOUCH_UPDATE: touch->gestures.update(id, x, y, now_ms); break;
    case TVW_TOUCH_END: touch->gestures.end(id, now_ms); break;
    case TVW_TOUCH_TIMEOUT: touch->gestures.timeout(now_ms); break;
    case TVW_TOUCH_DRAIN: break;
    default: return E_INVALIDARG;
    }
    for (const TouchAction& action : touch->gestures.take())
      touch->pending.push_back(action);
  } catch (const std::bad_alloc&) {
    return E_OUTOFMEMORY;
  }
  while (result->count < capacity && !touch->pending.empty()) {
    const TouchAction& action = touch->pending.front();
    actions[result->count++] = {static_cast<uint32_t>(action.kind), action.press ? 1u : 0u, action.button, action.keysym,
                                action.x, action.y};
    touch->pending.pop_front();
  }
  result->more = static_cast<uint32_t>(touch->pending.size());
  result->deadline_ms = touch->gestures.deadline();
  return S_OK;
}

void tvw_touch_destroy(tvw_touch* touch) { delete touch; }
