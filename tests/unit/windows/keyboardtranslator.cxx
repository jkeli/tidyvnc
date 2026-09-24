// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
//
// Windows.KB equivalence (plans/native-ui-winui TODO W3.4, DESKTOP.md section
// 5): the retained vncviewer/KeyboardWin32 and the helper DLL's extracted
// KeyboardTranslator replay the same message scripts against identical
// scripted keyboards and must produce identical key events, consumption,
// AltGr timer state, shortcut keysym candidates and LED synchronisation.
//
// The retained translator is compiled into this file with its Win32 keyboard
// calls redirected to the scripted keyboard and FLTK's timer replaced by a
// stub (windows/fltk-stub/FL/Fl.H).

#include <windows.h>

#include <assert.h>
#include <string.h>

#include <algorithm>
#include <list>
#include <random>
#include <string>
#include <vector>

#include <core/LogWriter.h>
#include <core/i18n.h>

#include <gtest/gtest.h>

#include <FL/Fl.H>

#include "KeyboardTranslator.h"

using tidyvnc::windows::KeyboardSystem;
using tidyvnc::windows::KeyboardTranslator;
using tidyvnc::windows::KeyEvent;
using tidyvnc::windows::KeyMessage;

namespace {

const HKL layoutUS = reinterpret_cast<HKL>((uintptr_t)0x04090409);
const HKL layoutGerman = reinterpret_cast<HKL>((uintptr_t)0x04070407);
const HKL layoutJapanese = reinterpret_cast<HKL>((uintptr_t)0xe0010411);
const HKL layoutKorean = reinterpret_cast<HKL>((uintptr_t)0xe0010412);

struct KeyInfo {
  UINT vkey;
  UINT scan;
  bool extended;
};

// Physical keys of the scripted keyboard (scan code set 1).
const KeyInfo keys[] = {
  {VK_ESCAPE, 0x01, false}, {'1', 0x02, false}, {'2', 0x03, false}, {'3', 0x04, false}, {'7', 0x08, false},
  {'0', 0x0b, false}, {VK_BACK, 0x0e, false}, {VK_TAB, 0x0f, false}, {'Q', 0x10, false}, {'W', 0x11, false},
  {'E', 0x12, false}, {'R', 0x13, false}, {'Y', 0x15, false}, {VK_OEM_6, 0x1b, false}, {VK_RETURN, 0x1c, false},
  {VK_LCONTROL, 0x1d, false}, {'A', 0x1e, false}, {'S', 0x1f, false}, {VK_OEM_AUTO, 0x29, false},
  {VK_LSHIFT, 0x2a, false}, {'Z', 0x2c, false}, {'C', 0x2e, false}, {'V', 0x2f, false}, {VK_OEM_COMMA, 0x33, false},
  {VK_OEM_PERIOD, 0x34, false}, {VK_RSHIFT, 0x36, false}, {VK_LMENU, 0x38, false}, {VK_SPACE, 0x39, false},
  {VK_CAPITAL, 0x3a, false}, {VK_F1, 0x3b, false}, {VK_F4, 0x3e, false}, {VK_PAUSE, 0x45, false},
  {VK_SCROLL, 0x46, false}, {VK_NUMPAD7, 0x47, false}, {VK_NUMPAD0, 0x52, false}, {VK_DECIMAL, 0x53, false},
  {VK_HANJA, 0x71, false}, {VK_HANGUL, 0x72, false}, {VK_RCONTROL, 0x1d, true}, {VK_VOLUME_DOWN, 0x2e, true},
  {VK_VOLUME_UP, 0x30, true}, {VK_DIVIDE, 0x35, true}, {VK_SNAPSHOT, 0x37, true}, {VK_RMENU, 0x38, true},
  {VK_NUMLOCK, 0x45, true}, {VK_HOME, 0x47, true}, {VK_LEFT, 0x4b, true}, {VK_DELETE, 0x53, true},
  {VK_LWIN, 0x5b, true}, {VK_APPS, 0x5d, true},
};

UINT genericKey(UINT vkey)
{
  switch (vkey) {
  case VK_LSHIFT:
  case VK_RSHIFT:
    return VK_SHIFT;
  case VK_LCONTROL:
  case VK_RCONTROL:
    return VK_CONTROL;
  case VK_LMENU:
  case VK_RMENU:
    return VK_MENU;
  default:
    return vkey;
  }
}

// A deterministic stand-in for the Win32 keyboard: US, German (AltGr layer and
// a dead acute accent), Japanese and Korean layouts, stateful ToUnicode,
// VK_PACKET text, lock-key toggles and recorded SendInput calls.
class ScriptedKeyboard final : public KeyboardSystem {
public:
  HKL currentLayout = layoutUS;
  BYTE state[256] = {};
  WCHAR deadPending = 0;
  WCHAR packet = 0;
  std::vector<INPUT> sent;

