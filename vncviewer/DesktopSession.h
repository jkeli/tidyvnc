/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_DESKTOP_SESSION_H
#define TIDYVNC_DESKTOP_SESSION_H
#include <set>
class CConn;
class PlatformPixelBuffer;
class Viewport;

// One connection-owned source buffer and damage stream, shared by all views.
// The first viewport retains keyboard, pointer throttling and clipboard state.
class DesktopSession {
public:
  DesktopSession(CConn* connection, int width, int height);
  ~DesktopSession();
  void attach(Viewport* view);
  void detach(Viewport* view);
  void synchronize();
  void update();
  void resize(int width, int height);
  PlatformPixelBuffer* buffer() const { return framebuffer; }
  const std::set<Viewport*>& views() const { return consumers; }
  Viewport* inputOwner() const { return input; }
private:
  static void flushDamage(void* data);
  CConn* cc;
  PlatformPixelBuffer* framebuffer;
  std::set<Viewport*> consumers;
  Viewport* input = nullptr;
};
#endif
