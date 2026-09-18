/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#include "DisplayMetrics.h"
#include <FL/Fl.H>
#include <FL/Fl_Window.H>
#ifdef __APPLE__
#include "cocoa.h"
#endif
DisplayMetrics displayMetrics(Fl_Window* window)
{
  DisplayMetrics m;
  m.screen = window->screen_num();
  m.pixelsPerUnitX = m.pixelsPerUnitY = Fl::screen_scale(m.screen);
#ifdef __APPLE__
  // Cocoa backing conversion describes points -> pixels; FLTK's separate
  // GUI scale describes logical units -> points. Apply each exactly once.
  double x = 1, y = 1;
  cocoa_backing_scale(window, &x, &y);
  m.pixelsPerUnitX *= x; m.pixelsPerUnitY *= y;
#endif
  if (!m.valid()) return DisplayMetrics();
  return m;
}