  bool keyboardState(BYTE out[256]) override
  {
    memcpy(out, state, sizeof(state));
    return true;
  }
  bool setKeyboardState(BYTE in[256]) override
  {
    memcpy(state, in, sizeof(state));
    return true;
  }
  HKL layout() override { return currentLayout; }
  SHORT keyState(int vkey) override { return (SHORT)(state[vkey & 0xff] & 0x81); }
  UINT sendInput(UINT count, INPUT* inputs) override
  {
    for (UINT i = 0; i < count; i++) {
      sent.push_back(inputs[i]);
      if (!(inputs[i].ki.dwFlags & KEYEVENTF_KEYUP))
        state[inputs[i].ki.wVk] ^= 0x01;
    }
    return count;
  }

  UINT mapVirtualKey(UINT code, UINT type) override
  {
    switch (type) {
    case MAPVK_VK_TO_VSC:
      for (const KeyInfo& key : keys) {
        if (key.vkey == code || genericKey(key.vkey) == code)
          return key.scan;
      }
      return 0;
    case MAPVK_VSC_TO_VK_EX: {
      bool extended = (code & 0xff00) == 0xe000;
      for (const KeyInfo& key : keys) {
        if (key.scan == (code & 0xff) && key.extended == extended)
          return key.vkey;
      }
      return 0;
    }
    case MAPVK_VK_TO_CHAR:
      if (code >= 'A' && code <= 'Z')
        return code;
      if (code >= '0' && code <= '9')
        return code;
      if (code == VK_DECIMAL)
        return currentLayout == layoutGerman ? ',' : '.';
      if (code == VK_OEM_6)
        return currentLayout == layoutGerman ? 0x80000000u | 0x00b4 : ']';
      if (code == VK_SPACE)
        return ' ';
      return 0;
    default:
      return 0;
    }
  }

  int toUnicode(UINT vkey, UINT, const BYTE keyState[256], WCHAR* buffer, int size, UINT) override
  {
    if (size < 2)
      return 0;
    bool shift = (keyState[VK_SHIFT] & 0x80) != 0;
    bool ctrl = (keyState[VK_CONTROL] & 0x80) != 0;
    bool alt = (keyState[VK_MENU] & 0x80) != 0;
    bool german = currentLayout == layoutGerman;

    if (vkey == VK_PACKET) {
      if (!packet)
        return 0;
      buffer[0] = packet;
      return 1;
    }

    if (ctrl && alt) {
      WCHAR ch = 0;
      if (german) {
        switch (vkey) {
        case 'Q': ch = '@'; break;
        case 'E': ch = 0x20ac; break;
        case '2': ch = 0x00b2; break;
        case '7': ch = '{'; break;
        }
      }
      if (!ch)
        return 0;
      return emit(ch, buffer);
    }

    if (ctrl) {
      if (vkey >= 'A' && vkey <= 'Z') {
        buffer[0] = (WCHAR)(vkey - 'A' + 1);
        return 1;
      }
      return 0;
    }

    if (german && vkey == VK_OEM_6 && !shift) {
      if (deadPending) {
        buffer[0] = buffer[1] = deadPending;
        deadPending = 0;
        return 2;
      }
      deadPending = 0x00b4;
      buffer[0] = 0x00b4;
      return -1;
    }

    WCHAR ch = base(vkey, shift, german);
    if (!ch)
      return 0;
    return emit(ch, buffer);
  }

private:
  int emit(WCHAR ch, WCHAR* buffer)
  {
    if (deadPending) {
      WCHAR dead = deadPending;
      deadPending = 0;
      if (dead == 0x00b4 && ch == 'e') {
        buffer[0] = 0x00e9;
        return 1;
      }
      buffer[0] = dead;
      buffer[1] = ch;
      return 2;
    }
    buffer[0] = ch;
    return 1;
  }

