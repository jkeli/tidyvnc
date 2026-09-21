/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef RFB_RSAAES_KEY_H
#define RFB_RSAAES_KEY_H
#include <cstddef>
#include <cstdint>
namespace rfb {
constexpr uint32_t rsaAESMinimumBits = 1024;
constexpr uint32_t rsaAESMaximumBits = 8192;
constexpr size_t rsaAESMaximumEncoding = 4 + 2 * (rsaAESMaximumBits / 8);
// Canonical framing and public-number checks only. The protocol still performs
// Nettle key preparation and the authenticated RSA-AES exchange.
bool validRSAKeyComponents(uint32_t bits, const uint8_t* modulus,
                           const uint8_t* exponent, size_t width) noexcept;
// Returns actual modulus bits, which can differ from the byte-rounded header.
bool validRSAKeyEncoding(const uint8_t* key, size_t length,
                        uint32_t* bits = nullptr) noexcept;
}
#endif
