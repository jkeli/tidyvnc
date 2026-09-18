/* Copyright 2016 Pierre Ossman for Cendio AB
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
#include <stdlib.h>

#include <stdexcept>

#include <FL/Fl_RGB_Image.H>
#include <FL/fl_draw.H>
#include <cmath>
#include <FL/x.H>

#include "Surface.h"

#ifndef FLTK_USE_X11
#error "TigerVNC requires FLTK's X11 backend (Wayland-only FLTK is unsupported)"
#endif
// Applies to both the viewer and fbperf when FLTK provides both backends.
FL_EXPORT bool fl_disable_wayland = true;

void Surface::clear(unsigned char r, unsigned char g, unsigned char b, unsigned char a)
{
  XRenderColor color;

  color.red = (unsigned)r * 65535 / 255 * a / 255;
  color.green = (unsigned)g * 65535 / 255 * a / 255;
  color.blue = (unsigned)b * 65535 / 255 * a / 255;
  color.alpha = (unsigned)a * 65535 / 255;

  XRenderFillRectangle(fl_display, PictOpSrc, picture, &color,
                       0, 0, width(), height());
}

void Surface::draw(int src_x, int src_y, int dst_x, int dst_y,
                   int dst_w, int dst_h)
{
  Picture winPict;

  winPict = XRenderCreatePicture(fl_display, fl_window, visFormat, 0, nullptr);
  XRenderComposite(fl_display, PictOpSrc, picture, None, winPict,
                   src_x, src_y, 0, 0, dst_x, dst_y, dst_w, dst_h);
  XRenderFreePicture(fl_display, winPict);
}

void Surface::draw(Surface* dst, int src_x, int src_y,
                   int dst_x, int dst_y, int dst_w, int dst_h)
{
  XRenderComposite(fl_display, PictOpSrc, picture, None, dst->picture,
                   src_x, src_y, 0, 0, dst_x, dst_y, dst_w, dst_h);
}

static Picture alpha_mask(int a)
{
  Pixmap pixmap;
  XRenderPictFormat* format;
  XRenderPictureAttributes rep;
  Picture pict;
  XRenderColor color;

  if (a == 255)
    return None;

  pixmap = XCreatePixmap(fl_display, XDefaultRootWindow(fl_display),
                         1, 1, 8);

  format = XRenderFindStandardFormat(fl_display, PictStandardA8);
  rep.repeat = RepeatNormal;
  pict = XRenderCreatePicture(fl_display, pixmap, format, CPRepeat, &rep);
  XFreePixmap(fl_display, pixmap);

  color.alpha = (unsigned)a * 65535 / 255;

  XRenderFillRectangle(fl_display, PictOpSrc, pict, &color,
                       0, 0, 1, 1);

  return pict;
}

void Surface::blend(int src_x, int src_y, int dst_x, int dst_y,
                    int dst_w, int dst_h, int a)
{
  Picture winPict, alpha;

  winPict = XRenderCreatePicture(fl_display, fl_window, visFormat, 0, nullptr);
  alpha = alpha_mask(a);
  XRenderComposite(fl_display, PictOpOver, picture, alpha, winPict,
                   src_x, src_y, 0, 0, dst_x, dst_y, dst_w, dst_h);
  XRenderFreePicture(fl_display, winPict);

  if (alpha != None)
    XRenderFreePicture(fl_display, alpha);
}

void Surface::blend(Surface* dst, int src_x, int src_y,
                    int dst_x, int dst_y, int dst_w, int dst_h, int a)
{
  Picture alpha;

  alpha = alpha_mask(a);
  XRenderComposite(fl_display, PictOpOver, picture, alpha, dst->picture,
                   src_x, src_y, 0, 0, dst_x, dst_y, dst_w, dst_h);
  if (alpha != None)
    XRenderFreePicture(fl_display, alpha);
}


void Surface::alloc()
{
  XRenderPictFormat templ;
  XRenderPictFormat* format;

  pixmap = XCreatePixmap(fl_display, XDefaultRootWindow(fl_display),
                         width(), height(), 32);

  // Our code assumes a BGRA byte order, regardless of what the endian
  // of the machine is or the native byte order of XImage, so make sure
  // we find such a format
  templ.type = PictTypeDirect;
  templ.depth = 32;
  if (XImageByteOrder(fl_display) == MSBFirst) {
    templ.direct.alpha = 0;
    templ.direct.red   = 8;
    templ.direct.green = 16;
    templ.direct.blue  = 24;
  } else {
    templ.direct.alpha = 24;
    templ.direct.red   = 16;
    templ.direct.green = 8;
    templ.direct.blue  = 0;
  }
  templ.direct.alphaMask = 0xff;
  templ.direct.redMask = 0xff;
  templ.direct.greenMask = 0xff;
  templ.direct.blueMask = 0xff;

  format = XRenderFindFormat(fl_display, PictFormatType | PictFormatDepth |
                             PictFormatRed | PictFormatRedMask |
                             PictFormatGreen | PictFormatGreenMask |
                             PictFormatBlue | PictFormatBlueMask |
                             PictFormatAlpha | PictFormatAlphaMask,
                             &templ, 0);

  if (!format)
    throw std::runtime_error("XRenderFindFormat");

  picture = XRenderCreatePicture(fl_display, pixmap, format, 0, nullptr);

  visFormat = XRenderFindVisualFormat(fl_display, fl_visual->visual);
}

void Surface::dealloc()
{
  XRenderFreePicture(fl_display, picture);
  XFreePixmap(fl_display, pixmap);
}

void Surface::update(const Fl_RGB_Image* image)
{
  XImage* img;
  GC gc;

  int x, y;
  const unsigned char* in;
  unsigned char* out;

  assert(image->data_w() == width());
  assert(image->data_h() == height());

  img = XCreateImage(fl_display, (Visual*)CopyFromParent, 32,
                     ZPixmap, 0, nullptr, width(), height(),
                     32, 0);
  if (!img)
    throw std::runtime_error("XCreateImage");

  img->data = (char*)malloc(img->bytes_per_line * img->height);
  if (!img->data)
    throw std::bad_alloc();

  // Convert data and pre-multiply alpha
  in = (const unsigned char*)image->data()[0];
  out = (unsigned char*)img->data;
  for (y = 0;y < img->height;y++) {
    for (x = 0;x < img->width;x++) {
      switch (image->d()) {
      case 1:
        *out++ = in[0];
        *out++ = in[0];
        *out++ = in[0];
        *out++ = 0xff;
        break;
      case 2:
        *out++ = (unsigned)in[0] * in[1] / 255;
        *out++ = (unsigned)in[0] * in[1] / 255;
        *out++ = (unsigned)in[0] * in[1] / 255;
        *out++ = in[1];
        break;
      case 3:
        *out++ = in[2];
        *out++ = in[1];
        *out++ = in[0];
        *out++ = 0xff;
        break;
      case 4:
        *out++ = (unsigned)in[2] * in[3] / 255;
        *out++ = (unsigned)in[1] * in[3] / 255;
        *out++ = (unsigned)in[0] * in[3] / 255;
        *out++ = in[3];
        break;
      }
      in += image->d();
    }
    if (image->ld() != 0)
      in += image->ld() - image->data_w() * image->d();
  }

  gc = XCreateGC(fl_display, pixmap, 0, nullptr);
  XPutImage(fl_display, pixmap, gc, img,
            0, 0, 0, 0, img->width, img->height);
  XFreeGC(fl_display, gc);

  XDestroyImage(img);
}


// FLTK's public clip region is in logical coordinates. Convert only the
// region intersecting this tile; do not depend on FLTK's private drivers.
static void backingClip(Region logical, Region backing, int x, int y, int w, int h,
                        double qx, double qy)
{
  if(w<=0 || h<=0) return;
  int inside=XRectInRegion(logical,x,y,w,h);
  if(!inside) return;
  if(inside==RectangleIn || (w==1 && h==1)) {
    int left=int(std::floor(x*qx)), top=int(std::floor(y*qy));
    XRectangle rect;
    rect.x=left; rect.y=top;
    rect.width=int(std::ceil((x+w)*qx))-left;
    rect.height=int(std::ceil((y+h)*qy))-top;
    XUnionRectWithRegion(&rect,backing,backing);
  } else if(w>=h) {
    backingClip(logical,backing,x,y,w/2,h,qx,qy);
    backingClip(logical,backing,x+w/2,y,w-w/2,h,qx,qy);
  } else {
    backingClip(logical,backing,x,y,w,h/2,qx,qy);
    backingClip(logical,backing,x,y+h/2,w,h-h/2,qx,qy);
  }
}

void Surface::drawBacking(int sx, int sy, int dx, int dy, int dw, int dh,
                          double qx, double qy)
{
  Picture target=XRenderCreatePicture(fl_display,fl_window,visFormat,0,nullptr);
  Region logical=(Region)fl_clip_region();
  if(logical) {
    Region native=XCreateRegion();
    int left=int(std::floor(dx/qx)), top=int(std::floor(dy/qy));
    backingClip(logical,native,left,top,int(std::ceil((dx+dw)/qx))-left,
                int(std::ceil((dy+dh)/qy))-top,qx,qy);
    XRenderSetPictureClipRegion(fl_display,target,native);
    XDestroyRegion(native);
  }
  XRenderComposite(fl_display,PictOpSrc,picture,None,target,sx,sy,0,0,dx,dy,dw,dh);
  XRenderFreePicture(fl_display,target);
}

void Surface::blendScaled(Surface* dst, int sx, int sy, int sw, int sh,
                          int dx, int dy, int dw, int dh, int a)
{
  XTransform transform = {{{XDoubleToFixed(double(sw)/dw), 0, XDoubleToFixed(sx)},
                           {0, XDoubleToFixed(double(sh)/dh), XDoubleToFixed(sy)},
                           {0, 0, XDoubleToFixed(1)}}};
  XRenderSetPictureTransform(fl_display, picture, &transform);
  XRenderSetPictureFilter(fl_display, picture, FilterBilinear, nullptr, 0);
  Picture alpha = alpha_mask(a);
  XRenderComposite(fl_display, PictOpOver, picture, alpha, dst->picture,
                   0, 0, 0, 0, dx, dy, dw, dh);
  if (alpha != None) XRenderFreePicture(fl_display, alpha);
  XTransform identity = {{{XDoubleToFixed(1),0,0},{0,XDoubleToFixed(1),0},{0,0,XDoubleToFixed(1)}}};
  XRenderSetPictureTransform(fl_display, picture, &identity);
  XRenderSetPictureFilter(fl_display, picture, FilterNearest, nullptr, 0);
}
