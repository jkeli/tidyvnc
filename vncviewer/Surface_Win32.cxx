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

#include <FL/Fl_RGB_Image.H>
#include <FL/x.H>

#include <core/Exception.h>

#include "Surface.h"

void Surface::clear(unsigned char r, unsigned char g, unsigned char b, unsigned char a)
{
  RGBQUAD* out;
  int x, y;

  r = (unsigned)r * a / 255;
  g = (unsigned)g * a / 255;
  b = (unsigned)b * a / 255;

  out = data;
  for (y = 0;y < width();y++) {
    for (x = 0;x < height();x++) {
      out->rgbRed = r;
      out->rgbGreen = g;
      out->rgbBlue = b;
      out->rgbReserved = a;
      out++;
    }
  }
}

static void copyBitmap(HBITMAP bitmap, HDC target, int src_x, int src_y, int dst_x, int dst_y,
                       int dst_w, int dst_h)
{
  HDC dc;

  dc = CreateCompatibleDC(target);
  if (!dc)
    throw core::win32_error("CreateCompatibleDC", GetLastError());

  if (!SelectObject(dc, bitmap))
    throw core::win32_error("SelectObject", GetLastError());

  if (!BitBlt(target, dst_x, dst_y, dst_w, dst_h,
              dc, src_x, src_y, SRCCOPY)) {
    // If the desktop we're rendering to is inactive (like when the screen
    // is locked or the UAC is active), then GDI calls will randomly fail.
    // This is completely undocumented so we have no idea how best to deal
    // with it. For now, we've only seen this error and for this function
    // so only ignore this combination.
    if (GetLastError() != ERROR_INVALID_HANDLE)
      throw core::win32_error("BitBlt", GetLastError());
  }

  DeleteDC(dc);
}

void Surface::draw(int sx, int sy, int dx, int dy, int dw, int dh)
{
  copyBitmap(bitmap, fl_win32_gc(), sx, sy, dx, dy, dw, dh);
}

void Surface::draw(Surface* dst, int src_x, int src_y,
                   int dst_x, int dst_y, int dst_w, int dst_h)
{
  HDC dstdc;

  dstdc = CreateCompatibleDC(nullptr);
  if (!dstdc)
    throw core::win32_error("CreateCompatibleDC", GetLastError());

  if (!SelectObject(dstdc, dst->bitmap))
    throw core::win32_error("SelectObject", GetLastError());

  copyBitmap(bitmap, dstdc, src_x, src_y, dst_x, dst_y, dst_w, dst_h);

  DeleteDC(dstdc);
}

void Surface::blend(int /*src_x*/, int /*src_y*/,
                    int /*dst_x*/, int /*dst_y*/,
                    int /*dst_w*/, int /*dst_h*/,
                    int /*a*/)
{
  // Compositing doesn't work properly for window DC:s
  assert(false);
}

void Surface::blend(Surface* dst, int sx, int sy, int dx, int dy, int dw, int dh, int a)
{
  blendScaled(dst, sx, sy, dw, dh, dx, dy, dw, dh, a);
}

void Surface::blendScaled(Surface* dst, int src_x, int src_y, int src_w, int src_h,
                          int dst_x, int dst_y, int dst_w, int dst_h, int a)
{
  HDC dstdc, srcdc;
  BLENDFUNCTION blend;

  dstdc = CreateCompatibleDC(nullptr);
  if (!dstdc)
    throw core::win32_error("CreateCompatibleDC", GetLastError());
  srcdc = CreateCompatibleDC(nullptr);
  if (!srcdc)
    throw core::win32_error("CreateCompatibleDC", GetLastError());

  if (!SelectObject(dstdc, dst->bitmap))
    throw core::win32_error("SelectObject", GetLastError());
  if (!SelectObject(srcdc, bitmap))
    throw core::win32_error("SelectObject", GetLastError());

  blend.BlendOp = AC_SRC_OVER;
  blend.BlendFlags = 0;
  blend.SourceConstantAlpha = a;
  blend.AlphaFormat = AC_SRC_ALPHA;

  if (!AlphaBlend(dstdc, dst_x, dst_y, dst_w, dst_h,
                  srcdc, src_x, src_y, src_w, src_h, blend)) {
    // If the desktop we're rendering to is inactive (like when the screen
    // is locked or the UAC is active), then GDI calls will randomly fail.
    // This is completely undocumented so we have no idea how best to deal
    // with it. For now, we've only seen this error and for this function
    // so only ignore this combination.
    if (GetLastError() != ERROR_INVALID_HANDLE)
      throw core::win32_error("BitBlt", GetLastError());
  }

  DeleteDC(srcdc);
  DeleteDC(dstdc);
}

void Surface::alloc()
{
  BITMAPINFOHEADER bih;

  memset(&bih, 0, sizeof(bih));

  bih.biSize         = sizeof(BITMAPINFOHEADER);
  bih.biBitCount     = 32;
  bih.biPlanes       = 1;
  bih.biWidth        = width();
  bih.biHeight       = -height(); // Negative to get top-down
  bih.biCompression  = BI_RGB;

  bitmap = CreateDIBSection(nullptr, (BITMAPINFO*)&bih,
                            DIB_RGB_COLORS, (void**)&data, nullptr, 0);
  if (!bitmap)
    throw core::win32_error("CreateDIBSection", GetLastError());
}

void Surface::dealloc()
{
  DeleteObject(bitmap);
}

void Surface::update(const Fl_RGB_Image* image)
{
  const unsigned char* in;
  RGBQUAD* out;
  int x, y;

  assert(image->data_w() == width());
  assert(image->data_h() == height());

  // Convert data and pre-multiply alpha
  in = (const unsigned char*)image->data()[0];
  out = data;
  for (y = 0;y < image->data_h();y++) {
    for (x = 0;x < image->data_w();x++) {
      switch (image->d()) {
      case 1:
        out->rgbBlue = in[0];
        out->rgbGreen = in[0];
        out->rgbRed = in[0];
        out->rgbReserved = 0xff;
        break;
      case 2:
        out->rgbBlue = (unsigned)in[0] * in[1] / 255;
        out->rgbGreen = (unsigned)in[0] * in[1] / 255;
        out->rgbRed = (unsigned)in[0] * in[1] / 255;
        out->rgbReserved = in[1];
        break;
      case 3:
        out->rgbBlue = in[2];
        out->rgbGreen = in[1];
        out->rgbRed = in[0];
        out->rgbReserved = 0xff;
        break;
      case 4:
        out->rgbBlue = (unsigned)in[2] * in[3] / 255;
        out->rgbGreen = (unsigned)in[1] * in[3] / 255;
        out->rgbRed = (unsigned)in[0] * in[3] / 255;
        out->rgbReserved = in[3];
        break;
      }
      in += image->d();
      out++;
    }
    if (image->ld() != 0)
      in += image->ld() - image->data_w() * image->d();
  }
}


void Surface::drawBacking(int sx, int sy, int dx, int dy, int dw, int dh,
                          double /*qx*/, double /*qy*/)
{
  draw(sx, sy, dx, dy, dw, dh);
}
