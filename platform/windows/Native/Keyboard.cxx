// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
//
// tidyvnc_windows.h keyboard surface: the translator, the UI-thread message
// hook (D12) and the low-level capture hook (SERVICES.md section 8).

#include "tidyvnc_windows.h"

#include "KeyboardTranslator.h"

#include <atomic>
#include <mutex>
#include <new>
#include <vector>

using tidyvnc::windows::KeyboardTranslator;
using tidyvnc::windows::KeyEvent;
using tidyvnc::windows::KeyMessage;

struct tvw_keyboard {
  KeyboardTranslator translator;
  std::vector<KeyEvent> events;
};

namespace {

int32_t deliver(tvw_keyboard* keyboard, tvw_key_event* events, uint32_t capacity, tvw_key_result* result)
{
  uint32_t count = 0;
  for (const KeyEvent& event : keyboard->events) {
    if (count == capacity)
      break;
    events[count++] = {event.press ? (uint32_t)TVW_KEY_PRESS : (uint32_t)TVW_KEY_RELEASE, event.systemKeyCode, event.keyCode,
                       event.keySym};
  }
  bool truncated = count < keyboard->events.size();
  keyboard->events.clear();
  result->count = count;
  result->timer_pending = keyboard->translator.timerPending() ? 1 : 0;
  result->timer_delay_ms = result->timer_pending ? KeyboardTranslator::altGrTimeoutMs : 0;
  return truncated ? E_NOT_SUFFICIENT_BUFFER : S_OK;
}

} // namespace

extern "C" {

int32_t tvw_keyboard_create(tvw_keyboard** out)
{
  if (!out)
    return E_POINTER;
  *out = new (std::nothrow) tvw_keyboard();
  return *out ? S_OK : E_OUTOFMEMORY;
}

int32_t tvw_keyboard_handle(tvw_keyboard* keyboard, const tvw_key_message* message, tvw_key_event* events, uint32_t capacity,
                            tvw_key_result* result)
{
  if (!keyboard || !message || !result || (capacity && !events))
    return E_POINTER;
  *result = {};
  try {
    KeyMessage msg{message->message, (WPARAM)message->wparam, (LPARAM)message->lparam, message->time};
    result->consumed = keyboard->translator.handle(msg, keyboard->events) ? 1 : 0;
    return deliver(keyboard, events, capacity, result);
  } catch (const std::bad_alloc&) {
    keyboard->events.clear();
    return E_OUTOFMEMORY;
  }
}

int32_t tvw_keyboard_timeout(tvw_keyboard* keyboard, tvw_key_event* events, uint32_t capacity, tvw_key_result* result)
{
  if (!keyboard || !result || (capacity && !events))
    return E_POINTER;
  *result = {};
  try {
    keyboard->translator.timeout(keyboard->events);
    return deliver(keyboard, events, capacity, result);
  } catch (const std::bad_alloc&) {
    keyboard->events.clear();
    return E_OUTOFMEMORY;
  }
}

void tvw_keyboard_reset(tvw_keyboard* keyboard)
{
  if (keyboard)
    keyboard->translator.reset();
}

int32_t tvw_keyboard_keysyms(tvw_keyboard* keyboard, int32_t system_key_code, uint32_t* keysyms, uint32_t capacity, uint32_t* count)
{
  if (!keyboard || !count || (capacity && !keysyms))
    return E_POINTER;
  *count = 0;
  try {
    auto candidates = keyboard->translator.translateToKeySyms(system_key_code);
    for (uint32_t keysym : candidates) {
      if (*count == capacity)
        return E_NOT_SUFFICIENT_BUFFER;
      keysyms[(*count)++] = keysym;
    }
    return S_OK;
  } catch (const std::bad_alloc&) {
    return E_OUTOFMEMORY;
  }
}

void tvw_keyboard_destroy(tvw_keyboard* keyboard)
{
  delete keyboard;
}

uint32_t tvw_keyboard_led_state(void)
{
  return KeyboardTranslator().ledState();
}

int32_t tvw_keyboard_set_led_state(uint32_t state)
{
  return KeyboardTranslator().setLedState(state) ? S_OK : HRESULT_FROM_WIN32(GetLastError());
}

} // extern "C"

