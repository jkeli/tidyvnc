// Copyright 2011-2021 Pierre Ossman for Cendio AB; 2026 TidyVNC contributors.
// Licensed under GPL-2.0-or-later.
//
// Extracted from vncviewer/KeyboardWin32.cxx (TODO W3.4). Keep the two in
// step: tests/unit/windows/keyboardtranslator.cxx replays message scripts
// through both and requires identical events.

#include "KeyboardTranslator.h"

#include <algorithm>
#include <cassert>
#include <cstring>

#define XK_MISCELLANY
#define XK_XKB_KEYS
#define XK_KOREAN
#include <rfb/keysymdef.h>
#include <rfb/XF86keysym.h>
#include <rfb/ledStates.h>

#include "keysym2ucs.h"

#define NoSymbol 0

namespace tidyvnc::windows {
namespace {

// Used to detect fake input (0xaa is not a real key)
constexpr WORD SCAN_FAKE = 0xaa;

// Fake scan code to represent VK_PACKET
constexpr int SCAN_VK_PACKET = 0x1ff;

// Layout independent keys
const UINT vkey_map[][3] = {
  { VK_CANCEL,              NoSymbol,       XK_Break },
  { VK_BACK,                XK_BackSpace,   NoSymbol },
  { VK_TAB,                 XK_Tab,         NoSymbol },
  { VK_CLEAR,               XK_Clear,       NoSymbol },
  { VK_RETURN,              XK_Return,      XK_KP_Enter },
  { VK_SHIFT,               XK_Shift_L,     NoSymbol },
  { VK_CONTROL,             XK_Control_L,   XK_Control_R },
  { VK_MENU,                XK_Alt_L,       XK_Alt_R },
  { VK_PAUSE,               XK_Pause,       NoSymbol },
  { VK_CAPITAL,             XK_Caps_Lock,   NoSymbol },
  { VK_ESCAPE,              XK_Escape,      NoSymbol },
  { VK_CONVERT,             XK_Henkan,      NoSymbol },
  { VK_NONCONVERT,          XK_Muhenkan,    NoSymbol },
  { VK_PRIOR,               XK_KP_Prior,    XK_Prior },
  { VK_NEXT,                XK_KP_Next,     XK_Next },
  { VK_END,                 XK_KP_End,      XK_End },
  { VK_HOME,                XK_KP_Home,     XK_Home },
  { VK_LEFT,                XK_KP_Left,     XK_Left },
  { VK_UP,                  XK_KP_Up,       XK_Up },
  { VK_RIGHT,               XK_KP_Right,    XK_Right },
  { VK_DOWN,                XK_KP_Down,     XK_Down },
  { VK_SNAPSHOT,            XK_Sys_Req,     XK_Print },
  { VK_INSERT,              XK_KP_Insert,   XK_Insert },
  { VK_DELETE,              XK_KP_Delete,   XK_Delete },
  { VK_LWIN,                NoSymbol,       XK_Super_L },
  { VK_RWIN,                NoSymbol,       XK_Super_R },
  { VK_APPS,                NoSymbol,       XK_Menu },
  { VK_SLEEP,               NoSymbol,       XF86XK_Sleep },
  { VK_NUMPAD0,             XK_KP_0,        NoSymbol },
  { VK_NUMPAD1,             XK_KP_1,        NoSymbol },
  { VK_NUMPAD2,             XK_KP_2,        NoSymbol },
  { VK_NUMPAD3,             XK_KP_3,        NoSymbol },
  { VK_NUMPAD4,             XK_KP_4,        NoSymbol },
  { VK_NUMPAD5,             XK_KP_5,        NoSymbol },
  { VK_NUMPAD6,             XK_KP_6,        NoSymbol },
  { VK_NUMPAD7,             XK_KP_7,        NoSymbol },
  { VK_NUMPAD8,             XK_KP_8,        NoSymbol },
  { VK_NUMPAD9,             XK_KP_9,        NoSymbol },
  { VK_MULTIPLY,            XK_KP_Multiply, NoSymbol },
  { VK_ADD,                 XK_KP_Add,      NoSymbol },
  { VK_SUBTRACT,            XK_KP_Subtract, NoSymbol },
  { VK_DIVIDE,              NoSymbol,       XK_KP_Divide },
  /* VK_SEPARATOR and VK_DECIMAL left out on purpose. See further down. */
  { VK_F1,                  XK_F1,          NoSymbol },
  { VK_F2,                  XK_F2,          NoSymbol },
  { VK_F3,                  XK_F3,          NoSymbol },
  { VK_F4,                  XK_F4,          NoSymbol },
  { VK_F5,                  XK_F5,          NoSymbol },
  { VK_F6,                  XK_F6,          NoSymbol },
  { VK_F7,                  XK_F7,          NoSymbol },
  { VK_F8,                  XK_F8,          NoSymbol },
  { VK_F9,                  XK_F9,          NoSymbol },
  { VK_F10,                 XK_F10,         NoSymbol },
  { VK_F11,                 XK_F11,         NoSymbol },
  { VK_F12,                 XK_F12,         NoSymbol },
  { VK_F13,                 XK_F13,         NoSymbol },
  { VK_F14,                 XK_F14,         NoSymbol },
  { VK_F15,                 XK_F15,         NoSymbol },
  { VK_F16,                 XK_F16,         NoSymbol },
  { VK_F17,                 XK_F17,         NoSymbol },
  { VK_F18,                 XK_F18,         NoSymbol },
  { VK_F19,                 XK_F19,         NoSymbol },
  { VK_F20,                 XK_F20,         NoSymbol },
  { VK_F21,                 XK_F21,         NoSymbol },
  { VK_F22,                 XK_F22,         NoSymbol },
  { VK_F23,                 XK_F23,         NoSymbol },
  { VK_F24,                 XK_F24,         NoSymbol },
  { VK_NUMLOCK,             NoSymbol,       XK_Num_Lock },
  { VK_SCROLL,              XK_Scroll_Lock, NoSymbol },
  { VK_BROWSER_BACK,        NoSymbol,       XF86XK_Back },
  { VK_BROWSER_FORWARD,     NoSymbol,       XF86XK_Forward },
  { VK_BROWSER_REFRESH,     NoSymbol,       XF86XK_Refresh },
  { VK_BROWSER_STOP,        NoSymbol,       XF86XK_Stop },
  { VK_BROWSER_SEARCH,      NoSymbol,       XF86XK_Search },
  { VK_BROWSER_FAVORITES,   NoSymbol,       XF86XK_Favorites },
  { VK_BROWSER_HOME,        NoSymbol,       XF86XK_HomePage },
  { VK_VOLUME_MUTE,         NoSymbol,       XF86XK_AudioMute },
  { VK_VOLUME_DOWN,         NoSymbol,       XF86XK_AudioLowerVolume },
  { VK_VOLUME_UP,           NoSymbol,       XF86XK_AudioRaiseVolume },
  { VK_MEDIA_NEXT_TRACK,    NoSymbol,       XF86XK_AudioNext },
  { VK_MEDIA_PREV_TRACK,    NoSymbol,       XF86XK_AudioPrev },
  { VK_MEDIA_STOP,          NoSymbol,       XF86XK_AudioStop },
  { VK_MEDIA_PLAY_PAUSE,    NoSymbol,       XF86XK_AudioPlay },
  { VK_LAUNCH_MAIL,         NoSymbol,       XF86XK_Mail },
  { VK_LAUNCH_MEDIA_SELECT, NoSymbol,       XF86XK_AudioMedia },
  { VK_LAUNCH_APP1,         NoSymbol,       XF86XK_MyComputer },
  { VK_LAUNCH_APP2,         NoSymbol,       XF86XK_Calculator },
};

// Layout dependent keys, but without useful symbols

// Japanese
const UINT vkey_map_jp[][3] = {
  { VK_KANA,                XK_Hiragana_Katakana, NoSymbol },
  { VK_KANJI,               XK_Kanji,       NoSymbol },
  { VK_OEM_ATTN,            XK_Eisu_toggle, NoSymbol },
  { VK_OEM_FINISH,          XK_Katakana,    NoSymbol },
  { VK_OEM_COPY,            XK_Hiragana,    NoSymbol },
  // These are really XK_Zenkaku/XK_Hankaku but we have no way of
  // keeping the client and server in sync
  { VK_OEM_AUTO,            XK_Zenkaku_Hankaku, NoSymbol },
  { VK_OEM_ENLW,            XK_Zenkaku_Hankaku, NoSymbol },
  { VK_OEM_BACKTAB,         XK_Romaji,      NoSymbol },
  { VK_ATTN,                XK_Romaji,      NoSymbol },
};

// Korean
const UINT vkey_map_ko[][3] = {
  { VK_HANGUL,              XK_Hangul,      NoSymbol },
  { VK_HANJA,               XK_Hangul_Hanja, NoSymbol },
};

template <size_t N>
uint32_t lookupVKeyMap(unsigned vkey, bool extended, const UINT (&map)[N][3])
{
  for (const auto& entry : map) {
    if (vkey == entry[0])
      return extended ? entry[2] : entry[1];
  }
  return NoSymbol;
}

bool isMouseMessage(UINT message)
{
  switch (message) {
  case WM_MOUSEMOVE:
  case WM_LBUTTONDOWN:
  case WM_LBUTTONUP:
  case WM_RBUTTONDOWN:
  case WM_RBUTTONUP:
  case WM_MBUTTONDOWN:
  case WM_MBUTTONUP:
  case WM_XBUTTONDOWN:
  case WM_XBUTTONUP:
  case WM_MOUSEWHEEL:
  case WM_MOUSEHWHEEL:
    return true;
  default:
    return false;
  }
}

void press(std::vector<KeyEvent>& events, int systemKeyCode, uint32_t keyCode, uint32_t keySym)
{
  events.push_back({true, systemKeyCode, keyCode, keySym});
}

void release(std::vector<KeyEvent>& events, int systemKeyCode)
{
  events.push_back({false, systemKeyCode, 0, 0});
}

void modifierState(BYTE state[256], unsigned mods)
{
  memset(state, 0, 256);
  if (mods & 0x1)
    state[VK_CONTROL] = state[VK_LCONTROL] = 0x80;
  if (mods & 0x2)
    state[VK_SHIFT] = state[VK_LSHIFT] = 0x80;
  if (mods & 0x4)
    state[VK_MENU] = state[VK_LMENU] = 0x80;
  if (mods & 0x8) {
    state[VK_CONTROL] = state[VK_LCONTROL] = 0x80;
    state[VK_MENU] = state[VK_RMENU] = 0x80;
  }
}

class Win32Keyboard final : public KeyboardSystem {
public:
  bool keyboardState(BYTE state[256]) override { return GetKeyboardState(state) != FALSE; }
  bool setKeyboardState(BYTE state[256]) override { return SetKeyboardState(state) != FALSE; }
  int toUnicode(UINT vkey, UINT scan, const BYTE state[256], WCHAR* buffer, int size, UINT flags) override
  {
    return ToUnicode(vkey, scan, state, buffer, size, flags);
  }
  UINT mapVirtualKey(UINT code, UINT type) override { return MapVirtualKeyW(code, type); }
  HKL layout() override { return GetKeyboardLayout(0); }
  SHORT keyState(int vkey) override { return GetKeyState(vkey); }
  UINT sendInput(UINT count, INPUT* inputs) override { return SendInput(count, inputs, sizeof(*inputs)); }
};

} // namespace

KeyboardSystem& systemKeyboard()
{
  static Win32Keyboard keyboard;
  return keyboard;
}

KeyboardTranslator::KeyboardTranslator(KeyboardSystem& system_) : system(system_) {}

bool KeyboardTranslator::handle(const KeyMessage& msg, std::vector<KeyEvent>& events)
{
  if (isMouseMessage(msg.message)) {
    // We can't get a mouse event in the middle of an AltGr sequence, so
    // abort that detection
    if (altGrArmed)
      resolveAltGrDetection(false, events);
    return false; // We didn't really consume the mouse event
  } else if ((msg.message == WM_KEYDOWN) || (msg.message == WM_SYSKEYDOWN)) {
    UINT vKey = (UINT)msg.wParam;
    bool isExtended = (msg.lParam & (1 << 24)) != 0;
    int systemKeyCode = ((msg.lParam >> 16) & 0xff);
    BYTE state[256];

    // Windows' touch keyboard doesn't set a scan code for the Alt
    // portion of the AltGr sequence, so we need to help it out
    if (!isExtended && (systemKeyCode == 0x00) && (vKey == VK_MENU)) {
      isExtended = true;
      systemKeyCode = 0x38;
    }

    // Windows doesn't have a proper AltGr, but handles it using fake
    // Ctrl+Alt. However the remote end might not be Windows, so we need
    // to merge those in to a single AltGr event. We detect this case
    // by seeing the two key events directly after each other with a very
    // short time between them (<50ms) and supress the Ctrl event.
    if (altGrArmed) {
      bool altPressed = isExtended && (systemKeyCode == 0x38) && (vKey == VK_MENU) && ((msg.time - altGrCtrlTime) < 50);
      resolveAltGrDetection(altPressed, events);
    }

    if (systemKeyCode == SCAN_FAKE)
      return true; // Fake key press (our own LED synchronisation)

    if (vKey == VK_PACKET)
      systemKeyCode = SCAN_VK_PACKET;

    // Windows sets the scan code to 0x00 for multimedia keys, so we
    // have to do a reverse lookup based on the vKey.
    if (systemKeyCode == 0x00) {
      systemKeyCode = (int)system.mapVirtualKey(vKey, MAPVK_VK_TO_VSC);
      if (systemKeyCode == 0x00)
        return true; // No scan code for the virtual key
    }

    if (systemKeyCode != SCAN_VK_PACKET && (systemKeyCode & ~0x7f))
      return true; // Invalid scan code

    if (isExtended)
      systemKeyCode |= 0x80;

    systemKeyCode = fixSystemKeyCode(systemKeyCode);
    uint32_t keyCode = translateSystemKeyCode(systemKeyCode);

    system.keyboardState(state);

    // Pressing Ctrl wreaks havoc with the symbol lookup, so turn
    // that off. But AltGr shows up as Ctrl+Alt in Windows, so keep
    // Ctrl if Alt is active.
    if (!(state[VK_LCONTROL] & 0x80) || !(state[VK_RMENU] & 0x80))
      state[VK_CONTROL] = state[VK_LCONTROL] = state[VK_RCONTROL] = 0;

    uint32_t keySym = translateVKey(vKey, isExtended, state);

    // VK_PACKET Surrogate pair handling
    if (vKey == VK_PACKET && ((keySym | 0x7ff) == 0x0100dfff)) {
      unsigned ucsCode = keySym & 0xffff; // keySym == 0b11011xxxxxxxxxxx
      if ((ucsCode & 0xfc00) == 0xd800) { // keySym == 0b110110xxxxxxxxxx
        // We have received a high surrogate code unit. Remember it and wait for
        // the low surrogate which should come immediately after. A second high
        // surrogate replaces the first (unmatched pair).
        vkPacketHighSurrogate = ucsCode;
        return true;
      } else {
        assert((ucsCode & 0xfc00) == 0xdc00);
        // A low surrogate not directly preceded by a high surrogate is dropped.
        if (!vkPacketHighSurrogate)
          return true;
        uint32_t codePoint = (((vkPacketHighSurrogate & 0x03ff) << 10) | (ucsCode & 0x03ff)) + 0x010000;
        vkPacketHighSurrogate = 0;
        keySym = ucs2keysym(codePoint);
      }
    } else if (vkPacketHighSurrogate) {
      // High surrogate not directly followed by a low surrogate
      vkPacketHighSurrogate = 0;
    }

    if (keySym == NoSymbol) {
      // Most Ctrl+Alt combinations will fail to produce a symbol, so
      // try it again with Ctrl unconditionally disabled.
      state[VK_CONTROL] = state[VK_LCONTROL] = state[VK_RCONTROL] = 0;
      keySym = translateVKey(vKey, isExtended, state);
    }

    // Windows sends the same vKey for both shifts, so we need to look
    // at the scan code to tell them apart
    if ((keySym == XK_Shift_L) && (systemKeyCode == 0x36))
      keySym = XK_Shift_R;

    // AltGr handling (see above)
    if (hasAltGr()) {
      if ((systemKeyCode == 0xb8) && (keySym == XK_Alt_R))
        keySym = XK_ISO_Level3_Shift;

      // Possible start of AltGr sequence?
      if ((systemKeyCode == 0x1d) && (keySym == XK_Control_L)) {
        altGrArmed = true;
        altGrCtrlTime = msg.time;
        return true;
      }
    }

    press(events, systemKeyCode, keyCode, keySym);

    // While VK_PACKET does deliver a key release immediately after key down, we
    // gain nothing from relying on it.
    if (systemKeyCode == SCAN_VK_PACKET)
      release(events, systemKeyCode);

    // We don't get reliable WM_KEYUP for these
    switch (keySym) {
    case XK_Zenkaku_Hankaku:
    case XK_Eisu_toggle:
    case XK_Katakana:
    case XK_Hiragana:
    case XK_Romaji:
      release(events, systemKeyCode);
    }

    // Shift key tracking, see below
    if (systemKeyCode == 0x2a)
      leftShiftDown = true;
    if (systemKeyCode == 0x36)
      rightShiftDown = true;

    return true;
  } else if ((msg.message == WM_KEYUP) || (msg.message == WM_SYSKEYUP)) {
    UINT vKey = (UINT)msg.wParam;
    bool isExtended = (msg.lParam & (1 << 24)) != 0;
    int systemKeyCode = ((msg.lParam >> 16) & 0xff);

    // Touch keyboard AltGr (see above)
    if (!isExtended && (systemKeyCode == 0x00) && (vKey == VK_MENU)) {
      isExtended = true;
      systemKeyCode = 0x38;
    }

    // We can't get a release in the middle of an AltGr sequence, so
    // abort that detection
    if (altGrArmed)
      resolveAltGrDetection(false, events);

    if (systemKeyCode == SCAN_FAKE)
      return true;

    if (vKey == VK_PACKET) {
      // Release of VK_PACKET handled in WM_KEYDOWN branch above.
      return true;
    }

    if (systemKeyCode == 0x00)
      systemKeyCode = (int)system.mapVirtualKey(vKey, MAPVK_VK_TO_VSC);
    if (isExtended)
      systemKeyCode |= 0x80;

    systemKeyCode = fixSystemKeyCode(systemKeyCode);

    release(events, systemKeyCode);

    // Windows has a rather nasty bug where it won't send key release
    // events for a Shift button if the other Shift is still pressed
    if ((systemKeyCode == 0x2a) || (systemKeyCode == 0x36)) {
      if (leftShiftDown)
        release(events, 0x2a);
      if (rightShiftDown)
        release(events, 0x36);
      leftShiftDown = false;
      rightShiftDown = false;
    }

    return true;
  }

  return false;
}

void KeyboardTranslator::timeout(std::vector<KeyEvent>& events)
{
  if (!altGrArmed)
    return;
  altGrArmed = false;
  press(events, 0x1d, 0x1d, XK_Control_L);
}

void KeyboardTranslator::reset()
{
  altGrArmed = false;
  leftShiftDown = false;
  rightShiftDown = false;
}

std::vector<uint32_t> KeyboardTranslator::translateToKeySyms(int systemKeyCode)
{
  std::vector<uint32_t> keySyms;
  BYTE state[256];

  auto add = [&keySyms](uint32_t ks) {
    if (ks != NoSymbol && std::find(keySyms.begin(), keySyms.end(), ks) == keySyms.end())
      keySyms.push_back(ks);
  };

  bool extended = (systemKeyCode & 0x80) != 0;
  if (extended)
    systemKeyCode = 0xe0 | (systemKeyCode & 0x7f);

  unsigned vkey = system.mapVirtualKey((UINT)systemKeyCode, MAPVK_VSC_TO_VK_EX);
  if (vkey == 0)
    return keySyms;

  // Start with no modifiers
  memset(state, 0, sizeof(state));
  add(translateVKey(vkey, extended, state));

  // Next just a single modifier at a time
  for (unsigned mods = 1; mods < 16; mods <<= 1) {
    modifierState(state, mods);
    add(translateVKey(vkey, extended, state));
  }

  // Finally everything
  for (unsigned mods = 0; mods < 16; mods++) {
    modifierState(state, mods);
    add(translateVKey(vkey, extended, state));
  }

  // As a final resort we use MapVirtualKey() as that gives us a Latin
  // character even on non-Latin keyboards, which is useful for
  // shortcuts
  UINT ch = system.mapVirtualKey(vkey, MAPVK_VK_TO_CHAR);
  if (ch != 0) {
    if (ch & 0x80000000)
      ch = ucs2combining(ch & 0xffff);
    else
      ch = ch & 0xffff;
    add(ucs2keysym(ch));
  }

  return keySyms;
}

unsigned KeyboardTranslator::ledState()
{
  unsigned state = 0;
  if (system.keyState(VK_CAPITAL) & 0x1)
    state |= rfb::ledCapsLock;
  if (system.keyState(VK_NUMLOCK) & 0x1)
    state |= rfb::ledNumLock;
  if (system.keyState(VK_SCROLL) & 0x1)
    state |= rfb::ledScrollLock;
  return state;
}

bool KeyboardTranslator::setLedState(unsigned state)
{
  INPUT input[6];
  UINT count = 0;

  memset(input, 0, sizeof(input));

  auto toggle = [&](WORD vkey, DWORD flags) {
    input[count].type = input[count + 1].type = INPUT_KEYBOARD;
    input[count].ki.wVk = input[count + 1].ki.wVk = vkey;
    input[count].ki.wScan = input[count + 1].ki.wScan = SCAN_FAKE;
    input[count].ki.dwFlags = flags;
    input[count + 1].ki.dwFlags = KEYEVENTF_KEYUP | flags;
    count += 2;
  };

  if (!!(state & rfb::ledCapsLock) != !!(system.keyState(VK_CAPITAL) & 0x1))
    toggle(VK_CAPITAL, 0);
  if (!!(state & rfb::ledNumLock) != !!(system.keyState(VK_NUMLOCK) & 0x1))
    toggle(VK_NUMLOCK, KEYEVENTF_EXTENDEDKEY);
  if (!!(state & rfb::ledScrollLock) != !!(system.keyState(VK_SCROLL) & 0x1))
    toggle(VK_SCROLL, 0);

  if (count == 0)
    return true;

  return system.sendInput(count, input) == count;
}

int KeyboardTranslator::fixSystemKeyCode(int systemKeyCode)
{
  // We need stable key codes for everything, but Windows changes the
  // key code for some keys depending on modifiers

  // Break (Ctrl+Pause) to normal Pause
  if (systemKeyCode == 0xc6)
    return 0x45;

  // SysRq (Alt+PrintScreen) to PrintScreen
  if (systemKeyCode == 0xb7)
    return 0x54;

  return systemKeyCode;
}

uint32_t KeyboardTranslator::translateSystemKeyCode(int systemKeyCode)
{
  // Fortunately RFB and Windows use the same scan code set (mostly),
  // so there is no conversion needed
  // (as long as we encode the extended keys with the high bit)

  // However Pause sends a code that conflicts with NumLock, so use
  // the code most RFB implementations use (part of the sequence for
  // Ctrl+Pause, i.e. Break)
  if (systemKeyCode == 0x45)
    return 0xc6;

  // And NumLock incorrectly has the extended bit set
  if (systemKeyCode == 0xc5)
    return 0x45;

  // VK_PACKET only has a fake key code, and should be sent to server as 0.
  if (systemKeyCode == SCAN_VK_PACKET)
    return 0;

  return (uint32_t)systemKeyCode;
}

uint32_t KeyboardTranslator::translateVKey(unsigned vkey, bool extended, const unsigned char state[256])
{
  int ret;
  WCHAR wstr[10];

  // Start with keys that either don't generate a symbol, or
  // generate the same symbol as some other key.

  uint32_t ks = lookupVKeyMap(vkey, extended, vkey_map);
  if (ks != NoSymbol)
    return ks;

  HKL layout = system.layout();
  WORD lang = LOWORD(layout);
  WORD primary_lang = PRIMARYLANGID(lang);

  if (primary_lang == LANG_JAPANESE) {
    ks = lookupVKeyMap(vkey, extended, vkey_map_jp);
    if (ks != NoSymbol)
      return ks;
  }

  if (primary_lang == LANG_KOREAN) {
    ks = lookupVKeyMap(vkey, extended, vkey_map_ko);
    if (ks != NoSymbol)
      return ks;
  }

  // Windows is not consistent in which virtual key it uses for
  // the numpad decimal key, and this is not likely to be fixed:
  // http://blogs.msdn.com/michkap/archive/2006/09/13/752377.aspx
  //
  // To get X11 behaviour, we instead look at the text generated
  // by they key.
  if ((vkey == VK_DECIMAL) || (vkey == VK_SEPARATOR)) {
    switch (system.mapVirtualKey(vkey, MAPVK_VK_TO_CHAR)) {
    case ',':
      return XK_KP_Separator;
    case '.':
      return XK_KP_Decimal;
    default:
      return NoSymbol;
    }
  }

  // MapVirtualKey() doesn't look at modifiers, so it is
  // insufficient for mapping most keys to a symbol. ToUnicode()
  // does what we want though. Unfortunately it keeps state, so
  // we have to be careful around dead characters.

  // FIXME: Multi character results, like U+0644 U+0627
  //        on Arabic layout
  ret = system.toUnicode(vkey, 0, state, wstr, (int)(sizeof(wstr) / sizeof(wstr[0])), 0);

  if (vkey == VK_PACKET && ret == 1 && ((wstr[0] | 0x7ff) == 0xdfff)) {
    // ucs2keysym correctly refuses to translate surrogate code units. They are
    // invalid code points and invalid keysyms. Here, they are used only as
    // intermediate values to be picked up by handle().
    return (unsigned)wstr[0] | 0x01000000;
  }

  if (ret == 1)
    return ucs2keysym(wstr[0]);

  if (ret == -1) {
    WCHAR dead_char = wstr[0];

    // Need to clear out the state that the dead key has caused.
    // This is the recommended method by Microsoft's engineers:
    // http://blogs.msdn.com/b/michkap/archive/2007/10/27/5717859.aspx
    do {
      ret = system.toUnicode(vkey, 0, state, wstr, (int)(sizeof(wstr) / sizeof(wstr[0])), 0);
    } while (ret < 0);

    // Dead keys are represented by their spacing equivalent
    // (or something similar depending on the layout)
    return ucs2keysym(ucs2combining(dead_char));
  }

  return NoSymbol;
}

bool KeyboardTranslator::hasAltGr()
{
  BYTE origState[256];
  BYTE altGrState[256];

  if (currentLayout == system.layout())
    return cachedHasAltGr;

  // Save current keyboard state so we can get things sane again after
  // we're done
  if (!system.keyboardState(origState))
    return false;

  // We press Ctrl+Alt (Windows fake AltGr) and then test every key
  // to see if it produces a printable character. If so then we assume
  // AltGr is used in the current layout.

  cachedHasAltGr = false;

  memset(altGrState, 0, sizeof(altGrState));
  altGrState[VK_CONTROL] = 0x80;
  altGrState[VK_MENU] = 0x80;

  for (UINT vkey = 0; vkey <= 0xff; vkey++) {
    WCHAR wstr[10];

    // Need to skip this one as it is a bit magical and will trigger
    // a false positive
    if (vkey == VK_PACKET)
      continue;

    int ret = system.toUnicode(vkey, 0, altGrState, wstr, (int)(sizeof(wstr) / sizeof(wstr[0])), 0);
    if (ret == 1) {
      cachedHasAltGr = true;
      break;
    }

    if (ret == -1) {
      // Dead key, need to clear out state before we proceed
      do {
        ret = system.toUnicode(vkey, 0, altGrState, wstr, (int)(sizeof(wstr) / sizeof(wstr[0])), 0);
      } while (ret < 0);
    }
  }

  system.setKeyboardState(origState);

  currentLayout = system.layout();

  return cachedHasAltGr;
}

void KeyboardTranslator::resolveAltGrDetection(bool isAltGrSequence, std::vector<KeyEvent>& events)
{
  altGrArmed = false;
  // when it's not an AltGr sequence we can't supress the Ctrl anymore
  if (!isAltGrSequence)
    press(events, 0x1d, 0x1d, XK_Control_L);
}

} // namespace tidyvnc::windows
