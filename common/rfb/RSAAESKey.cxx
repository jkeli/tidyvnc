/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "RSAAESKey.h"
#include <cstring>
namespace rfb {
bool validRSAKeyComponents(uint32_t bits, const uint8_t* modulus,
                           const uint8_t* exponent, size_t width) noexcept {
  if (bits < rsaAESMinimumBits || bits > rsaAESMaximumBits ||
      width != (bits + 7) / 8 || !modulus || !exponent) return false;
  // The retained server rounds the declared bit count up to a whole byte.
  // Require a consistent byte width, not an exactly matching top-bit position.
  if (!modulus[0] || !(modulus[width-1] & 1) ||
      !(exponent[width-1] & 1) || std::memcmp(exponent,modulus,width) >= 0) return false;
  // Reject e=1 (e=0/even already rejected), without allocating large integers.
  for (size_t i=0; i+1<width; ++i) if (exponent[i]) return true;
  return exponent[width-1] > 1;
}
bool validRSAKeyEncoding(const uint8_t* key, size_t length, uint32_t* bits) noexcept {
  if (!key || length < 4 || length > rsaAESMaximumEncoding) return false;
  const uint32_t value = (uint32_t(key[0]) << 24) | (uint32_t(key[1]) << 16) |
                         (uint32_t(key[2]) << 8) | uint32_t(key[3]);
  if (value < rsaAESMinimumBits || value > rsaAESMaximumBits) return false;
  const size_t width = (value + 7) / 8;
  if (length != 4 + 2 * width || !validRSAKeyComponents(value,key+4,key+4+width,width)) return false;
  if (bits) {
    uint32_t actual = static_cast<uint32_t>((width - 1) * 8);
    for (uint8_t high = key[4]; high; high >>= 1) ++actual;
    *bits = actual;
  }
  return true;
}
}