  static WCHAR base(UINT vkey, bool shift, bool german)
  {
    if (vkey >= 'A' && vkey <= 'Z') {
      UINT letter = vkey;
      if (german && letter == 'Y')
        letter = 'Z';
      else if (german && letter == 'Z')
        letter = 'Y';
      return (WCHAR)(shift ? letter : letter - 'A' + 'a');
    }
    switch (vkey) {
    case '1': return shift ? '!' : '1';
    case '2': return shift ? (german ? '"' : '@') : '2';
    case '3': return shift ? (german ? 0x00a7 : '#') : '3';
    case '7': return shift ? (german ? '/' : '&') : '7';
    case '0': return shift ? (german ? '=' : ')') : '0';
    case VK_OEM_6: return shift ? (german ? '`' : '}') : ']';
    case VK_OEM_COMMA: return shift ? (german ? ';' : '<') : ',';
    case VK_OEM_PERIOD: return shift ? (german ? ':' : '>') : '.';
    case VK_SPACE: return ' ';
    case VK_RETURN: return '\r';
    case VK_BACK: return 0x08;
    case VK_TAB: return '\t';
    case VK_ESCAPE: return 0x1b;
    default: return 0;
    }
  }
};

ScriptedKeyboard* legacyKeyboard = nullptr;

struct PendingTimeout {
  void (*callback)(void*) = nullptr;
  void* data = nullptr;
} legacyTimer;

} // namespace

void Fl::add_timeout(double, void (*callback)(void*), void* data)
{
  legacyTimer = {callback, data};
}

void Fl::remove_timeout(void (*callback)(void*), void* data)
{
  if (legacyTimer.callback == callback && (!data || legacyTimer.data == data))
    legacyTimer = {};
}

namespace {

BOOL legacyGetKeyboardState(PBYTE state) { return legacyKeyboard->keyboardState(state); }
BOOL legacySetKeyboardState(LPBYTE state) { return legacyKeyboard->setKeyboardState(state); }
int legacyToUnicode(UINT vkey, UINT scan, const BYTE* state, LPWSTR buffer, int size, UINT flags)
{
  return legacyKeyboard->toUnicode(vkey, scan, state, buffer, size, flags);
}
UINT legacyMapVirtualKey(UINT code, UINT type) { return legacyKeyboard->mapVirtualKey(code, type); }
HKL legacyGetKeyboardLayout(DWORD) { return legacyKeyboard->layout(); }
SHORT legacyGetKeyState(int vkey) { return legacyKeyboard->keyState(vkey); }
UINT legacySendInput(UINT count, LPINPUT inputs, int) { return legacyKeyboard->sendInput(count, inputs); }

} // namespace

#undef MapVirtualKey
#define GetKeyboardState legacyGetKeyboardState
#define SetKeyboardState legacySetKeyboardState
#define ToUnicode legacyToUnicode
#define MapVirtualKey legacyMapVirtualKey
#define MapVirtualKeyW legacyMapVirtualKey
#define GetKeyboardLayout legacyGetKeyboardLayout
#define GetKeyState legacyGetKeyState
#define SendInput legacySendInput
#pragma warning(push)
#pragma warning(disable : 4245 4389 4458)
#include "../../../vncviewer/KeyboardWin32.cxx"
#pragma warning(pop)
#undef GetKeyboardState
#undef SetKeyboardState
#undef ToUnicode
#undef MapVirtualKey
#undef MapVirtualKeyW
#undef GetKeyboardLayout
#undef GetKeyState
#undef SendInput

namespace {

class Recorder final : public KeyboardHandler {
public:
  std::vector<KeyEvent> events;
  void handleKeyPress(int systemKeyCode, uint32_t keyCode, uint32_t keySym) override
  {
    events.push_back({true, systemKeyCode, keyCode, keySym});
  }
  void handleKeyRelease(int systemKeyCode) override { events.push_back({false, systemKeyCode, 0, 0}); }
};

std::string describe(const std::vector<KeyEvent>& events)
{
  std::string text;
  char item[64];
  for (const KeyEvent& event : events) {
    snprintf(item, sizeof(item), "%s(0x%x,0x%x,0x%x) ", event.press ? "press" : "release", event.systemKeyCode,
             event.keyCode, event.keySym);
    text += item;
  }
  return text;
}

// Drives both translators in lock step. Every step is applied to both
// scripted keyboards so their states never diverge.
class Harness {
public:
  ScriptedKeyboard legacySystem, extractedSystem;
  Recorder recorder;
  KeyboardWin32 legacy{&recorder};
  KeyboardTranslator extracted{extractedSystem};
  DWORD time = 1000;
  int steps = 0;

