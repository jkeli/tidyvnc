/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include "CertificatePolicy.h"
#ifdef HAVE_GNUTLS
#include <gnutls/gnutls.h>
#endif
namespace viewer {
namespace {
struct Reason { uint32_t status, reason; bool overridable; };
// GnuTLS verification status values are also present in retained prompt metadata.
// Keep this classifier available for non-TLS builds/consumers without linking TLS.
const Reason mapping[] = {
  {1u << 1, CertificateInvalid, true}, {1u << 5, CertificateRevoked, false},
  {1u << 6, CertificateUnknownIssuer, true}, {1u << 7, CertificateSignerNotCA, true},
  {1u << 8, CertificateWeakAlgorithm, true}, {1u << 9, CertificateNotYetValid, true},
  {1u << 10, CertificateExpired, true}, {1u << 11, CertificateBadSignature, false},
  {1u << 12, CertificateOldRevocationData, false}, {1u << 14, CertificateWrongOwner, true},
  {1u << 15, CertificateFutureRevocationData, false}, {1u << 16, CertificateSignerConstraints, false},
  {1u << 17, CertificateMismatch, false}, {1u << 18, CertificateWrongPurpose, false},
  {1u << 19, CertificateMissingOCSP, false}, {1u << 20, CertificateInvalidOCSP, false},
  {1u << 21, CertificateCriticalExtension, false}
};
#ifdef HAVE_GNUTLS
// These are the same constants required by the retained CConn implementation.
static_assert(GNUTLS_CERT_INVALID == (1u << 1) &&
  GNUTLS_CERT_SIGNER_NOT_FOUND == (1u << 6) && GNUTLS_CERT_SIGNER_NOT_CA == (1u << 7) &&
  GNUTLS_CERT_INSECURE_ALGORITHM == (1u << 8) && GNUTLS_CERT_NOT_ACTIVATED == (1u << 9) &&
  GNUTLS_CERT_EXPIRED == (1u << 10) && GNUTLS_CERT_UNEXPECTED_OWNER == (1u << 14),
  "Certificate exception mask changed");
// Do not require newer diagnostic enum names on older supported TLS headers.
#if GNUTLS_VERSION_NUMBER >= 0x030800
static_assert(GNUTLS_CERT_REVOKED == (1u << 5) && GNUTLS_CERT_SIGNATURE_FAILURE == (1u << 11) &&
  GNUTLS_CERT_REVOCATION_DATA_SUPERSEDED == (1u << 12) &&
  GNUTLS_CERT_REVOCATION_DATA_ISSUED_IN_FUTURE == (1u << 15) && GNUTLS_CERT_SIGNER_CONSTRAINTS_FAILURE == (1u << 16) &&
  GNUTLS_CERT_MISMATCH == (1u << 17) && GNUTLS_CERT_PURPOSE_MISMATCH == (1u << 18) &&
  GNUTLS_CERT_MISSING_OCSP_STATUS == (1u << 19) && GNUTLS_CERT_INVALID_OCSP_STATUS == (1u << 20) &&
  GNUTLS_CERT_UNKNOWN_CRIT_EXTENSIONS == (1u << 21), "Certificate diagnostic mapping changed");
#endif
#endif
}
CertificatePolicy certificatePolicy(uint32_t status) noexcept {
  CertificatePolicy result;
  uint32_t known = 0, allowed = 0;
  for (const auto& item : mapping) {
    known |= item.status;
    if (item.overridable) allowed |= item.status;
    if (status & item.status) result.reasons |= item.reason;
  }
  if (status & ~known) result.reasons |= CertificateUnknownProblem;
  if (!status) result.reasons |= CertificateMissingProblem;
  result.fatalStatus = status & ~allowed;
  result.mayOverride = status && !result.fatalStatus;
  return result;
}
}
