// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
// The part of FLTK's Fl class that vncviewer/KeyboardWin32.cxx uses, so the
// retained translator can run in keyboardtranslator.cxx without FLTK. The
// test implements the timer functions and fires timeouts explicitly.
#ifndef TIDYVNC_TEST_FLTK_STUB_FL_H
#define TIDYVNC_TEST_FLTK_STUB_FL_H

class Fl {
public:
  static void add_timeout(double seconds, void (*callback)(void*), void* data);
  static void remove_timeout(void (*callback)(void*), void* data = nullptr);
};

#endif
