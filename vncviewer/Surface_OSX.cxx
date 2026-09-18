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

#include <stdexcept>

#include <ApplicationServices/ApplicationServices.h>

#include <FL/Fl_RGB_Image.H>
#include <FL/Fl_Window.H>
#include <FL/x.H>

#include "Surface.h"

static CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

static CGImageRef create_image(CGColorSpaceRef lut,
                               const unsigned char* data,
                               int w, int h, bool skip_alpha)
{
  CGDataProviderRef provider;
  CGImageAlphaInfo alpha;

  CGImageRef image;

  provider = CGDataProviderCreateWithData(nullptr, data,
                                          size_t(w) * h * 4, nullptr);
  if (!provider)
    throw std::runtime_error("CGDataProviderCreateWithData");

  // FIXME: This causes a performance hit, but is necessary to avoid
  //        artifacts in the edges of the window
  if (skip_alpha)
    alpha = kCGImageAlphaNoneSkipFirst;
  else
    alpha = kCGImageAlphaPremultipliedFirst;

  image = CGImageCreate(w, h, 8, 32, w * 4, lut,
                        alpha | kCGBitmapByteOrder32Little,
                        provider, nullptr, false,
                        kCGRenderingIntentDefault);
  CGDataProviderRelease(provider);
  if (!image)
    throw std::runtime_error("CGImageCreate");

  return image;
}

static void render(CGContextRef gc, CGColorSpaceRef lut,
                   const unsigned char* data,
                   CGBlendMode mode, CGFloat alpha,
                   int src_x, int src_y, int src_w, int src_h,
                   int x, int y, int w, int h, int crop_w = -1, int crop_h = -1)
{
  CGRect rect;
  CGImageRef image, subimage;

  image = create_image(lut, data, src_w, src_h, mode == kCGBlendModeCopy);

  rect.origin.x = src_x;
  rect.origin.y = src_y;
  rect.size.width = crop_w < 0 ? w : crop_w;
  rect.size.height = crop_h < 0 ? h : crop_h;

  subimage = CGImageCreateWithImageInRect(image, rect);
  if (!subimage) {
    CGImageRelease(image);
    throw std::runtime_error("CGImageCreateImageWithImageInRect");
  }

  CGContextSaveGState(gc);

  CGContextSetBlendMode(gc, mode);
  CGContextSetAlpha(gc, alpha);

  rect.origin.x = x;
  rect.origin.y = y;
  rect.size.width = w;
  rect.size.height = h;

  CGContextDrawImage(gc, rect, subimage);

  CGContextRestoreGState(gc);

  CGImageRelease(subimage);
  CGImageRelease(image);
}

static CGContextRef make_bitmap(int width, int height, unsigned char* data)
{
  CGContextRef bitmap;

  bitmap = CGBitmapContextCreate(data, width, height, 8, width*4, srgb,
                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  if (!bitmap)
    throw std::runtime_error("CGBitmapContextCreate");

  return bitmap;
}

void Surface::clear(unsigned char r, unsigned char g, unsigned char b, unsigned char a)
{
  unsigned char* out;
  int x, y;

  r = (unsigned)r * a / 255;
  g = (unsigned)g * a / 255;
  b = (unsigned)b * a / 255;

  out = data;
  for (y = 0;y < width();y++) {
    for (x = 0;x < height();x++) {
      *out++ = b;
      *out++ = g;
      *out++ = r;
      *out++ = a;
    }
  }
}

void Surface::draw(int src_x, int src_y, int dst_x, int dst_y,
                   int dst_w, int dst_h)
{
  drawBacking(src_x, src_y, dst_x, dst_y, dst_w, dst_h, 1, 1);
}

void Surface::draw(Surface* dst, int src_x, int src_y,
                   int dst_x, int dst_y, int dst_w, int dst_h)
{
  CGContextRef bitmap;

  bitmap = make_bitmap(dst->width(), dst->height(), dst->data);

  // macOS Coordinates are from bottom left, not top left
  dst_y = dst->height() - (dst_y + dst_h);

  render(bitmap, srgb, data, kCGBlendModeCopy, 1.0,
         src_x, src_y, width(), height(), dst_x, dst_y, dst_w, dst_h);

  CGContextRelease(bitmap);
}

void Surface::blend(int src_x, int src_y, int dst_x, int dst_y,
                    int dst_w, int dst_h, int a)
{
  CGContextRef gc = fl_mac_gc();
  CGContextSaveGState(gc);
  // FLTK positions strokes at half-unit centers. Images use pixel edges.
  CGContextTranslateCTM(gc, -0.5, -0.5);
  CGContextScaleCTM(gc, 1, -1);
  render(gc, srgb, data, kCGBlendModeNormal, (CGFloat)a/255.0,
         src_x, src_y, width(), height(), dst_x, -dst_y-dst_h, dst_w, dst_h);
  CGContextRestoreGState(gc);
}

void Surface::blend(Surface* dst, int src_x, int src_y,
                    int dst_x, int dst_y, int dst_w, int dst_h, int a)
{
  CGContextRef bitmap;

  bitmap = make_bitmap(dst->width(), dst->height(), dst->data);

  // macOS Coordinates are from bottom left, not top left
  dst_y = dst->height() - (dst_y + dst_h);

  render(bitmap, srgb, data, kCGBlendModeNormal, (CGFloat)a/255.0,
         src_x, src_y, width(), height(), dst_x, dst_y, dst_w, dst_h);

  CGContextRelease(bitmap);
}

void Surface::alloc()
{
  data = new unsigned char[size_t(width()) * height() * 4];
}

void Surface::dealloc()
{
  delete [] data;
}

void Surface::update(const Fl_RGB_Image* image)
{
  int x, y;
  const unsigned char* in;
  unsigned char* out;

  assert(image->data_w() == width());
  assert(image->data_h() == height());

  // Convert data and pre-multiply alpha
  in = (const unsigned char*)image->data()[0];
  out = data;
  for (y = 0;y < image->data_h();y++) {
    for (x = 0;x < image->data_w();x++) {
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
}

void Surface::drawBacking(int sx, int sy, int dx, int dy, int dw, int dh,
                          double qx, double qy)
{
  CGContextRef gc = fl_mac_gc();
  CGContextSaveGState(gc);
  // Keep the window's native translation, scale and clip. Undo only the
  // logical-unit mapping for this already-resampled backing-pixel copy.
  CGContextTranslateCTM(gc, -0.5, -0.5);
  CGContextScaleCTM(gc, 1/qx, -1/qy);
  CGContextSetInterpolationQuality(gc, kCGInterpolationNone);
  render(gc, srgb, data, kCGBlendModeCopy, 1,
         sx, sy, width(), height(), dx, -dy-dh, dw, dh);
  CGContextRestoreGState(gc);
}

void Surface::blendScaled(Surface* dst, int sx, int sy, int sw, int sh,
                           int dx, int dy, int dw, int dh, int a)
{
  CGContextRef gc = make_bitmap(dst->width(), dst->height(), dst->data);
  render(gc, srgb, data, kCGBlendModeNormal, (CGFloat)a/255,
         sx, sy, width(), height(), dx, dst->height()-dy-dh, dw, dh, sw, sh);
  CGContextRelease(gc);
}
