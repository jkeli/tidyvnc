// Copyright 2011-2021 Pierre Ossman for Cendio AB; 2026 TidyVNC contributors.
// Licensed under GPL-2.0-or-later.
#ifndef TIDYVNC_WINDOWS_KEYBOARD_TRANSLATOR_H
#define TIDYVNC_WINDOWS_KEYBOARD_TRANSLATOR_H

#include <windows.h>

#include <stdint.h>

#include <vector>

namespace tidyvnc::windows {

// The Win32 calls the translator depends on. The production implementation
// calls the system; tests substitute a scripted layout so the translator can
// be compared with the retained vncviewer/KeyboardWin32 (TODO W3.4).
class KeyboardSystem {
public:
  virtual ~KeyboardSystem() = default;
  virtual bool keyboardState(BYTE state[256]) = 0;
  virtual bool setKeyboardState(BYTE state[256]) = 0;
  virtual int toUnicode(UINT vkey, UINT scan, const BYTE state[256], WCHAR* buffer, int size, UINT flags) = 0;
  virtual UINT mapVirtualKey(UINT code, UINT type) = 0;
  virtual HKL layout() = 0;
  virtual SHORT keyState(int vkey) = 0;
  virtual UINT sendInput(UINT count, INPUT* inputs) = 0;
};

KeyboardSystem& systemKeyboard();

struct KeyEvent {
  bool press;
  int systemKeyCode;
  uint32_t keyCode;
  uint32_t keySym;
  bool operator==(const KeyEvent& other) const
  {
    return press == other.press && systemKeyCode == other.systemKeyCode && keyCode == other.keyCode && keySym == other.keySym;
  }
};

struct KeyMessage {
  UINT message;
  WPARAM wParam;
  LPARAM lParam;
  DWORD time;
};

// vncviewer/KeyboardWin32 without FLTK or logging. Behaviour is identical;
// the 100 ms AltGr timer is reported through timerPending() and fired by the
// host with timeout().
class KeyboardTranslator {
public:
  explicit KeyboardTranslator(KeyboardSystem& system = systemKeyboard());

  static constexpr unsigned altGrTimeoutMs = 100;

  // Returns whether the message was consumed; events are appended.
  bool handle(const KeyMessage& message, std::vector<KeyEvent>& events);
  void timeout(std::vector<KeyEvent>& events);
  bool timerPending() const { return altGrArmed; }
  void reset();

  std::vector<uint32_t> translateToKeySyms(int systemKeyCode);
  unsigned ledState();
  bool setLedState(unsigned state);

private:
  static int fixSystemKeyCode(int systemKeyCode);
  static uint32_t translateSystemKeyCode(int systemKeyCode);
  uint32_t translateVKey(unsigned vkey, bool extended, const unsigned char state[256]);
  bool hasAltGr();
  void resolveAltGrDetection(bool isAltGrSequence, std::vector<KeyEvent>& events);

  KeyboardSystem& system;
  bool cachedHasAltGr = false;
  HKL currentLayout = nullptr;
  bool altGrArmed = false;
  DWORD altGrCtrlTime = 0;
  uint32_t vkPacketHighSurrogate = 0;
  bool leftShiftDown = false;
  bool rightShiftDown = false;
};

} // namespace tidyvnc::windows

#endif