  Harness() { legacyTimer = {}; }
  ~Harness() { legacyKeyboard = nullptr; }

  template <class F> void both(F&& change)
  {
    change(legacySystem);
    change(extractedSystem);
  }

  void layout(HKL layout)
  {
    both([layout](ScriptedKeyboard& keyboard) { keyboard.currentLayout = layout; });
  }

  void message(UINT msg, WPARAM wParam, LPARAM lParam)
  {
    SCOPED_TRACE("step " + std::to_string(steps++) + " message 0x" + std::to_string(msg) + " vkey " +
                 std::to_string(wParam) + " lParam " + std::to_string(lParam));
    MSG legacyMessage = {};
    legacyMessage.message = msg;
    legacyMessage.wParam = wParam;
    legacyMessage.lParam = lParam;
    legacyMessage.time = time;
    legacyKeyboard = &legacySystem;
    recorder.events.clear();
    bool legacyConsumed = legacy.handleEvent(&legacyMessage);
    std::vector<KeyEvent> events;
    bool extractedConsumed = extracted.handle({msg, wParam, lParam, time}, events);
    EXPECT_EQ(legacyConsumed, extractedConsumed);
    EXPECT_EQ(describe(recorder.events), describe(events));
    EXPECT_EQ(legacyTimer.callback != nullptr, extracted.timerPending());
  }

  void fireTimer()
  {
    SCOPED_TRACE("step " + std::to_string(steps++) + " timer");
    legacyKeyboard = &legacySystem;
    recorder.events.clear();
    ASSERT_EQ(legacyTimer.callback != nullptr, extracted.timerPending());
    if (legacyTimer.callback) {
      PendingTimeout fire = legacyTimer;
      legacyTimer = {};
      fire.callback(fire.data);
    }
    std::vector<KeyEvent> events;
    extracted.timeout(events);
    EXPECT_EQ(describe(recorder.events), describe(events));
  }

  void reset()
  {
    legacyKeyboard = &legacySystem;
    legacy.reset();
    extracted.reset();
    EXPECT_EQ(legacyTimer.callback != nullptr, extracted.timerPending());
  }

  static LPARAM keyParam(const KeyInfo& key, bool down, bool scanless = false)
  {
    LPARAM lParam = 1;
    if (!scanless)
      lParam |= (LPARAM)key.scan << 16;
    if (key.extended)
      lParam |= (LPARAM)1 << 24;
    if (!down)
      lParam |= ((LPARAM)1 << 30) | ((LPARAM)1 << 31);
    return lParam;
  }

  void setDown(UINT vkey, bool down)
  {
    both([vkey, down](ScriptedKeyboard& keyboard) {
      if (down)
        keyboard.state[vkey] |= 0x80;
      else
        keyboard.state[vkey] &= ~0x80;
      UINT generic = genericKey(vkey);
      if (generic != vkey) {
        bool any = false;
        for (UINT side : {VK_LSHIFT, VK_RSHIFT, VK_LCONTROL, VK_RCONTROL, VK_LMENU, VK_RMENU}) {
          if (genericKey(side) == generic && (keyboard.state[side] & 0x80))
            any = true;
        }
        keyboard.state[generic] = (BYTE)((keyboard.state[generic] & ~0x80) | (any ? 0x80 : 0));
      }
      if (down && (vkey == VK_CAPITAL || vkey == VK_NUMLOCK || vkey == VK_SCROLL))
        keyboard.state[vkey] ^= 0x01;
    });
  }

  void key(UINT vkey, bool down, DWORD advance = 5, bool scanless = false)
  {
    const KeyInfo* info = nullptr;
    for (const KeyInfo& candidate : keys) {
      if (candidate.vkey == vkey)
        info = &candidate;
    }
    ASSERT_NE(info, nullptr) << "unknown key " << vkey;
    time += advance;
    setDown(vkey, down);
    bool alt = (legacySystem.state[VK_MENU] & 0x80) && !(legacySystem.state[VK_CONTROL] & 0x80);
    UINT msg = down ? (alt ? WM_SYSKEYDOWN : WM_KEYDOWN) : (alt ? WM_SYSKEYUP : WM_KEYUP);
    message(msg, genericKey(vkey), keyParam(*info, down, scanless));
  }

