/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_CERTIFICATE_POLICY_H
#define TIDYVNC_CERTIFICATE_POLICY_H
#include <cstdint>
namespace viewer {
// Stable presentation reasons, independent of the TLS library's bit assignments.
enum CertificateReason : uint32_t {
  CertificateInvalid = 1u << 0, CertificateRevoked = 1u << 1,
  CertificateUnknownIssuer = 1u << 2, CertificateSignerNotCA = 1u << 3,
  CertificateWeakAlgorithm = 1u << 4, CertificateNotYetValid = 1u << 5,
  CertificateExpired = 1u << 6, CertificateBadSignature = 1u << 7,
  CertificateOldRevocationData = 1u << 8, CertificateWrongOwner = 1u << 9,
  CertificateFutureRevocationData = 1u << 10, CertificateSignerConstraints = 1u << 11,
  CertificateMismatch = 1u << 12, CertificateWrongPurpose = 1u << 13,
  CertificateMissingOCSP = 1u << 14, CertificateInvalidOCSP = 1u << 15,
  CertificateCriticalExtension = 1u << 16, CertificateUnknownProblem = 1u << 17,
  CertificateMissingProblem = 1u << 18
};
struct CertificatePolicy {
  uint32_t reasons = 0, fatalStatus = 0;
  bool mayOverride = false;
};
// Preserve CConn's existing X509 exception mask. Unknown/new status bits are
// fatal. Zero means no failed verification and cannot authorize an exception.
CertificatePolicy certificatePolicy(uint32_t verificationStatus) noexcept;
}
#endif
