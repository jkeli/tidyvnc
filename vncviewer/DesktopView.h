/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_DESKTOP_VIEW_H
#define TIDYVNC_DESKTOP_VIEW_H
#include <FL/Fl_Window.H>
#include <viewer/core/DesktopLayout.h>
#include <memory>
class DesktopWindow;
class DesktopSession;
class Viewport;
class Surface;
class CConn;

// Secondary macOS fullscreen surface. It owns no connection or input state.
class DesktopView : public Fl_Window {
public:
  DesktopView(DesktopWindow* owner, CConn* connection,
              std::shared_ptr<DesktopSession> session, const DesktopRegion& region);
  ~DesktopView();
  void draw() override;
  int handle(int event) override;
  Viewport* viewport;
  DesktopWindow* owner;
  uint32_t monitorId;
private:
  static void closeView(Fl_Widget*,void* data);
  static void displayChanged(void* data);
  Surface* composition = nullptr;
  void* observer = nullptr;
  DisplayMetrics lastMetrics;
  bool haveMetrics = false;
};
#endif
