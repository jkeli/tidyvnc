// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
//
// Remote cursor images as real HCURSORs (DESKTOP.md section 3, D13). The core
// cursor sampler produces straight-alpha RGBA at device resolution.
// CreateIconIndirect takes a 32-bit top-down DIB with straight BGRA alpha,
// plus a monochrome mask that alpha cursors ignore but that must exist.

#include "tidyvnc_windows.h"

#include <windows.h>

#include <cstring>

extern "C" {

int32_t tvw_cursor_create(const uint8_t* rgba, uint32_t width, uint32_t height, uint32_t hotspot_x, uint32_t hotspot_y,
                          uint64_t* cursor)
{
  if (!rgba || !cursor)
    return E_POINTER;
  *cursor = 0;
  if (width == 0 || height == 0 || width > 1024 || height > 1024 || hotspot_x >= width || hotspot_y >= height)
    return E_INVALIDARG;

  BITMAPV5HEADER header = {};
  header.bV5Size = sizeof(header);
  header.bV5Width = (LONG)width;
  header.bV5Height = -(LONG)height; // Top-down
  header.bV5Planes = 1;
  header.bV5BitCount = 32;
  header.bV5Compression = BI_BITFIELDS;
  header.bV5RedMask = 0x00ff0000;
  header.bV5GreenMask = 0x0000ff00;
  header.bV5BlueMask = 0x000000ff;
  header.bV5AlphaMask = 0xff000000;

  HDC screen = GetDC(nullptr);
  void* bits = nullptr;
  HBITMAP colour = CreateDIBSection(screen, reinterpret_cast<BITMAPINFO*>(&header), DIB_RGB_COLORS, &bits, nullptr, 0);
  ReleaseDC(nullptr, screen);
  if (!colour)
    return HRESULT_FROM_WIN32(GetLastError());

  auto* out = static_cast<uint8_t*>(bits);
  size_t pixels = (size_t)width * height;
  for (size_t i = 0; i < pixels; i++) {
    out[i * 4 + 0] = rgba[i * 4 + 2];
    out[i * 4 + 1] = rgba[i * 4 + 1];
    out[i * 4 + 2] = rgba[i * 4 + 0];
    out[i * 4 + 3] = rgba[i * 4 + 3];
  }
  GdiFlush();

  HBITMAP mask = CreateBitmap((int)width, (int)height, 1, 1, nullptr);
  if (!mask) {
    HRESULT error = HRESULT_FROM_WIN32(GetLastError());
    DeleteObject(colour);
    return error;
  }

  ICONINFO info = {};
  info.fIcon = FALSE;
  info.xHotspot = hotspot_x;
  info.yHotspot = hotspot_y;
  info.hbmMask = mask;
  info.hbmColor = colour;
  HICON icon = CreateIconIndirect(&info);
  HRESULT result = icon ? S_OK : HRESULT_FROM_WIN32(GetLastError());
  DeleteObject(mask);
  DeleteObject(colour);
  if (icon)
    *cursor = (uint64_t)(uintptr_t)icon;
  return result;
}

void tvw_cursor_destroy(uint64_t cursor)
{
  if (cursor)
    DestroyCursor(reinterpret_cast<HCURSOR>((uintptr_t)cursor));
}

void tvw_cursor_limits(uint32_t* max_width, uint32_t* max_height)
{
  // CreateIconIndirect accepts large alpha cursors; the system scales them
  // only when the cursor size setting says so. Keep the vncviewer bound.
  if (max_width)
    *max_width = 1024;
  if (max_height)
    *max_height = 1024;
}

} // extern "C"
