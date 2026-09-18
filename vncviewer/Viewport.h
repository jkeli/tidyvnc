/* Copyright (C) 2002-2005 RealVNC Ltd.  All Rights Reserved.
 * Copyright 2011-2021 Pierre Ossman <ossman@cendio.se> for Cendio AB
 * 
 * This is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 * 
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this software; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307,
 * USA.
 */

#ifndef __VIEWPORT_H__
#define __VIEWPORT_H__

#include <core/Rect.h>
#include <memory>

#include <FL/Fl_Widget.H>

#include <viewer/core/DesktopTransform.h>
#include <viewer/core/DesktopTileCache.h>
#include "EmulateMB.h"
#include "Keyboard.h"
#include "ShortcutHandler.h"

namespace rfb { class PixelFormat; }

class Fl_Menu_Button;
class Fl_RGB_Image;

class CConn;
class DesktopSession;
class Keyboard;
class PlatformPixelBuffer;
class Surface;
class CursorRenderer;

class Viewport : public Fl_Widget, protected EmulateMB,
                 protected KeyboardHandler {
public:

  Viewport(int w, int h, CConn* cc_, std::shared_ptr<DesktopSession> session = {});
  ~Viewport();

  std::shared_ptr<DesktopSession> desktopSession() const { return session; }
  void sourceDamaged(const core::Rect& damage);
  void flushSourceDamage();
  void sourceReplaced();
  bool sessionFocused();
  void setCacheBudget(size_t bytes) { tileCache.setBudget(bytes); }

  // Most efficient format (from Viewport's point of view)
  const rfb::PixelFormat &getPreferredPF();

  // Flush updates to screen
  void updateWindow();
  void resizeFramebuffer(int width, int height);
  void configureDisplay(int availableWidth, int availableHeight);
  DesktopTransform transform() const;
  void setDisplayOrigin(double x, double y);
  double displayX() const { return originX; }
  double displayY() const { return originY; }
  void setCanvas(int width, int height, const core::Rect& region,
                 double panX = 0, double panY = 0);
  void clearCanvas();
  int remoteWidth() const;
  int remoteHeight() const;

  // New image for the locally rendered cursor
  void setCursor();

  // Change client LED state
  void setLEDState(unsigned int state);

  void draw(Surface* dst, int originBX = 0, int originBY = 0);

  // Clipboard events
  void handleClipboardRequest();
  void handleClipboardAnnounce(bool available);
  void handleClipboardData(const char* data);

  // Fl_Widget callback methods

  void draw() override;

  void resize(int x, int y, int w, int h) override;

  int handle(int event) override;

protected:
  void sendPointerEvent(const core::Point& pos,
                        uint16_t buttonMask) override;

private:
  void renderDesktop(Surface* destination, int originBX = 0, int originBY = 0);
  void drawSoftwareCursor(Surface* destination, int originBX, int originBY);
  void damageSoftwareCursor();
  bool hasFocus();
  Viewport* pointerTarget(int* x, int* y);

  // Show the currently set (or system) cursor
  void showCursor();

  static void handleClipboardChange(int source, void *data);

  void flushPendingClipboard();

  void handlePointerEvent(const core::Point& pos, uint16_t buttonMask);
  static void handlePointerTimeout(void *data);
  static void handleFocusChange(void* data);

  void resetKeyboard();

  void handleKeyPress(int systemKeyCode,
                      uint32_t keyCode, uint32_t keySym) override;
  void sendKeyPress(int systemKeyCode,
                    uint32_t keyCode, uint32_t keySym);
  void handleKeyRelease(int systemKeyCode) override;
  void sendKeyRelease(int systemKeyCode);

  static int handleSystemEvent(void *event, void *data);

  void pushLEDState();

  void initContextMenu();
  void popupContextMenu();

  static void handleOptions(void *data);

private:
  CConn* cc;
  std::shared_ptr<DesktopSession> session;
  Viewport* inputOwner;
  Viewport* activePointerView = nullptr;
  bool sessionHadFocus = false;

  PlatformPixelBuffer* frameBuffer;
  PlatformPixelBuffer* renderTile;
  core::Rect deferredDamage;
  DesktopTileCache tileCache;
  int availableWidth, availableHeight;
  double originX = 0, originY = 0;
  int canvasWidth = 0, canvasHeight = 0;
  core::Rect canvasRegion;
  double canvasPanX = 0, canvasPanY = 0;
  mutable bool scalingLimitReported = false;
  mutable DisplayMetrics previousMetrics;
  mutable unsigned long displayGeneration = 0;

  core::Point lastPointerPos;
  uint16_t lastButtonMask;

  Keyboard* keyboard;
  ShortcutHandler shortcutHandler;
  bool shortcutBypass;
  bool shortcutActive;
  std::set<int> pressedKeys;

  bool firstLEDState;

  bool pendingClientClipboard;

  int clipboardSource;

  Fl_Menu_Button *contextMenu;

  bool menuCtrlKey;
  bool menuAltKey;

  Fl_RGB_Image *cursor;
  CursorRenderer* softwareCursor = nullptr;
  core::Point softwareHotspot;
  core::Point logicalPointer;
  double cursorScaleX = 0, cursorScaleY = 0;
  double cursorDpiX = 0, cursorDpiY = 0;
  core::Point cursorHotspot;
  bool cursorIsBlank;
};

#endif
