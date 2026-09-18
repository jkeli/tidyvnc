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

#include <FL/Fl_RGB_Image.H>

#include "Surface.h"
#include <limits>
#include <stdexcept>

static void checkSurfaceSize(int w, int h)
{
  if(w <= 0 || h <= 0 || size_t(w) > (std::numeric_limits<size_t>::max)()/4/size_t(h))
    throw std::overflow_error("Invalid surface allocation size");
}

Surface::Surface(int width, int height) :
  w(width), h(height), lw(width), lh(height)
{
  checkSurfaceSize(w,h);
  alloc();
}

Surface::Surface(const Fl_RGB_Image* image) :
  w(image->data_w()), h(image->data_h()), lw(image->w()), lh(image->h())
{
  checkSurfaceSize(w,h);
  alloc();
  try { update(image); } catch (...) { dealloc(); throw; }
}

Surface::~Surface()
{
  dealloc();
}
