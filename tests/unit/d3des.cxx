/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */

#include <gtest/gtest.h>

#include <rfb/d3des.h>
#include <rfb/obfuscate.h>

#include <array>
#include <atomic>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {

using Block = std::array<uint8_t, 8>;
using Challenge = std::array<uint8_t, 16>;

// Standard DES known-answer vector with each key byte bit-reversed to match
// VNC's convention (ordinary DES key: 133457799bbcdff1).
const Block knownKey = {{0xc8, 0x2c, 0xea, 0x9e, 0xd9, 0x3d, 0xfb, 0x8f}};
const Block plaintext = {{0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef}};
const Block ciphertext = {{0x85, 0xe8, 0x13, 0x54, 0x0f, 0x0a, 0xb4, 0x05}};
const Block passwordKey = {{'p', 'a', 's', 's', 'w', 'o', 'r', 'd'}};
const Block secretKey = {{'s', 'e', 'c', 'r', 'e', 't', 0, 0}};
const Challenge challenge = {{0, 1, 2, 3, 4, 5, 6, 7,
                              8, 9, 10, 11, 12, 13, 14, 15}};

// Captured from the unmodified implementation at 7daf39fa, before extraction.
const Challenge passwordResponse = {{0xb8, 0x66, 0x92, 0x41, 0x25, 0xc8, 0xee, 0xbb,
                                     0x9d, 0xeb, 0xc1, 0xdb, 0x61, 0xc5, 0x38, 0xe2}};
const Challenge secretResponse = {{0xee, 0x22, 0x53, 0x9f, 0x33, 0xa5, 0x98, 0x3e,
                                   0xc1, 0x2f, 0x9c, 0x2e, 0xdb, 0xc9, 0x95, 0xdd}};
const Challenge emptyResponse = {{0x49, 0x1e, 0x89, 0x0d, 0xe9, 0xac, 0xe9, 0x32,
                                  0x83, 0x8a, 0x49, 0x79, 0x2f, 0x22, 0x13, 0xf3}};
const std::vector<uint8_t> obfuscatedPassword =
  {0xdb, 0xd8, 0x3c, 0xfd, 0x72, 0x7a, 0x14, 0x58};

Challenge response(const d3des_ctx& context)
{
  Challenge result = challenge;
  d3des_transform(&context, result.data(), result.data());
  d3des_transform(&context, result.data() + 8, result.data() + 8);
  return result;
}

} // namespace

TEST(D3DES, KnownAnswer)
{
  d3des_ctx context;
  Block result;
  d3des_set_key(&context, knownKey.data(), EN0);
  d3des_transform(&context, plaintext.data(), result.data());
  EXPECT_EQ(ciphertext, result);
}

TEST(D3DES, DecryptInPlace)
{
  d3des_ctx context;
  Block result = ciphertext;
  d3des_set_key(&context, knownKey.data(), DE1);
  d3des_transform(&context, result.data(), result.data());
  EXPECT_EQ(plaintext, result);
}

TEST(D3DES, InterleavedContextsKeepIndependentSchedules)
{
  d3des_ctx first, second;
  d3des_set_key(&first, passwordKey.data(), EN0);
  d3des_set_key(&second, secretKey.data(), EN0);

  // The old process-global register would use the second key for both calls.
  EXPECT_EQ(passwordResponse, response(first));
  EXPECT_EQ(secretResponse, response(second));

  // Re-keying one context (including direction) must not change another.
  d3des_set_key(&second, passwordKey.data(), DE1);
  EXPECT_EQ(passwordResponse, response(first));
  Challenge decrypted = passwordResponse;
  d3des_transform(&second, decrypted.data(), decrypted.data());
  d3des_transform(&second, decrypted.data() + 8, decrypted.data() + 8);
  EXPECT_EQ(challenge, decrypted);
}

TEST(D3DES, EmptyPasswordResponse)
{
  const Block empty = {};
  d3des_ctx context;
  d3des_set_key(&context, empty.data(), EN0);
  EXPECT_EQ(emptyResponse, response(context));
}

TEST(D3DES, PasswordFileCompatibility)
{
  EXPECT_EQ(obfuscatedPassword, rfb::obfuscate("password"));
  EXPECT_EQ(obfuscatedPassword, rfb::obfuscate("password-truncated"));
  EXPECT_EQ("password", rfb::deobfuscate(obfuscatedPassword.data(), 8));
  for (const char* password : {"", "s", "secret", "12345678"}) {
    auto bytes = rfb::obfuscate(password);
    EXPECT_EQ(password, rfb::deobfuscate(bytes.data(), bytes.size()));
  }
  EXPECT_THROW(rfb::deobfuscate(obfuscatedPassword.data(), 7), std::invalid_argument);
  EXPECT_THROW(rfb::deobfuscate(obfuscatedPassword.data(), 9), std::invalid_argument);
}

TEST(D3DES, ConcurrentAuthenticationAndPasswordFiles)
{
  std::atomic<bool> start(false), failed(false);
  std::vector<std::thread> workers;
  for (int worker = 0; worker < 4; ++worker) {
    workers.emplace_back([&, worker] {
      while (!start.load())
        std::this_thread::yield();
      for (int i = 0; i < 1000; ++i) {
        d3des_ctx context;
        const bool usePassword = worker % 2 == 0;
        d3des_set_key(&context, (usePassword ? passwordKey : secretKey).data(), EN0);
        // Deliberately run the other DES consumers between keying and use.
        auto bytes = rfb::obfuscate("password");
        auto decoded = rfb::deobfuscate(obfuscatedPassword.data(), 8);
        std::this_thread::yield();
        if (bytes != obfuscatedPassword || decoded != "password" ||
            response(context) != (usePassword ? passwordResponse : secretResponse))
          failed.store(true);
      }
    });
  }
  start.store(true);
  for (auto& worker : workers)
    worker.join();
  EXPECT_FALSE(failed.load());
}
