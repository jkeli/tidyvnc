/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <core/wipe.h>
#include <stdexcept>
#include <string>
#include <vector>

TEST(Wipe, ScopedWipeClearsRegisteredObjectsOnNormalExit)
{
  std::string secret = "correct horse battery staple"; // heap-allocated
  std::string shortSecret = "pw";                       // inline (short string)
  std::vector<uint8_t> key{1, 2, 3, 4};
  uint8_t block[8] = {9, 9, 9, 9, 9, 9, 9, 9};
  {
    core::ScopedWipe secrets;
    secrets.add(secret).add(shortSecret).add(key).add(block, sizeof(block));
  }
  EXPECT_TRUE(secret.empty()); EXPECT_TRUE(shortSecret.empty());
  EXPECT_EQ(key, (std::vector<uint8_t>{0, 0, 0, 0}));
  for (uint8_t byte : block) EXPECT_EQ(byte, 0);
}

TEST(Wipe, ScopedWipeClearsOnExceptionAndWipeZeroesRanges)
{
  std::string secret = "secret";
  uint8_t block[4] = {1, 2, 3, 4};
  try {
    core::ScopedWipe secrets;
    secrets.add(secret).add(block, sizeof(block));
    throw std::runtime_error("fail");
  } catch (const std::runtime_error&) {}
  EXPECT_TRUE(secret.empty());
  for (uint8_t byte : block) EXPECT_EQ(byte, 0);
  uint8_t bytes[3] = {7, 7, 7};
  core::wipe(bytes, sizeof(bytes));
  EXPECT_EQ(bytes[0] | bytes[1] | bytes[2], 0);
  core::wipe(nullptr, 0);
}
