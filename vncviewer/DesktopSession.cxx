/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#include "DesktopSession.h"
#include "CConn.h"
#include "PlatformPixelBuffer.h"
#include "Viewport.h"
#include <FL/Fl.H>
#include <memory>

DesktopSession::DesktopSession(CConn* connection, int width, int height) : cc(connection)
{
  std::unique_ptr<PlatformPixelBuffer> buffer(new PlatformPixelBuffer(width,height));
  cc->setFramebuffer(buffer.get());
  framebuffer=buffer.release();
}
DesktopSession::~DesktopSession() { Fl::remove_timeout(flushDamage,this); }
void DesktopSession::attach(Viewport* view)
{
  if(!input) input=view;
  consumers.insert(view);
  // CPU cache is at most 128 MiB across views, separate from the authoritative
  // remote framebuffer and bounded per-view composition/cursor scratch.
  size_t bytes=std::min(size_t(32*1024*1024),size_t(128*1024*1024)/consumers.size());
  for(Viewport* consumer : consumers) consumer->setCacheBudget(bytes);
}
void DesktopSession::detach(Viewport* view) { consumers.erase(view); }
void DesktopSession::synchronize()
{
  cc->syncFramebuffer();
  core::Rect damage=framebuffer->getDamage();
  if(damage.is_empty()) return;
  // Harvest exactly once, then invalidate every consumer before reuse.
  for(Viewport* view : consumers) view->sourceDamaged(damage);
  // An expose can harvest new pixels during a decoder batch. Repaint the
  // other views (and portions outside the current clip) without waiting for
  // another server update or losing damage when FLTK finishes this draw.
  if(!Fl::has_timeout(flushDamage,this)) Fl::add_timeout(0,flushDamage,this);
}
void DesktopSession::update()
{
  synchronize();
  flushDamage(this);
}
void DesktopSession::flushDamage(void* data)
{
  DesktopSession* self=static_cast<DesktopSession*>(data);
  Fl::remove_timeout(flushDamage,self);
  for(Viewport* view : self->consumers) view->flushSourceDamage();
}
void DesktopSession::resize(int width,int height)
{
  if(width==framebuffer->width() && height==framebuffer->height()) return;
  std::unique_ptr<PlatformPixelBuffer> buffer(new PlatformPixelBuffer(width,height));
  cc->setFramebuffer(buffer.get());
  framebuffer=buffer.release();
  for(Viewport* view : consumers) view->sourceReplaced();
}
