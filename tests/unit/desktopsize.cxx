/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/DesktopSize.h>
#include <stdexcept>

using namespace viewer;

TEST(DesktopSize, LegacyCommandLineFormKeepsRetainedLeniency)
{
  EXPECT_TRUE(DesktopSize::parse("", DesktopSizeSyntax::Legacy).empty());
  EXPECT_EQ(DesktopSize::parse("800x600", DesktopSizeSyntax::Legacy).text(), "800x600");
  EXPECT_EQ(DesktopSize::parse(" +0800x+600trailing", DesktopSizeSyntax::Legacy).text(), "800x600");
  EXPECT_EQ(DesktopSize::parse("\t1x\n2", DesktopSizeSyntax::Legacy).text(), "1x2");
  EXPECT_EQ(DesktopSize::parse("65535x65535", DesktopSizeSyntax::Legacy).text(), "65535x65535");
  for (const auto* bad : {"0x600", "65536x1", "800 x600", "800X600", "-1x2", "x2", "2x", "2x+", "99999999999999999999x1"})
    EXPECT_THROW(DesktopSize::parse(bad, DesktopSizeSyntax::Legacy), std::invalid_argument) << bad;
}

TEST(DesktopSize, StrictNativeFormIsExactDecimal)
{
  EXPECT_TRUE(DesktopSize::parse("", DesktopSizeSyntax::Strict).empty());
  const auto value = DesktopSize::parse("0008x0004", DesktopSizeSyntax::Strict);
  EXPECT_EQ(DesktopSize::parse("000000000000000000000000000001x1", DesktopSizeSyntax::Strict).text(), "1x1"); // 32 bytes
  EXPECT_EQ(value.width, 8u); EXPECT_EQ(value.height, 4u); EXPECT_EQ(value.text(), "8x4");
  for (const auto* bad : {"0x2", "65536x1", "2X3", "2x3extra", " 2x3", "2x", "1.5x3", "+2x3", "2x3 ",
                          "0000000000000000000000000000001x1"})
    EXPECT_THROW(DesktopSize::parse(bad, DesktopSizeSyntax::Strict), std::invalid_argument) << bad;
}
