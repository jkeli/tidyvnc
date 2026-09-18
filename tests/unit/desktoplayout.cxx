/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include "DesktopLayout.h"
#include <algorithm>
#include <stdexcept>

TEST(DesktopLayout, MixedDensityNegativeOriginsAndStableIds)
{
  std::vector<DesktopMonitor> monitors={
    {42,0,{-1440,-200,0,700},2880,1800},
    {7,1,{0,0,1920,1080},1920,1080}};
  DesktopLayout logical(monitors,ScalingSettings::Logical);
  EXPECT_EQ(3360,logical.width); EXPECT_EQ(1280,logical.height);
  EXPECT_EQ(core::Rect(1440,200,3360,1280),logical.regions[0].canvas);
  DesktopLayout device(monitors,ScalingSettings::Device);
  EXPECT_EQ(4800,device.width); EXPECT_EQ(1800,device.height);
  EXPECT_TRUE(device.normalized);
  EXPECT_EQ(core::Rect(2880,200,4800,1280),device.regions[0].canvas);
  EXPECT_TRUE(device.screens().validate(device.width,device.height));
  std::reverse(monitors.begin(),monitors.end());
  EXPECT_EQ(device.screens(),DesktopLayout(monitors,ScalingSettings::Device).screens());
}

TEST(DesktopLayout, RejectInvalidProtocolLayouts)
{
  std::vector<DesktopMonitor> monitors={{1,0,{0,0,100,100},200,200}};
  EXPECT_THROW(DesktopLayout({},ScalingSettings::Device),std::invalid_argument);
  monitors.push_back(monitors.front());
  EXPECT_THROW(DesktopLayout(monitors,ScalingSettings::Device),std::invalid_argument);
  monitors[1]={2,1,{50,0,150,100},100,100};
  EXPECT_THROW(DesktopLayout(monitors,ScalingSettings::Device),std::invalid_argument);
  monitors[1]={2,1,{100,0,201,100},65535,100};
  EXPECT_THROW(DesktopLayout(monitors,ScalingSettings::Device),std::overflow_error);
  monitors.assign(256,{1,0,{0,0,100,100},200,200});
  EXPECT_THROW(DesktopLayout(monitors,ScalingSettings::Logical),std::invalid_argument);
}

TEST(DesktopLayout, DevicePixelIdentityAndSeamInput)
{
  DesktopLayout layout({{1,0,{0,0,101,77},202,154},
                        {2,1,{101,0,302,155},201,155}},ScalingSettings::Device);
  EXPECT_EQ(403,layout.width);
  for(const auto& region : layout.regions) {
    DisplayMetrics m;
    m.pixelsPerUnitX=m.pixelsPerUnitY=region.monitor.id==1?2:1;
    DesktopTransform t(layout.width,layout.height,layout.width/m.pixelsPerUnitX,
      layout.height/m.pixelsPerUnitY,m,{},ScalingSettings::Device);
    t.placeOnCanvas(layout.width,layout.height,region.canvas,ScalingSettings::Device);
    EXPECT_TRUE(t.identity());
    EXPECT_EQ(region.canvas.tl,t.remotePoint(.5/m.pixelsPerUnitX,.5/m.pixelsPerUnitY));
    EXPECT_EQ(region.canvas.br.x-1,
      t.remotePoint((region.canvas.width()-.5)/m.pixelsPerUnitX,.5/m.pixelsPerUnitY).x);
  }
}

TEST(DesktopLayout, PanAndServerResizeKeepOneCoordinateMap)
{
  DisplayMetrics m; m.pixelsPerUnitX=m.pixelsPerUnitY=2;
  // Server declined the requested 600x300: its actual 800x500 remains
  // authoritative, with a shared 25-backing-pixel pan on the second view.
  DesktopTransform t(800,500,300,150,m,{},ScalingSettings::Device);
  t.placeOnCanvas(600,300,{300,0,600,300},ScalingSettings::Device,25,50);
  EXPECT_EQ(core::Point(325,50),t.remotePoint(.25,.25));
  EXPECT_EQ(-325,t.originBX); EXPECT_EQ(-50,t.originBY);
  t.placeOnCanvas(600,300,{300,0,600,300},ScalingSettings::Device,99999,99999);
  EXPECT_EQ(core::Point(500,200),t.remotePoint(.25,.25));
}
