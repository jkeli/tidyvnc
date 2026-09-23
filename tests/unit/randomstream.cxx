/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <rdr/RandomStream.h>
#include <cstdio>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {
bool systemSourceAvailable()
{
  for (const char* path : {"/dev/urandom", "/dev/random"})
    if (FILE* file = std::fopen(path, "r")) { std::fclose(file); return true; }
  return false;
}
std::vector<uint8_t> read(rdr::RandomStream& stream, size_t length)
{
  std::vector<uint8_t> bytes(length);
  if (!stream.hasData(length)) throw std::runtime_error("Random stream ended");
  stream.readBytes(bytes.data(), bytes.size());
  return bytes;
}
}

// Client key exchange must never use the process-wide rand() fallback. With
// a system source both modes read it; without one only the legacy mode proceeds.
TEST(RandomStream, RequireSystemFailsClosedWithoutSystemSource)
{
  if (systemSourceAvailable()) {
    rdr::RandomStream strict(rdr::RandomStream::RequireSystem);
    EXPECT_EQ(read(strict, 64).size(), 64u);
  } else {
    EXPECT_THROW(rdr::RandomStream strict(rdr::RandomStream::RequireSystem), std::runtime_error);
  }
  rdr::RandomStream legacy;
  EXPECT_EQ(read(legacy, 64).size(), 64u);
}

TEST(RandomStream, IndependentStrictStreamsReadConcurrently)
{
  if (!systemSourceAvailable()) GTEST_SKIP() << "No system random source";
  std::vector<std::vector<uint8_t>> values(4);
  std::vector<std::thread> threads;
  for (auto& value : values)
    threads.emplace_back([&value] {
      rdr::RandomStream stream(rdr::RandomStream::RequireSystem);
      value = read(stream, 4096);
    });
  for (auto& thread : threads) thread.join();
  for (size_t i = 1; i < values.size(); ++i) EXPECT_NE(values[0], values[i]);
}