  void tap(UINT vkey)
  {
    key(vkey, true);
    key(vkey, false);
  }

  void packet(WCHAR unit)
  {
    both([unit](ScriptedKeyboard& keyboard) { keyboard.packet = unit; });
    time += 1;
    message(WM_KEYDOWN, VK_PACKET, 1);
    message(WM_KEYUP, VK_PACKET, 1 | ((LPARAM)3 << 30));
    both([](ScriptedKeyboard& keyboard) { keyboard.packet = 0; });
  }

  void compareKeySyms()
  {
    legacyKeyboard = &legacySystem;
    for (const KeyInfo& key : keys) {
      int systemKeyCode = (int)key.scan | (key.extended ? 0x80 : 0);
      std::list<uint32_t> expected = legacy.translateToKeySyms(systemKeyCode);
      std::vector<uint32_t> actual = extracted.translateToKeySyms(systemKeyCode);
      EXPECT_EQ(std::vector<uint32_t>(expected.begin(), expected.end()), actual) << "scan 0x" << std::hex << systemKeyCode;
    }
  }
};

} // namespace

TEST(KeyboardTranslator, PlainShiftedAndControlKeysMatchTheRetainedTranslator)
{
  for (HKL layout : {layoutUS, layoutGerman, layoutJapanese, layoutKorean}) {
    Harness h;
    h.layout(layout);
    for (UINT vkey : {(UINT)'A', (UINT)'Z', (UINT)'Y', (UINT)'2', (UINT)VK_SPACE, (UINT)VK_RETURN, (UINT)VK_OEM_COMMA,
                      (UINT)VK_F1, (UINT)VK_LEFT, (UINT)VK_HOME, (UINT)VK_DELETE, (UINT)VK_NUMPAD7, (UINT)VK_NUMPAD0,
                      (UINT)VK_DIVIDE, (UINT)VK_LWIN, (UINT)VK_APPS, (UINT)VK_ESCAPE, (UINT)VK_TAB, (UINT)VK_BACK})
      h.tap(vkey);
    h.key(VK_LSHIFT, true);
    h.tap('A');
    h.tap('2');
    h.tap(VK_OEM_PERIOD);
    h.key(VK_LSHIFT, false);
    h.key(VK_LCONTROL, true);
    h.fireTimer();
    h.tap('C');
    h.tap('V');
    h.key(VK_LCONTROL, false);
    h.key(VK_RCONTROL, true);
    h.tap('A');
    h.key(VK_RCONTROL, false);
    h.key(VK_LMENU, true);
    h.tap(VK_F4);
    h.tap(VK_TAB);
    h.key(VK_LMENU, false);
  }
}

TEST(KeyboardTranslator, AltGrDetectionMergesFastCtrlAltAndTimesOut)
{
  Harness h;
  h.layout(layoutGerman);
  // Windows' AltGr: LCtrl then RAlt with the same timestamp.
  h.key(VK_LCONTROL, true, 5);
  h.key(VK_RMENU, true, 0);
  h.tap('Q');
  h.tap('E');
  h.tap('2');
  h.tap('7');
  h.tap('A');
  h.key(VK_RMENU, false);
  h.key(VK_LCONTROL, false, 0);
  // Just under and over the 50 ms window.
  h.key(VK_LCONTROL, true);
  h.key(VK_RMENU, true, 49);
  h.key(VK_RMENU, false);
  h.key(VK_LCONTROL, false);
  h.key(VK_LCONTROL, true);
  h.key(VK_RMENU, true, 50);
  h.key(VK_RMENU, false);
  h.key(VK_LCONTROL, false);
  // Ctrl alone: the timer sends it.
  h.key(VK_LCONTROL, true);
  h.fireTimer();
  h.tap('C');
  h.key(VK_LCONTROL, false);
  // Ctrl then another key, a mouse event or a release resolves detection.
  h.key(VK_LCONTROL, true);
  h.tap('S');
  h.key(VK_LCONTROL, false);
  h.key(VK_LCONTROL, true);
  h.message(WM_MOUSEMOVE, 0, 0);
  h.key(VK_LCONTROL, false);
  h.key(VK_LCONTROL, true);
  h.message(WM_LBUTTONDOWN, MK_LBUTTON, 0);
  h.message(WM_LBUTTONUP, 0, 0);
  h.key(VK_LCONTROL, false);
  h.key(VK_LCONTROL, true);
  h.key(VK_LCONTROL, false);
  // Touch keyboard: the Alt of AltGr arrives without a scan code.
  h.key(VK_LCONTROL, true);
  h.setDown(VK_RMENU, true);
  h.message(WM_KEYDOWN, VK_MENU, 1);
  h.tap('Q');
  h.setDown(VK_RMENU, false);
  h.message(WM_KEYUP, VK_MENU, 1 | ((LPARAM)3 << 30));
  h.key(VK_LCONTROL, false);
  // Reset while armed.
  h.key(VK_LCONTROL, true);
  h.reset();
  h.key(VK_LCONTROL, false);
  // US has no AltGr: Ctrl is never held back.
  h.layout(layoutUS);
  h.key(VK_LCONTROL, true, 5);
  h.key(VK_RMENU, true, 0);
  h.tap('Q');
  h.key(VK_RMENU, false);
  h.key(VK_LCONTROL, false);
}

