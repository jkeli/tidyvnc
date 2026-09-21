/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/WindowGeometry.h>
#include <climits>
#include <cstdio>
#include <stdexcept>
using viewer::WindowGeometry;
TEST(WindowGeometry, DefinedRetainedScanfFormsRemainEquivalent) {
  for (const auto* text : {"+1+2", "+-100+-200", "++1++2", "+ 10+\t20suffix", "800x600", "800x600suffix",
                          "  +800x+600", "800x600+10+20", "800x600+-10+-20ignored", "800x600-10-20",
                          "800x600+", "800x600+bad", "+-2147483648+2147483647", "2147483647x1"}) {
    SCOPED_TRACE(text); WindowGeometry reference;
    auto matched = std::sscanf(text,"+%d+%d",&reference.x,&reference.y);
    if (matched == 2) reference.hasPosition = true;
    else {
      reference = {};
      matched = std::sscanf(text,"%dx%d+%d+%d",&reference.width,&reference.height,&reference.x,&reference.y);
      ASSERT_TRUE(matched == 2 || matched == 4);
      reference.hasSize = true; reference.hasPosition = matched == 4;
    }
    const auto value = WindowGeometry::parse(text);
    EXPECT_EQ(value.hasPosition,reference.hasPosition); EXPECT_EQ(value.hasSize,reference.hasSize);
    EXPECT_EQ(value.width,reference.width); EXPECT_EQ(value.height,reference.height);
    EXPECT_EQ(value.x,reference.x); EXPECT_EQ(value.y,reference.y);
  }
}
TEST(WindowGeometry, RejectsMalformedNonpositiveAndOverflowWithoutScanfUndefinedBehavior) {
  for (const auto* text : {"x", "800", "800X600", "800 x600", "800x600+1", "+1", "-1-2", "0x1", "1x0", "-1x2",
                          "1x-2", "2147483648x1", "1x2147483648", "+2147483648+0", "+-2147483649+0",
                          "800x600+2147483648+0", "800x600+0+2147483648"}) {
    SCOPED_TRACE(text); EXPECT_THROW(WindowGeometry::parse(text),std::invalid_argument);
  }
  EXPECT_THROW(WindowGeometry::parse(std::string("10x20\0tail",10)),std::invalid_argument);
  EXPECT_THROW(WindowGeometry::parse("1x1"+std::string(65534,'a')),std::invalid_argument);
}
TEST(WindowGeometry, EmptyAndBoundedTrailingText) {
  const auto empty = WindowGeometry::parse("");
  EXPECT_FALSE(empty.hasSize); EXPECT_FALSE(empty.hasPosition);
  const auto longest = WindowGeometry::parse("1x1"+std::string(65533,'a'));
  EXPECT_TRUE(longest.hasSize); EXPECT_EQ(longest.width,1); EXPECT_FALSE(longest.hasPosition);
}
