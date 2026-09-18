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

#ifndef __SURFACE_H__
#define __SURFACE_H__

#if defined(WIN32)
#include <windows.h>
#elif defined(__APPLE__)
// Apple headers conflict with FLTK, so redefine types here
typedef struct CGImage* CGImageRef;
#else
#include <X11/extensions/Xrender.h>
#endif

class Fl_RGB_Image;

class Surface {
public:
  Surface(int width, int height);
  Surface(const Fl_RGB_Image* image);
  ~Surface();

  int width() { return w; }
  int height() { return h; }
  int logicalWidth() { return lw; }
  int logicalHeight() { return lh; }

  void clear(unsigned char r, unsigned char g, unsigned char b, unsigned char a=255);

  // Source, destination and clip dimensions are backing pixels. The scale
  // converts only the final native-window copy to FLTK's logical context.
  void drawBacking(int src_x, int src_y, int dst_x, int dst_y,
                   int dst_w, int dst_h, double pixelsPerUnitX, double pixelsPerUnitY);

  void draw(int src_x, int src_y, int dst_x, int dst_y,
            int dst_w, int dst_h);
  void draw(Surface* dst, int src_x, int src_y, int dst_x, int dst_y,
            int dst_w, int dst_h);

  void blendScaled(Surface* dst, int src_x, int src_y, int src_w, int src_h,
                   int dst_x, int dst_y, int dst_w, int dst_h, int a=255);

  void blend(int src_x, int src_y, int dst_x, int dst_y,
             int dst_w, int dst_h, int a=255);
  void blend(Surface* dst, int src_x, int src_y, int dst_x, int dst_y,
             int dst_w, int dst_h, int a=255);

protected:
  void alloc();
  void dealloc();
  void update(const Fl_RGB_Image* image);

protected:
  int w, h, lw, lh;

#if defined(WIN32)
  RGBQUAD* data;
  HBITMAP bitmap;
#elif defined(__APPLE__)
  unsigned char* data;
#else
  Pixmap pixmap;
  Picture picture;
  XRenderPictFormat* visFormat;
#endif
};

#endif