TEST(KeyboardTranslator, ShiftReleaseWorkaroundAndResets)
{
  Harness h;
  h.key(VK_LSHIFT, true);
  h.key(VK_RSHIFT, true);
  h.tap('A');
  // Windows only reports one release when both are held.
  h.key(VK_RSHIFT, false);
  h.setDown(VK_LSHIFT, false);
  h.tap('A');
  h.key(VK_RSHIFT, true);
  h.reset();
  h.key(VK_RSHIFT, false);
}

TEST(KeyboardTranslator, SpecialScanCodesAndMultimediaKeys)
{
  for (HKL layout : {layoutUS, layoutGerman}) {
    Harness h;
    h.layout(layout);
    h.tap(VK_PAUSE);
    h.tap(VK_NUMLOCK);
    h.tap(VK_SCROLL);
    h.tap(VK_CAPITAL);
    h.tap(VK_SNAPSHOT);
    h.tap(VK_DECIMAL);
    // Break (Ctrl+Pause, scan 0x46 extended) and SysRq (Alt+PrintScreen, 0x54).
    h.message(WM_KEYDOWN, VK_CANCEL, 1 | (0x46 << 16) | (1 << 24));
    h.message(WM_KEYUP, VK_CANCEL, 1 | (0x46 << 16) | (1 << 24) | ((LPARAM)3 << 30));
    h.message(WM_SYSKEYDOWN, VK_SNAPSHOT, 1 | (0x54 << 16));
    h.message(WM_SYSKEYUP, VK_SNAPSHOT, 1 | (0x54 << 16) | ((LPARAM)3 << 30));
    // Media keys arrive with scan code 0.
    h.key(VK_VOLUME_UP, true, 5, true);
    h.key(VK_VOLUME_UP, false, 5, true);
    h.key(VK_VOLUME_DOWN, true, 5, true);
    h.key(VK_VOLUME_DOWN, false, 5, true);
    // No scan code at all, an invalid scan code, and our own fake scan code.
    h.message(WM_KEYDOWN, VK_BROWSER_BACK, 1 | (1 << 24));
    h.message(WM_KEYUP, VK_BROWSER_BACK, 1 | (1 << 24) | ((LPARAM)3 << 30));
    h.message(WM_KEYDOWN, 'A', 1 | (0xaa << 16));
    h.message(WM_KEYUP, 'A', 1 | (0xaa << 16) | ((LPARAM)3 << 30));
    h.message(WM_KEYDOWN, 'A', 1 | (0x9e << 16));
    h.message(WM_KEYUP, 'A', 1 | (0x9e << 16) | ((LPARAM)3 << 30));
    // Other messages are not the keyboard's.
    h.message(WM_CHAR, 'a', 1);
    h.message(WM_PAINT, 0, 0);
  }
}

TEST(KeyboardTranslator, DeadKeysLeaveNoStateBehind)
{
  Harness h;
  h.layout(layoutGerman);
  h.tap(VK_OEM_6);
  h.tap('E');
  h.tap(VK_OEM_6);
  h.tap(VK_OEM_6);
  h.key(VK_LSHIFT, true);
  h.tap(VK_OEM_6);
  h.key(VK_LSHIFT, false);
  EXPECT_EQ(0, h.legacySystem.deadPending);
  EXPECT_EQ(0, h.extractedSystem.deadPending);
}

