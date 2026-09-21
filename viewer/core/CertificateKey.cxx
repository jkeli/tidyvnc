/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include "CertificateKey.h"
#include <exception>
#include <stdexcept>
#ifdef HAVE_GNUTLS
#include <gnutls/gnutls.h>
#include <gnutls/crypto.h>
#endif
namespace viewer {
#ifdef HAVE_GNUTLS
namespace {
struct TLS {
  TLS() { if (gnutls_global_init() < 0) throw std::runtime_error("TLS initialization failed"); }
  ~TLS() { gnutls_global_deinit(); }
};
struct Capture {
  std::vector<uint8_t> bytes;
  std::exception_ptr failure;
};
// GnuTLS documents db_name as the private context for a custom backend. No
// callback exceptions cross C. A private per-call backend avoids global state.
int capture(const char* context, const char*, const char*, const gnutls_datum_t* key) noexcept {
  auto& result = *reinterpret_cast<Capture*>(const_cast<char*>(context));
  try {
    if (!key || !key->data || !key->size || key->size > 65536) throw std::invalid_argument("Invalid certificate public key");
    result.bytes.assign(key->data,key->data+key->size);
  } catch (...) { result.failure = std::current_exception(); }
  return 0;
}
}
#endif
bool CertificateKey::supported() noexcept {
#ifdef HAVE_GNUTLS
  return true;
#else
  return false;
#endif
}
CertificateKey::CertificateKey(const uint8_t* certificate, size_t length) {
  if (!certificate || !length || length > 65536) throw std::invalid_argument("Invalid certificate size");
#ifdef HAVE_GNUTLS
  TLS tls; Capture context;
  gnutls_tdb_t database = nullptr;
  if (gnutls_tdb_init(&database) < 0) throw std::runtime_error("Trust backend initialization failed");
  struct Owner { gnutls_tdb_t value; ~Owner() { gnutls_tdb_deinit(value); } } owner{database};
  gnutls_tdb_set_verify_func(database,capture);
  gnutls_datum_t input{const_cast<unsigned char*>(certificate),static_cast<unsigned>(length)};
  const auto status = gnutls_verify_stored_pubkey(reinterpret_cast<const char*>(&context),database,
    nullptr,nullptr,GNUTLS_CRT_X509,&input,0);
  if (context.failure) std::rethrow_exception(context.failure);
  if (status < 0 || context.bytes.empty()) throw std::invalid_argument("Invalid certificate public key");
  value = std::move(context.bytes);
#else
  throw std::logic_error("Certificate keys unavailable");
#endif
}
std::vector<uint8_t> CertificateKey::digest(uint32_t algorithm) const {
#ifdef HAVE_GNUTLS
  TLS tls;
  bool known = false;
  for (const auto* type = gnutls_digest_list(); type && *type; ++type)
    if (static_cast<uint32_t>(*type) == algorithm) { known = true; break; }
  if (!known) throw std::invalid_argument("Unsupported key digest");
  const auto type = static_cast<gnutls_digest_algorithm_t>(algorithm);
  const auto size = gnutls_hash_get_len(type);
  if (!size || size > 64) throw std::invalid_argument("Unsupported key digest");
  std::vector<uint8_t> result(size);
  if (gnutls_hash_fast(type,value.data(),value.size(),result.data()) < 0)
    throw std::invalid_argument("Unsupported key digest");
  return result;
#else
  (void)algorithm;
  throw std::logic_error("Certificate keys unavailable");
#endif
}
}
