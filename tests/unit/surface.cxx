/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <FL/Fl_RGB_Image.H>
#include "Surface.h"
#ifdef __APPLE__
#include "cocoa.h"
#include <FL/Fl_Image_Surface.H>
#include <FL/fl_draw.H>
#endif

class ReadableSurface : public Surface {
public:
  using Surface::Surface;
  unsigned byte(int x,int y,int channel) {
    return reinterpret_cast<const unsigned char*>(data)[(size_t(y)*width()+x)*4+channel];
  }
};
TEST(Surface, HighResolutionRasterAndRowStride)
{
  const unsigned char rgb[]={255,0,0, 0,255,0, 99,99, 0,0,255, 255,255,255, 88,88};
  Fl_RGB_Image image(rgb,2,2,3,8);
  image.scale(1,1,0,1);
  ReadableSurface surface(&image);
  EXPECT_EQ(2,surface.width()); EXPECT_EQ(2,surface.height());
  EXPECT_EQ(1,surface.logicalWidth()); EXPECT_EQ(1,surface.logicalHeight());
  EXPECT_EQ(255u,surface.byte(0,0,2));
  EXPECT_EQ(255u,surface.byte(1,0,1));
  EXPECT_EQ(255u,surface.byte(0,1,0));
  EXPECT_EQ(255u,surface.byte(1,1,2));
}
TEST(Surface, BitmapCopyOrientationAndOffset)
{
  const unsigned char rgb[]={255,0,0, 0,255,0, 0,0,255, 255,255,255};
  Fl_RGB_Image image(rgb,2,2,3);
  ReadableSurface source(&image), destination(5,5);
  destination.clear(0,0,0);
  source.draw(&destination,0,0,1,2,2,2);
  EXPECT_EQ(255u,destination.byte(1,2,2));
  EXPECT_EQ(255u,destination.byte(2,2,1));
  EXPECT_EQ(255u,destination.byte(1,3,0));
  EXPECT_EQ(0u,destination.byte(0,0,2));
}
TEST(Surface, PremultipliedAlpha)
{
  const unsigned char rgba[]={200,100,50,128};
  Fl_RGB_Image image(rgba,1,1,4);
  ReadableSurface source(&image), destination(1,1);
  EXPECT_EQ(100u,source.byte(0,0,2));
  EXPECT_EQ(50u,source.byte(0,0,1));
  EXPECT_EQ(25u,source.byte(0,0,0));
  destination.clear(0,0,0);
  source.blend(&destination,0,0,0,0,1,1);
  EXPECT_NEAR(100u,destination.byte(0,0,2),1);
}

#ifdef __APPLE__
TEST(Surface, ExplicitTargetScaleForOverlayRaster)
{
  // No window or first-window Retina heuristic is involved. Verify that a
  // logical rectangle lands at the requested physical pixel edges.
  Fl_Image_Surface surface(10,8,0);
  Fl_Surface_Device::push_current(&surface);
  cocoa_scale_image_surface(2,2);
  fl_rectf(0,0,5,4,FL_BLACK);
  fl_rectf(1,1,2,2,FL_RED);
  Fl_RGB_Image* image=surface.image();
  Fl_Surface_Device::pop_current();
  ASSERT_EQ(10,image->data_w()); ASSERT_EQ(8,image->data_h());
  image->scale(5,4,0,1);
  ReadableSurface raster(image);
  for(int y=0;y<8;++y) for(int x=0;x<10;++x)
    EXPECT_EQ(x>=2 && x<6 && y>=2 && y<6 ? 255u : 0u,raster.byte(x,y,2)) << x << ',' << y;
  EXPECT_EQ(5,raster.logicalWidth()); EXPECT_EQ(4,raster.logicalHeight());
  delete image;
}
#endif
