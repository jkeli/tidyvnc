/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#include "DesktopView.h"
#include "DesktopWindow.h"
#include "Viewport.h"
#include "Surface.h"
#include "DisplayMetrics.h"
#include "cocoa.h"
#include <FL/fl_draw.H>
#include <algorithm>
#include <cmath>

DesktopView::DesktopView(DesktopWindow* owner_, CConn* cc,
    std::shared_ptr<DesktopSession> session,const DesktopRegion& region)
  : Fl_Window(region.monitor.logical.tl.x,region.monitor.logical.tl.y,
              region.monitor.logical.width(),region.monitor.logical.height()),
    owner(owner_),monitorId(region.monitor.id)
{
  copy_label(owner->label());
  viewport=new Viewport(w(),h(),cc,session);
  end();
  callback(closeView,this);
  fullscreen_screens(region.monitor.screen,region.monitor.screen,
                      region.monitor.screen,region.monitor.screen);
  fullscreen();
  show();
#ifdef __APPLE__
  cocoa_prevent_native_fullscreen(this);
  observer=cocoa_observe_display(this,displayChanged,this);
#endif
}
DesktopView::~DesktopView()
{
#ifdef __APPLE__
  cocoa_unobserve_display(observer);
#endif
  delete composition;
}
void DesktopView::displayChanged(void* data)
{
  DesktopView* self=static_cast<DesktopView*>(data);
  self->owner->displayConfigurationChanged();
  self->redraw();
}
void DesktopView::closeView(Fl_Widget*,void* data)
{
  // Leave fullscreen through the coordinator. Defer deletion until this
  // callback returns, retaining the connection and its input state.
  static_cast<DesktopView*>(data)->owner->leaveFullscreen();
}
int DesktopView::handle(int event)
{
  if(event==FL_FOCUS || event==FL_UNFOCUS) owner->viewFocusChanged();
  if(event==FL_MOVE || event==FL_DRAG || event==FL_ENTER || event==FL_LEAVE) owner->viewPointerMoved(this);
  return Fl_Window::handle(event);
}
void DesktopView::draw()
{
  viewport->configureDisplay(w(),h());
  DisplayMetrics m=displayMetrics(this);
  bool changed=!haveMetrics || m.screen!=lastMetrics.screen ||
    m.pixelsPerUnitX!=lastMetrics.pixelsPerUnitX || m.pixelsPerUnitY!=lastMetrics.pixelsPerUnitY;
  lastMetrics=m; haveMetrics=true;
  if(changed) fl_push_no_clip();
  int x,y,w,h;
  fl_clip_box(0,0,this->w(),this->h(),x,y,w,h);
  int left=int(std::floor(x*m.pixelsPerUnitX)), top=int(std::floor(y*m.pixelsPerUnitY));
  int right=int(std::ceil((x+w)*m.pixelsPerUnitX)), bottom=int(std::ceil((y+h)*m.pixelsPerUnitY));
  for(int by=top;by<bottom;by+=1024) for(int bx=left;bx<right;bx+=1024) {
    int width=std::min(1024,right-bx), height=std::min(1024,bottom-by);
    if(!composition || composition->width()!=width || composition->height()!=height) {
      // Release before replacement so even edge tiles retain the 4 MiB cap.
      delete composition; composition=nullptr;
      composition=new Surface(width,height);
    }
    composition->clear(40,40,40);
    viewport->draw(composition,bx,by);
    composition->drawBacking(0,0,bx,by,width,height,m.pixelsPerUnitX,m.pixelsPerUnitY);
  }
  viewport->clear_damage();
  if(changed) fl_pop_clip();
}
