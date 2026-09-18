/* Copyright (C) 2002-2005 RealVNC Ltd.  All Rights Reserved.
 * Copyright 2011-2025 Pierre Ossman for Cendio AB
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

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include <stdexcept>

#include <core/LogWriter.h>
#include <core/i18n.h>
#include <core/string.h>

#include <rfb/CMsgWriter.h>
#include <rfb/Cursor.h>
#include <rfb/KeysymStr.h>
#include <rfb/ledStates.h>

// FLTK can pull in the X11 headers on some systems
#ifndef XK_VoidSymbol
#define XK_LATIN1
#define XK_MISCELLANY
#include <rfb/keysymdef.h>
#endif

#ifndef NoSymbol
#define NoSymbol 0
#endif

#include "fltk/layout.h"
#include "fltk/util.h"
#include "Viewport.h"
#include "DisplayMetrics.h"
#include "DesktopResampler.h"
#include "CursorRenderer.h"
#include <cmath>
#include <vector>
#include <memory>
#include "CConn.h"
#include "OptionsDialog.h"
#include "DesktopWindow.h"
#include "DesktopSession.h"
#include "parameters.h"
#include "vncviewer.h"

#include "PlatformPixelBuffer.h"

#include <FL/fl_draw.H>
#include <FL/fl_ask.H>

#include <FL/Fl_Menu.H>
#include <FL/Fl_Menu_Button.H>
#include <FL/x.H>

#if defined(WIN32)
#include "KeyboardWin32.h"
#elif defined(__APPLE__)
#include "KeyboardMacOS.h"
#else
#include "KeyboardX11.h"
#endif

#ifdef __APPLE__
#include "cocoa.h"
#endif

static core::LogWriter vlog("Viewport");

// Menu constants

enum { ID_DISCONNECT, ID_FULLSCREEN, ID_MINIMIZE, ID_RESIZE,
       ID_CTRL, ID_ALT, ID_CTRLALTDEL,
       ID_REFRESH, ID_OPTIONS, ID_INFO, ID_ABOUT };

// Used for fake key presses from the menu
static const int FAKE_CTRL_KEY_CODE = 0x10001;
static const int FAKE_ALT_KEY_CODE = 0x10002;
static const int FAKE_DEL_KEY_CODE = 0x10003;

// Used for fake key presses for lock key sync
static const int FAKE_KEY_CODE = 0xffff;

Viewport::Viewport(int w, int h, CConn* cc_, std::shared_ptr<DesktopSession> sharedSession)
  : Fl_Widget(0, 0, w, h), cc(cc_), session(sharedSession), frameBuffer(nullptr), renderTile(nullptr),
    availableWidth(w), availableHeight(h),
    lastPointerPos(0, 0), lastButtonMask(0),
    keyboard(nullptr), shortcutBypass(false), shortcutActive(false),
    firstLEDState(true), pendingClientClipboard(false),
    menuCtrlKey(false), menuAltKey(false), cursor(nullptr),
    cursorIsBlank(false)
{
  if(!session) session=std::make_shared<DesktopSession>(cc,w,h);
  session->attach(this);
  inputOwner=session->inputOwner();
  frameBuffer=session->buffer();
  if(inputOwner!=this) {
    setCursor();
    return;
  }
#if defined(WIN32)
  keyboard = new KeyboardWin32(this);
#elif defined(__APPLE__)
  keyboard = new KeyboardMacOS(this);
#else
  keyboard = new KeyboardX11(this);
#endif

  Fl::add_clipboard_notify(handleClipboardChange, this);

  // We need to intercept keyboard events early
  Fl::add_system_handler(handleSystemEvent, this);

  // FIXME: We should only disable this whilst we have keyboard focus,
  //        but we also need to keep it disabled when we lose focus to
  //        any layout selector so it can properly filter out the
  //        layouts we don't support
  Fl::disable_im();


  contextMenu = new Fl_Menu_Button(0, 0, 0, 0);
  // Setting box type to FL_NO_BOX prevents it from trying to draw the
  // button component (which we don't want)
  contextMenu->box(FL_NO_BOX);

  // The (invisible) button associated with this widget can mess with
  // things like Fl_Scroll so we need to get rid of any parents.
  // Unfortunately that's not possible because of STR #2654, but
  // reparenting to the current window works for most cases.
  window()->add(contextMenu);

  unsigned modifierMask = 0;
  for (core::EnumListEntry key : shortcutModifiers)
    modifierMask |= ShortcutHandler::parseModifier(key.getValueStr().c_str());

  shortcutHandler.setModifiers(modifierMask);

  OptionsDialog::addCallback(handleOptions, this);

  // Make sure we have an initial blank cursor set
  setCursor();
}


Viewport::~Viewport()
{
  // Unregister all timeouts in case they get a change tro trigger
  // again later when this object is already gone.
  Fl::remove_timeout(handlePointerTimeout, this);

  Fl::remove_timeout(handleFocusChange,this);
  if(inputOwner->activePointerView==this) inputOwner->activePointerView=nullptr;
  session->detach(this);
  if(inputOwner==this) {
    Fl::remove_system_handler(handleSystemEvent);
    Fl::remove_clipboard_notify(handleClipboardChange);
    OptionsDialog::removeCallback(handleOptions);
    Fl::enable_im();
  }

  if (cursor) {
    if (!cursor->alloc_array)
      delete [] cursor->array;
    delete cursor;
  }

  delete softwareCursor;
  delete renderTile;
  delete keyboard;

  // FLTK automatically deletes all child widgets, so we shouldn't touch
  // them ourselves here
}


const rfb::PixelFormat &Viewport::getPreferredPF()
{
  return frameBuffer->getPF();
}


// Copy the areas of the framebuffer that have been changed (damaged)
// to the displayed window.

void Viewport::updateWindow() { session->update(); }

void Viewport::sourceDamaged(const core::Rect& damage)
{
  tileCache.invalidate(damage);
  deferredDamage=deferredDamage.union_boundary(damage);
}

void Viewport::flushSourceDamage()
{
  ScalingSettings::Quality quality = scalingQuality == "Nearest" ? ScalingSettings::Nearest :
    scalingQuality == "Area" ? ScalingSettings::Area : ScalingSettings::Bilinear;
  core::Rect r=transform().logicalDamage(deferredDamage,quality);
  deferredDamage={};
  if(!r.is_empty()) damage(FL_DAMAGE_USER1,r.tl.x,r.tl.y,r.width(),r.height());
}

static const char * dotcursor_xpm[] = {
  "5 5 2 1",
  ".	c #000000",
  " 	c #FFFFFF",
  "     ",
  " ... ",
  " ... ",
  " ... ",
  "     "};

void Viewport::setCursor()
{
  int width, height;
  core::Point hotspot;
  const uint8_t* data;

  int i;

  if (cursor) {
    if (!cursor->alloc_array)
      delete [] cursor->array;
    delete cursor;
  }

  width = cc->server.cursor().width();
  height = cc->server.cursor().height();
  hotspot = cc->server.cursor().hotspot();
  data = cc->server.cursor().getBuffer();

  for (i = 0; i < width*height; i++)
    if (data[i*4 + 3] != 0) break;

  cursorIsBlank = i == width*height;

  if (cursorIsBlank && alwaysCursor) {
    // This is the default in case the local cursor should be displayed yet cursorType is invalid.
    // Since the cursor variable isn't used if the cursorType is system, we can do this without checking the current
    // type which helps handle changing the type while the viewer is running.
    vlog.debug("Cursor is empty, using dot");

    Fl_Pixmap pxm(dotcursor_xpm);
    cursor = new Fl_RGB_Image(&pxm);
    cursorHotspot.x = cursorHotspot.y = 2;
  } else {
    if ((width == 0) || (height == 0)) {
      uint8_t *buffer = new uint8_t[4];
      memset(buffer, 0, 4);
      cursor = new Fl_RGB_Image(buffer, 1, 1, 4);
      cursorHotspot.x = cursorHotspot.y = 0;
    } else {
      uint8_t *buffer = new uint8_t[width * height * 4];
      memcpy(buffer, data, width * height * 4);
      cursor = new Fl_RGB_Image(buffer, width, height, 4);
      cursorHotspot = hotspot;
    }
  }

  damageSoftwareCursor();
  delete softwareCursor; softwareCursor = nullptr;
  DesktopTransform t = transform();
  cursorScaleX = double(t.backingWidth)/remoteWidth();
  cursorScaleY = double(t.backingHeight)/remoteHeight();
  cursorDpiX = t.metrics.pixelsPerUnitX; cursorDpiY = t.metrics.pixelsPerUnitY;
  if (!cursorIsBlank && width > 0 && height > 0 && !t.empty() &&
      (cursorScaleX != 1 || cursorScaleY != 1 || cursorDpiX != 1 || cursorDpiY != 1 || width > 128 || height > 128)) {
    ScalingSettings::Quality quality = scalingQuality == "Nearest" ? ScalingSettings::Nearest :
      scalingQuality == "Area" ? ScalingSettings::Area : ScalingSettings::Bilinear;
    softwareCursor = new CursorRenderer(data,width,height,hotspot,cursorScaleX,cursorScaleY,quality);
    softwareHotspot = softwareCursor->hotspot();
  }
  damageSoftwareCursor();

  if (Fl::belowmouse() == this)
    showCursor();
}

void Viewport::showCursor()
{
  if (viewOnly) {
    window()->cursor(FL_CURSOR_DEFAULT);
    return;
  }

  if (softwareCursor) {
    window()->cursor(FL_CURSOR_NONE);
    return;
  }
  if (cursorIsBlank && alwaysCursor && (cursorType == "system")) {
    window()->cursor(FL_CURSOR_DEFAULT);
  } else {
    window()->cursor(cursor, cursorHotspot.x, cursorHotspot.y);
  }
}

void Viewport::handleClipboardRequest()
{
  if (viewOnly)
    return;

  Fl::paste(*this, clipboardSource);
}

void Viewport::handleClipboardAnnounce(bool available)
{
  if (viewOnly)
    return;

  if (!acceptClipboard)
    return;

  if (!available) {
    vlog.debug("Clipboard is no longer available on server");
    return;
  }

  if (!hasFocus()) {
    vlog.debug("Got notification of new clipboard on server whilst not focused, ignoring");
    return;
  }

  pendingClientClipboard = false;

  vlog.debug("Got notification of new clipboard on server, requesting data");
  cc->requestClipboard();
}

void Viewport::handleClipboardData(const char* data)
{
  size_t len;

  if (!hasFocus())
    return;

  len = strlen(data);

  vlog.debug("Got clipboard data (%d bytes)", (int)len);

  // RFB doesn't have separate selection and clipboard concepts, so we
  // dump the data into both variants.
#if !defined(WIN32) && !defined(__APPLE__)
  if (setPrimary)
    Fl::copy(data, len, 0);
#endif
  Fl::copy(data, len, 1);
}

void Viewport::setLEDState(unsigned int ledState)
{
  vlog.debug("Got server LED state: 0x%08x", ledState);

  // The first message is just considered to be the server announcing
  // support for this extension. We will push our state to sync up the
  // server when we get focus. If we already have focus we need to push
  // it here though.
  if (firstLEDState) {
    firstLEDState = false;
    if (hasFocus())
      pushLEDState();
    return;
  }

  if (viewOnly)
    return;

  if (!hasFocus())
    return;

  keyboard->setLEDState(ledState);
}

void Viewport::pushLEDState()
{
  unsigned int ledState;

  if (viewOnly)
    return;

  // Server support?
  if (cc->server.ledState() == rfb::ledUnknown)
    return;

  ledState = keyboard->getLEDState();
  if (ledState == rfb::ledUnknown)
    return;

#if defined(__APPLE__)
  // No support for Scroll Lock //
  ledState |= (cc->server.ledState() & rfb::ledScrollLock);
#endif

  if ((ledState & rfb::ledCapsLock) !=
      (cc->server.ledState() & rfb::ledCapsLock)) {
    vlog.debug("Inserting fake CapsLock to get in sync with server");
    sendKeyPress(FAKE_KEY_CODE, 0x3a, XK_Caps_Lock);
    sendKeyRelease(FAKE_KEY_CODE);
  }
  if ((ledState & rfb::ledNumLock) !=
      (cc->server.ledState() & rfb::ledNumLock)) {
    vlog.debug("Inserting fake NumLock to get in sync with server");
    sendKeyPress(FAKE_KEY_CODE, 0x45, XK_Num_Lock);
    sendKeyRelease(FAKE_KEY_CODE);
  }
  if ((ledState & rfb::ledScrollLock) !=
      (cc->server.ledState() & rfb::ledScrollLock)) {
    vlog.debug("Inserting fake ScrollLock to get in sync with server");
    sendKeyPress(FAKE_KEY_CODE, 0x46, XK_Scroll_Lock);
    sendKeyRelease(FAKE_KEY_CODE);
  }
}


DesktopTransform Viewport::transform() const
{
  DisplayMetrics metrics = displayMetrics(window());
  if(!displayGeneration || metrics.screen != previousMetrics.screen ||
      metrics.pixelsPerUnitX != previousMetrics.pixelsPerUnitX ||
      metrics.pixelsPerUnitY != previousMetrics.pixelsPerUnitY) {
    ++displayGeneration;
    previousMetrics=metrics;
  }
  metrics.generation=displayGeneration;
  const bool device=desktopPixelUnits=="Device" && (!canvasWidth || !scalingFactor.settings().fits());
  const double unitX=device?metrics.pixelsPerUnitX:1;
  const double unitY=device?metrics.pixelsPerUnitY:1;
  double aw=canvasWidth?canvasWidth/unitX:availableWidth;
  double ah=canvasHeight?canvasHeight/unitY:availableHeight;
  ScalingSettings effective=scalingFactor.settings();
  ScalingSettings::Units units=device?ScalingSettings::Device:ScalingSettings::Logical;
  DesktopTransform result(remoteWidth(),remoteHeight(),aw,ah,metrics,{},ScalingSettings::Device);
  try {
    result=DesktopTransform(remoteWidth(),remoteHeight(),aw,ah,metrics,effective,units,originX,originY);
    scalingLimitReported=false;
  } catch(const std::overflow_error&) {
    if(!scalingLimitReported) {
      vlog.error(_("Scaled desktop exceeds the dimension limit; temporarily using 100%% Device"));
      scalingLimitReported=true;
    }
    effective={}; units=ScalingSettings::Device;
    result=DesktopTransform(remoteWidth(),remoteHeight(),aw,ah,metrics,effective,units,originX,originY);
  }
  if(canvasWidth) result.placeOnCanvas(canvasWidth,canvasHeight,canvasRegion,
    device?ScalingSettings::Device:ScalingSettings::Logical,canvasPanX,canvasPanY);
  return result;
}
int Viewport::remoteWidth() const { return frameBuffer->width(); }
int Viewport::remoteHeight() const { return frameBuffer->height(); }

void Viewport::setCanvas(int width,int height,const core::Rect& region,double panX,double panY)
{
  canvasWidth=width; canvasHeight=height; canvasRegion=region;
  canvasPanX=panX; canvasPanY=panY;
  configureDisplay(window()->w(),window()->h());
}
void Viewport::clearCanvas()
{
  canvasWidth=canvasHeight=0;
  originX=originY=0;
  configureDisplay(window()->w(),window()->h());
}

void Viewport::configureDisplay(int width, int height)
{
  availableWidth = width; availableHeight = height;
  DesktopTransform t = transform();
  setDisplayOrigin(originX,originY);
  if(cursor && (cursorScaleX != double(t.backingWidth)/remoteWidth() ||
                cursorScaleY != double(t.backingHeight)/remoteHeight() ||
                cursorDpiX != t.metrics.pixelsPerUnitX || cursorDpiY != t.metrics.pixelsPerUnitY))
    setCursor();
}

void Viewport::draw(Surface* dst, int bx, int by)
{
  renderDesktop(dst, bx, by);
  drawSoftwareCursor(dst,bx,by);
}
void Viewport::draw()
{
  renderDesktop(nullptr);
  drawSoftwareCursor(nullptr,0,0);
}

void Viewport::renderDesktop(Surface* dst, int targetBX, int targetBY)
{
  DesktopTransform t = transform();
  if (t.empty()) return;
  int X, Y, W, H;
  fl_clip_box(x(), y(), w(), h(), X, Y, W, H);
  if (W <= 0 || H <= 0) return;
  const double qx = t.metrics.pixelsPerUnitX, qy = t.metrics.pixelsPerUnitY;
  core::Rect clip(std::max(t.originBX, int(std::floor(X*qx))),
                  std::max(t.originBY, int(std::floor(Y*qy))),
                  std::min(t.originBX+t.backingWidth, int(std::ceil((X+W)*qx))),
                  std::min(t.originBY+t.backingHeight, int(std::ceil((Y+H)*qy))));
  if (dst) clip = clip.intersect({targetBX, targetBY,
                                 targetBX+dst->width(), targetBY+dst->height()});
  if (clip.is_empty()) return;
  // Exposes and local scale changes may happen while decoders are active.
  session->synchronize();
  if (t.identity()) {
    if (dst) frameBuffer->draw(dst, clip.tl.x-t.originBX, clip.tl.y-t.originBY,
      clip.tl.x-targetBX, clip.tl.y-targetBY, clip.width(), clip.height());
    else frameBuffer->drawBacking(clip.tl.x-t.originBX, clip.tl.y-t.originBY,
      clip.tl.x, clip.tl.y, clip.width(), clip.height(), qx, qy);
    return;
  }
  if (!renderTile) renderTile = new PlatformPixelBuffer(256,256);
  int stride;
  const uint8_t* source = frameBuffer->getBuffer(frameBuffer->getRect(), &stride);
  ScalingSettings::Quality quality = scalingQuality == "Nearest" ? ScalingSettings::Nearest :
    scalingQuality == "Area" ? ScalingSettings::Area : ScalingSettings::Bilinear;
  tileCache.configure(remoteWidth(),remoteHeight(),t.backingWidth,t.backingHeight,
                      quality,t.metrics.generation);
  int startX=(clip.tl.x-t.originBX)/256*256;
  int startY=(clip.tl.y-t.originBY)/256*256;
  for (int ty=startY;ty<clip.br.y-t.originBY;ty+=256) {
    for (int tx=startX;tx<clip.br.x-t.originBX;tx+=256) {
      int tw=std::min(256,t.backingWidth-tx), th=std::min(256,t.backingHeight-ty), ts;
      core::Rect tile(0,0,tw,th);
      uint8_t* out=renderTile->getBufferRW(tile,&ts);
      tileCache.render(source,size_t(stride)*4,out,size_t(ts)*4,{tx,ty,tx+tw,ty+th});
      renderTile->commitBufferRW(tile);
      renderTile->getDamage();
      int bx=tx+t.originBX, by=ty+t.originBY;
      core::Rect visible=core::Rect(bx,by,bx+tw,by+th).intersect(clip);
      if(dst) renderTile->draw(dst,visible.tl.x-bx,visible.tl.y-by,
        visible.tl.x-targetBX,visible.tl.y-targetBY,visible.width(),visible.height());
      else renderTile->drawBacking(visible.tl.x-bx,visible.tl.y-by,
        visible.tl.x,visible.tl.y,visible.width(),visible.height(),qx,qy);
    }
  }
}

void Viewport::resizeFramebuffer(int width,int height) { session->resize(width,height); }

void Viewport::sourceReplaced()
{
  frameBuffer=session->buffer();
  lastPointerPos.x=std::max(0,std::min(remoteWidth()-1,lastPointerPos.x));
  lastPointerPos.y=std::max(0,std::min(remoteHeight()-1,lastPointerPos.y));
  deferredDamage={};
  tileCache.clear();
  configureDisplay(availableWidth,availableHeight);
  // A smaller source also exposes old image bounds outside the new widget.
  window()->redraw();
}

void Viewport::setDisplayOrigin(double x, double y)
{
  originX=x; originY=y;
  DesktopTransform t=transform();
  originX=t.originBX/t.metrics.pixelsPerUnitX;
  originY=t.originBY/t.metrics.pixelsPerUnitY;
  int left=int(std::floor(originX)), top=int(std::floor(originY));
  int width=int(std::ceil(originX+t.logicalWidth))-left;
  int height=int(std::ceil(originY+t.logicalHeight))-top;
  // The integer widget only encloses the image. Rendering and input use
  // the independently retained, backing-aligned fractional origin.
  if(left!=this->x() || top!=this->y() || width!=w() || height!=h()) {
    Fl_Widget::resize(left,top,width,height);
    redraw();
  }
}

void Viewport::resize(int x, int y, int w, int h)
{
  originX+=x-this->x(); originY+=y-this->y();
  Fl_Widget::resize(x,y,w,h);
}


Viewport* Viewport::pointerTarget(int* x,int* y)
{
  if(session->views().size()==1) return this;
  // During a held drag FLTK keeps sending events to the original widget.
  // Route through the view under the global pointer before converting to R.
  int rootX=Fl::event_x_root(), rootY=Fl::event_y_root();
  for(Viewport* view : session->views()) {
    Fl_Window* win=view->window();
    if(rootX>=win->x() && rootY>=win->y() && rootX<win->x()+win->w() && rootY<win->y()+win->h()) {
      *x=rootX-win->x(); *y=rootY-win->y(); return view;
    }
  }
  return this;
}

int Viewport::handle(int event)
{
  std::string filtered;
  int buttonMask, wheelMask;
  int pointerX=Fl::event_x(), pointerY=Fl::event_y();
  Viewport* pointerView=pointerTarget(&pointerX,&pointerY);

  if (event == FL_MOVE || event == FL_DRAG || event == FL_PUSH || event == FL_RELEASE ||
      event == FL_ENTER || event == FL_LEAVE || event == FL_MOUSEWHEEL) {
    Viewport* old=inputOwner->activePointerView;
    if(old) old->damageSoftwareCursor();
    inputOwner->activePointerView=event==FL_LEAVE && pointerView==this?nullptr:pointerView;
    pointerView->logicalPointer={pointerX,pointerY};
    if(inputOwner->activePointerView) {
      pointerView->damageSoftwareCursor();
      pointerView->showCursor();
    }
  }
  switch (event) {
  case FL_PASTE:
    if (!core::isValidUTF8(Fl::event_text(), Fl::event_length())) {
      vlog.error(_("Invalid UTF-8 sequence in clipboard"));
      // Reset the state as if we don't have any clipboard data at all
      this->pendingClientClipboard = false;
      try {
        this->cc->announceClipboard(false);
      } catch (std::exception& e) {
        vlog.error("%s", e.what());
        abort_connection_with_unexpected_error(e);
      }
      return 1;
    }

    filtered = core::convertLF(Fl::event_text(), Fl::event_length());

    vlog.debug("Sending clipboard data (%d bytes)", (int)filtered.size());

    try {
      cc->sendClipboardData(filtered.c_str());
    } catch (std::exception& e) {
      vlog.error("%s", e.what());
      abort_connection_with_unexpected_error(e);
    }

    return 1;

  case FL_ENTER:
    showCursor();
    // Yes, we would like some pointer events please!
    return 1;

  case FL_LEAVE:
    window()->cursor(FL_CURSOR_DEFAULT);
    // We want a last move event to help trigger edge stuff
    inputOwner->handlePointerEvent(pointerView->transform().remotePoint(pointerX,pointerY),
                                   inputOwner->lastButtonMask);
    return 1;

  case FL_PUSH:
  case FL_RELEASE:
  case FL_DRAG:
  case FL_MOVE:
  case FL_MOUSEWHEEL:
    buttonMask = 0;
    if (Fl::event_button1())
      buttonMask |= 1 << 0;
    if (Fl::event_button2())
      buttonMask |= 1 << 1;
    if (Fl::event_button3())
      buttonMask |= 1 << 2;

  // The back/forward buttons are not supported by FTLK 1.3 and require
  // a patch which adds these buttons to the FLTK API. These buttons
  // will be part of the upcoming 1.4 API:
  //   * https://github.com/fltk/fltk/pull/1081
  //
  // A backport for branch-1.3 is available here:
  //   * https://github.com/fltk/fltk/pull/1083
#if defined(FL_BUTTON4) && defined(FL_BUTTON5)
    if (Fl::event_button4())
      buttonMask |= 1 << 7;
    if (Fl::event_button5())
      buttonMask |= 1 << 8;
#endif

    if (event == FL_MOUSEWHEEL) {
      wheelMask = 0;
      if (Fl::event_dy() < 0)
        wheelMask |= 1 << 3;
      if (Fl::event_dy() > 0)
        wheelMask |= 1 << 4;
      if (Fl::event_dx() < 0)
        wheelMask |= 1 << 5;
      if (Fl::event_dx() > 0)
        wheelMask |= 1 << 6;

      // A quick press of the wheel "button", followed by a immediate
      // release below
      inputOwner->handlePointerEvent(pointerView->transform().remotePoint(pointerX,pointerY),
                         buttonMask | wheelMask);
    } 

    inputOwner->handlePointerEvent(pointerView->transform().remotePoint(pointerX,pointerY), buttonMask);
    return 1;

  case FL_FOCUS:
  case FL_UNFOCUS:
    // Focus can briefly be null between native windows. Defer the decision
    // to release held keys until FLTK has completed the focus transfer.
    if(!Fl::has_timeout(handleFocusChange,inputOwner))
      Fl::add_timeout(0,handleFocusChange,inputOwner);
    return 1;

  case FL_KEYDOWN:
  case FL_KEYUP:
    // Just ignore these as keys were handled in the event handler
    return 1;
  }

  return Fl_Widget::handle(event);
}

void Viewport::sendPointerEvent(const core::Point& position,
                                uint16_t buttonMask)
{
  core::Point pos(std::max(0,std::min(remoteWidth()-1,position.x)),
                  std::max(0,std::min(remoteHeight()-1,position.y)));
  if (viewOnly)
      return;

  if ((pointerEventInterval == 0) || (buttonMask != lastButtonMask)) {
    try {
      cc->writer()->writePointerEvent(pos, buttonMask);
    } catch (std::exception& e) {
      vlog.error("%s", e.what());
      abort_connection_with_unexpected_error(e);
    }
  } else {
    if (!Fl::has_timeout(handlePointerTimeout, this))
      Fl::add_timeout((double)pointerEventInterval/1000.0,
                      handlePointerTimeout, this);
  }
  lastPointerPos = pos;
  lastButtonMask = buttonMask;
}

bool Viewport::sessionFocused()
{
  Fl_Widget* focus=Fl::grab();
  if(!focus) focus=Fl::focus();
  Viewport* view=dynamic_cast<Viewport*>(focus);
  return view && view->session==session;
}

bool Viewport::hasFocus() { return sessionFocused(); }

void Viewport::handleFocusChange(void* data)
{
  Viewport* self=static_cast<Viewport*>(data);
  bool focused=self->hasFocus();
  if(focused==self->sessionHadFocus) return;
  self->sessionHadFocus=focused;
  if(!focused) { self->resetKeyboard(); return; }
  self->flushPendingClipboard();
  self->pushLEDState();
  if(self->menuCtrlKey) self->sendKeyPress(FAKE_CTRL_KEY_CODE,0x1d,XK_Control_L);
  if(self->menuAltKey) self->sendKeyPress(FAKE_ALT_KEY_CODE,0x38,XK_Alt_L);
}

void Viewport::handleClipboardChange(int source, void *data)
{
  Viewport *self = (Viewport *)data;

  assert(self);

  if (viewOnly)
    return;

  if (!sendClipboard)
    return;

#if !defined(WIN32) && !defined(__APPLE__)
  if (!sendPrimary && (source == 0))
    return;
#endif

  if (!self->hasFocus()) {
    vlog.debug("Local clipboard changed whilst not focused, will notify server later");
    self->clipboardSource = source;
    self->pendingClientClipboard = true;
    // Clear any older client clipboard from the server
    try {
      self->cc->announceClipboard(false);
    } catch (std::exception& e) {
      vlog.error("%s", e.what());
      abort_connection_with_unexpected_error(e);
    }
    return;
  }

  if (source != 0 &&
      !Fl::clipboard_contains(Fl::clipboard_plain_text)) {
    vlog.debug("Got non-plain text in local clipboard, ignoring.");
    // Reset the state as if we don't have any clipboard data at all
    self->pendingClientClipboard = false;
    try {
      self->cc->announceClipboard(false);
    } catch (std::exception& e) {
      vlog.error("%s", e.what());
      abort_connection_with_unexpected_error(e);
    }
    return;
  }

  self->clipboardSource = source;

  vlog.debug("Local clipboard changed, notifying server");
  try {
    self->cc->announceClipboard(true);
  } catch (std::exception& e) {
    vlog.error("%s", e.what());
    abort_connection_with_unexpected_error(e);
  }
}


void Viewport::flushPendingClipboard()
{
  if (pendingClientClipboard) {
    if (clipboardSource != 0 &&
        !Fl::clipboard_contains(Fl::clipboard_plain_text)) {
      vlog.debug("Pending local clipboard has no plain text, ignoring.");
      pendingClientClipboard = false;
      return;
    }

    vlog.debug("Focus regained after local clipboard change, notifying server");
    try {
      cc->announceClipboard(true);
    } catch (std::exception& e) {
      vlog.error("%s", e.what());
      abort_connection_with_unexpected_error(e);
    }
  }

  pendingClientClipboard = false;
}


void Viewport::handlePointerEvent(const core::Point& pos,
                                  uint16_t buttonMask)
{
  filterPointerEvent(pos, buttonMask);
}


void Viewport::handlePointerTimeout(void *data)
{
  Viewport *self = (Viewport *)data;

  assert(self);

  try {
    self->cc->writer()->writePointerEvent(self->lastPointerPos,
                                          self->lastButtonMask);
  } catch (std::exception& e) {
    vlog.error("%s", e.what());
    abort_connection_with_unexpected_error(e);
  }
}


void Viewport::resetKeyboard()
{
  try {
    cc->releaseAllKeys();
  } catch (std::exception& e) {
    vlog.error("%s", e.what());
    abort_connection_with_unexpected_error(e);
  }

  keyboard->reset();

  shortcutHandler.reset();
  shortcutBypass = false;
  shortcutActive = false;
  pressedKeys.clear();
}


void Viewport::handleKeyPress(int systemKeyCode,
                              uint32_t keyCode, uint32_t keySym)
{
  pressedKeys.insert(systemKeyCode);

  // Possible keyboard shortcut?

  if (!shortcutBypass) {
    ShortcutHandler::KeyAction action;

    action = shortcutHandler.handleKeyPress(systemKeyCode, keySym);

    if (action == ShortcutHandler::KeyIgnore) {
      vlog.debug("Ignoring key press %d => 0x%02x / XK_%s (0x%04x)",
                 systemKeyCode, keyCode, KeySymName(keySym), keySym);
      return;
    }

    if (action == ShortcutHandler::KeyShortcut) {
      std::list<uint32_t> keySyms;
      std::list<uint32_t>::const_iterator iter;

      // Modifiers can change the KeySym that's been resolved, so we
      // need to check all possible KeySyms for this physical key, not
      // just the current one
      keySyms = keyboard->translateToKeySyms(systemKeyCode);

      // Then we pick the one that matches first
      keySym = NoSymbol;
      for (iter = keySyms.begin(); iter != keySyms.end(); iter++) {
        bool found;

        switch (*iter) {
        case XK_space:
        case XK_G:
        case XK_g:
        case XK_M:
        case XK_m:
        case XK_KP_Enter:
        case XK_Return:
          keySym = *iter;
          found = true;
          break;
        default:
          found = false;
          break;
        }

        if (found)
          break;
      }

      if (keySym != NoSymbol) {
        vlog.debug("Detected shortcut %d => 0x%02x / XK_%s (0x%04x)",
                  systemKeyCode, keyCode, KeySymName(keySym), keySym);
      } else {
        std::string names;

        for (iter = keySyms.begin(); iter != keySyms.end(); iter++) {
          if (!names.empty())
            names += ", ";
          names += core::format("XK_%s (0x%04x)",
                                KeySymName(*iter), *iter);
        }

        vlog.debug("Detected unknown shortcut %d => 0x%02x / %s",
                   systemKeyCode, keyCode, names.c_str());
      }

      // Special case which we need to handle first
      if (keySym == XK_space) {
        // If another shortcut has already fired, then we're too late as
        // we've already released the modifier keys
        if (!shortcutActive) {
          shortcutBypass = true;
          shortcutHandler.reset();
        }
        return;
      }

      shortcutActive = true;

      // The remote session won't see any more keys, so release the ones
      // currently down
      try {
        cc->releaseAllKeys();
      } catch (std::exception& e) {
        vlog.error("%s", e.what());
        abort_connection(_("An unexpected error occurred when communicating "
                           "with the server:\n\n%s"), e.what());
      }

      switch (keySym) {
      case XK_G:
      case XK_g:
        ((DesktopWindow*)window())->grabKeyboard();
        break;
      case XK_M:
      case XK_m:
        popupContextMenu();
        break;
      case XK_KP_Enter:
      case XK_Return:
        if (window()->fullscreen_active()) {
          fullScreen.setParam(false);
          window()->fullscreen_off();
        } else {
          fullScreen.setParam(true);
          ((DesktopWindow*)window())->fullscreen_on();
        }
        break;
      default:
        // Unknown/Unused keyboard shortcut
        break;
      }

      return;
    }
  }

  // Normal key, so send to server...

  sendKeyPress(systemKeyCode, keyCode, keySym);
}

void Viewport::sendKeyPress(int systemKeyCode,
                            uint32_t keyCode, uint32_t keySym)
{
  if (viewOnly)
    return;

  try {
    cc->sendKeyPress(systemKeyCode, keyCode, keySym);
  } catch (std::exception& e) {
    vlog.error("%s", e.what());
    abort_connection_with_unexpected_error(e);
  }
}


void Viewport::handleKeyRelease(int systemKeyCode)
{
  pressedKeys.erase(systemKeyCode);

  if (pressedKeys.empty())
    shortcutActive = false;

  // Possible keyboard shortcut?

  if (!shortcutBypass) {
    ShortcutHandler::KeyAction action;

    action = shortcutHandler.handleKeyRelease(systemKeyCode);

    if (action == ShortcutHandler::KeyIgnore) {
      vlog.debug("Ignoring key release %d", systemKeyCode);
      return;
    }

    if (action == ShortcutHandler::KeyShortcut) {
      vlog.debug("Shortcut release %d", systemKeyCode);
      return;
    }

    if (action == ShortcutHandler::KeyUnarm) {
      DesktopWindow *win;

      vlog.debug("Detected shortcut to release grab");

      try {
        cc->releaseAllKeys();
      } catch (std::exception& e) {
        vlog.error("%s", e.what());
        abort_connection(_("An unexpected error occurred when communicating "
                           "with the server:\n\n%s"), e.what());
      }

      win = dynamic_cast<DesktopWindow*>(window());
      assert(win);
      win->ungrabKeyboard();

      return;
    }
  }

  if (pressedKeys.empty())
    shortcutBypass = false;

  // Normal key, so send to server...

  sendKeyRelease(systemKeyCode);
}

void Viewport::sendKeyRelease(int systemKeyCode)
{
  if (viewOnly)
    return;

  try {
    cc->sendKeyRelease(systemKeyCode);
  } catch (std::exception& e) {
    vlog.error("%s", e.what());
    abort_connection_with_unexpected_error(e);
  }
}


int Viewport::handleSystemEvent(void *event, void *data)
{
  Viewport *self = (Viewport *)data;
  bool consumed;

  assert(self);

  if (!self->hasFocus())
    return 0;

  // Special event that means we temporarily lost some input
  if (self->keyboard->isKeyboardReset(event)) {
    self->resetKeyboard();
    return 1;
  }

  consumed = self->keyboard->handleEvent(event);
  if (consumed)
    return 1;

  return 0;
}

// FIXME: gcc confuses ID_DISCONNECT with NULL
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wzero-as-null-pointer-constant"
void Viewport::initContextMenu()
{
  contextMenu->clear();

  fltk_menu_add(contextMenu, C_("ContextMenu|", "Disconn&ect"),
                0, nullptr, (void*)ID_DISCONNECT, FL_MENU_DIVIDER);

  fltk_menu_add(contextMenu, C_("ContextMenu|", "&Full screen"),
                0, nullptr, (void*)ID_FULLSCREEN,
                FL_MENU_TOGGLE | (window()->fullscreen_active()?FL_MENU_VALUE:0));
  fltk_menu_add(contextMenu, C_("ContextMenu|", "Minimi&ze"),
                0, nullptr, (void*)ID_MINIMIZE, 0);
  fltk_menu_add(contextMenu, C_("ContextMenu|", "Resize &window to session"),
                0, nullptr, (void*)ID_RESIZE,
                (window()->fullscreen_active()?FL_MENU_INACTIVE:0) |
                FL_MENU_DIVIDER);

  fltk_menu_add(contextMenu, C_("ContextMenu|", "&Ctrl"),
                0, nullptr, (void*)ID_CTRL,
                FL_MENU_TOGGLE | (menuCtrlKey?FL_MENU_VALUE:0));
  fltk_menu_add(contextMenu, C_("ContextMenu|", "&Alt"),
                0, nullptr, (void*)ID_ALT,
                FL_MENU_TOGGLE | (menuAltKey?FL_MENU_VALUE:0));

  fltk_menu_add(contextMenu, C_("ContextMenu|", "Send Ctrl-Alt-&Del"),
                0, nullptr, (void*)ID_CTRLALTDEL, FL_MENU_DIVIDER);

  fltk_menu_add(contextMenu, C_("ContextMenu|", "&Refresh screen"),
                0, nullptr, (void*)ID_REFRESH, FL_MENU_DIVIDER);

  fltk_menu_add(contextMenu, C_("ContextMenu|", "&Options..."),
                0, nullptr, (void*)ID_OPTIONS, 0);
  fltk_menu_add(contextMenu, C_("ContextMenu|", "Connection &info..."),
                0, nullptr, (void*)ID_INFO, 0);
  fltk_menu_add(contextMenu, C_("ContextMenu|", "About &TigerVNC..."),
                0, nullptr, (void*)ID_ABOUT, 0);
}
#pragma GCC diagnostic pop

void Viewport::popupContextMenu()
{
  const Fl_Menu_Item *m;

  // Make sure the menu is reset to its initial state between goes or
  // it will start up highlighting the previously selected entry.
  contextMenu->value(-1);

  // initialize context menu before display
  initContextMenu();

  // Unfortunately FLTK doesn't reliably restore the mouse pointer for
  // menus, so we have to help it out.
  if (Fl::belowmouse() == this)
    window()->cursor(FL_CURSOR_DEFAULT);

  // FLTK also doesn't switch focus properly for menus
  Fl::handle(FL_UNFOCUS, window());

  m = contextMenu->popup();

  Fl::handle(FL_FOCUS, window());

  // Back to our proper mouse pointer.
  if (Fl::belowmouse() == this)
    showCursor();

  if (m == nullptr)
    return;

  switch (m->argument()) {
  case ID_DISCONNECT:
    disconnect();
    break;
  case ID_FULLSCREEN:
    if (window()->fullscreen_active())
      window()->fullscreen_off();
    else
      ((DesktopWindow*)window())->fullscreen_on();
    break;
  case ID_MINIMIZE:
#ifdef __APPLE__
    // FIXME: Workaround for not being able to minimize in fullscreen
    // https://github.com/TigerVNC/tigervnc/pull/1813
    if (window()->fullscreen_active())
      cocoa_enable_minimize(window());
#endif
    window()->iconize();
    break;
  case ID_RESIZE:
    if (window()->fullscreen_active())
      break;
    window()->size(w(), h());
    break;
  case ID_CTRL:
    if (m->value())
      sendKeyPress(FAKE_CTRL_KEY_CODE, 0x1d, XK_Control_L);
    else
      sendKeyRelease(FAKE_CTRL_KEY_CODE);
    menuCtrlKey = !menuCtrlKey;
    break;
  case ID_ALT:
    if (m->value())
      sendKeyPress(FAKE_ALT_KEY_CODE, 0x38, XK_Alt_L);
    else
      sendKeyRelease(FAKE_ALT_KEY_CODE);
    menuAltKey = !menuAltKey;
    break;
  case ID_CTRLALTDEL:
    sendKeyPress(FAKE_CTRL_KEY_CODE, 0x1d, XK_Control_L);
    sendKeyPress(FAKE_ALT_KEY_CODE, 0x38, XK_Alt_L);
    sendKeyPress(FAKE_DEL_KEY_CODE, 0xd3, XK_Delete);

    sendKeyRelease(FAKE_DEL_KEY_CODE);
    sendKeyRelease(FAKE_ALT_KEY_CODE);
    sendKeyRelease(FAKE_CTRL_KEY_CODE);
    break;
  case ID_REFRESH:
    cc->refreshFramebuffer();
    break;
  case ID_OPTIONS:
    OptionsDialog::showDialog();
    break;
  case ID_INFO:
    fl_message_title(_("VNC connection info"));
    fl_message("%s", fltk_escape(cc->connectionInfo().c_str()).c_str());
    break;
  case ID_ABOUT:
    about_vncviewer();
    break;
  }
}

void Viewport::handleOptions(void *data)
{
  Viewport *self = (Viewport*)data;
  unsigned modifierMask;

  modifierMask = 0;
  for (core::EnumListEntry key : shortcutModifiers)
    modifierMask |= ShortcutHandler::parseModifier(key.getValueStr().c_str());

  self->shortcutHandler.setModifiers(modifierMask);
  for(Viewport* view : self->session->views()) view->setCursor();

  if (Fl::belowmouse() == self)
    self->showCursor();
}

void Viewport::damageSoftwareCursor()
{
  if(!softwareCursor) return;
  DisplayMetrics m=displayMetrics(window());
  int x0=int(std::floor(logicalPointer.x-softwareHotspot.x/m.pixelsPerUnitX))-1;
  int y0=int(std::floor(logicalPointer.y-softwareHotspot.y/m.pixelsPerUnitY))-1;
  int cw=int(std::ceil(softwareCursor->width()/m.pixelsPerUnitX))+2;
  int ch=int(std::ceil(softwareCursor->height()/m.pixelsPerUnitY))+2;
  window()->damage(FL_DAMAGE_USER1,x0,y0,cw,ch);
}

void Viewport::drawSoftwareCursor(Surface* dst,int bx,int by)
{
  if(!softwareCursor || viewOnly || inputOwner->activePointerView!=this) return;
  DesktopTransform t=transform();
  const double qx=t.metrics.pixelsPerUnitX, qy=t.metrics.pixelsPerUnitY;
  int dx=int(std::floor(logicalPointer.x*qx+.5))-softwareHotspot.x;
  int dy=int(std::floor(logicalPointer.y*qy+.5))-softwareHotspot.y;
  core::Rect r(dx,dy,dx+softwareCursor->width(),dy+softwareCursor->height());
  int X,Y,W,H;
  fl_clip_box(0,0,window()->w(),window()->h(),X,Y,W,H);
  r=r.intersect({int(std::floor(X*qx)),int(std::floor(Y*qy)),
                 int(std::ceil((X+W)*qx)),int(std::ceil((Y+H)*qy))});
  if(dst) r=r.intersect({bx,by,bx+dst->width(),by+dst->height()});
  if(r.is_empty()) return;
  std::vector<uint8_t> pixels(256*256*4);
  for(int y=r.tl.y;y<r.br.y;y+=256) for(int x=r.tl.x;x<r.br.x;x+=256) {
    int w=std::min(256,r.br.x-x), h=std::min(256,r.br.y-y);
    softwareCursor->render(pixels.data(),size_t(w)*4,{x-dx,y-dy,x-dx+w,y-dy+h});
    Fl_RGB_Image image(pixels.data(),w,h,4);
    Surface tile(&image);
    if(dst) tile.blend(dst,0,0,x-bx,y-by,w,h);
    else {
      Surface background(w,h);
      background.clear(40,40,40);
      renderDesktop(&background,x,y);
      tile.blend(&background,0,0,0,0,w,h);
      background.drawBacking(0,0,x,y,w,h,qx,qy);
    }
  }
}