TEST(KeyboardTranslator, VkPacketTextAndSurrogatePairs)
{
  Harness h;
  h.packet(L'x');
  h.packet(0x00e9);
  // U+1F600 as a pair, then unmatched high, lone low, and high followed by BMP text.
  h.packet(0xd83d);
  h.packet(0xde00);
  h.packet(0xd83d);
  h.packet(0xd83d);
  h.packet(0xde00);
  h.packet(0xde00);
  h.packet(0xd83d);
  h.packet(L'y');
  h.packet(0xd83d);
  h.tap('A');
}

TEST(KeyboardTranslator, JapaneseAndKoreanLayoutKeys)
{
  Harness h;
  h.layout(layoutJapanese);
  h.tap(VK_OEM_AUTO); // Zenkaku/Hankaku: no reliable release, sent at once.
  h.tap(VK_HANGUL);
  h.layout(layoutKorean);
  h.tap(VK_HANGUL);
  h.tap(VK_HANJA);
  h.tap(VK_OEM_AUTO);
}

TEST(KeyboardTranslator, ShortcutKeySymCandidatesMatch)
{
  for (HKL layout : {layoutUS, layoutGerman, layoutJapanese, layoutKorean}) {
    Harness h;
    h.layout(layout);
    h.compareKeySyms();
  }
}

TEST(KeyboardTranslator, LedStateReadAndSynchronisation)
{
  Harness h;
  legacyKeyboard = &h.legacySystem;
  for (unsigned initial = 0; initial < 8; initial++) {
    for (unsigned target = 0; target < 8; target++) {
      h.both([initial](ScriptedKeyboard& keyboard) {
        keyboard.state[VK_SCROLL] = (initial & 1) ? 1 : 0;
        keyboard.state[VK_NUMLOCK] = (initial & 2) ? 1 : 0;
        keyboard.state[VK_CAPITAL] = (initial & 4) ? 1 : 0;
        keyboard.sent.clear();
      });
      EXPECT_EQ(h.legacy.getLEDState(), h.extracted.ledState());
      h.legacy.setLEDState(target);
      EXPECT_TRUE(h.extracted.setLedState(target));
      ASSERT_EQ(h.legacySystem.sent.size(), h.extractedSystem.sent.size());
      for (size_t i = 0; i < h.legacySystem.sent.size(); i++)
        EXPECT_EQ(0, memcmp(&h.legacySystem.sent[i], &h.extractedSystem.sent[i], sizeof(INPUT)));
      EXPECT_EQ(target, h.extracted.ledState());
      EXPECT_EQ(h.legacy.getLEDState(), h.extracted.ledState());
    }
  }
}

// Random interleavings of the whole key set, modifiers, text, mouse events,
// timer expiry and layout switches.
TEST(KeyboardTranslator, RandomMessageStreamsMatch)
{
  std::mt19937 random(20260923);
  for (int round = 0; round < 40; round++) {
    Harness h;
    const HKL layouts[] = {layoutUS, layoutGerman, layoutJapanese, layoutKorean};
    h.layout(layouts[round % 4]);
    for (int step = 0; step < 400; step++) {
      int choice = (int)(random() % 100);
      if (choice < 70) {
        const KeyInfo& key = keys[random() % (sizeof(keys) / sizeof(keys[0]))];
        bool down = (random() % 2) == 0;
        DWORD advance = (DWORD)(random() % 4 == 0 ? random() % 120 : random() % 30);
        h.key(key.vkey, down, advance, (random() % 16) == 0);
      } else if (choice < 78) {
        h.packet((WCHAR)(random() % 3 == 0 ? 0xd800 + (random() % 0x800) : 0x20 + (random() % 0x3000)));
      } else if (choice < 85) {
        h.message(WM_MOUSEMOVE + (UINT)(random() % 2), 0, 0);
      } else if (choice < 93) {
        h.fireTimer();
      } else if (choice < 97) {
        h.layout(layouts[random() % 4]);
      } else {
        h.reset();
      }
      if (::testing::Test::HasFailure())
        return;
    }
  }
}
