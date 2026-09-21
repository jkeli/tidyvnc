/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_CERTIFICATE_KEY_H
#define TIDYVNC_CERTIFICATE_KEY_H
#include <cstddef>
#include <cstdint>
#include <vector>
namespace viewer {
// Exact DER SPKI bytes used by GnuTLS's stored-public-key API, not a certificate
// fingerprint or a platform-specific SecKey encoding. No filesystem access.
class CertificateKey {
public:
  static bool supported() noexcept;
  CertificateKey(const uint8_t* certificate, size_t length);
  const std::vector<uint8_t>& bytes() const noexcept { return value; }
  std::vector<uint8_t> digest(uint32_t algorithm) const;
private:
  std::vector<uint8_t> value;
};
}
#endif
