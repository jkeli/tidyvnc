/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/CertificateKey.h>
#include <gnutls/gnutls.h>
#include <unistd.h>
#include <fstream>
#include <iterator>
#include <thread>
#include <stdexcept>
#include "../viewer/trust-fixture.h"
namespace {
struct TemporaryFile {
  char path[64] = "/tmp/tidyvnc-certificate-key-XXXXXX";
  TemporaryFile() { int fd = mkstemp(path); if (fd < 0) throw std::runtime_error("temp file"); close(fd); }
  ~TemporaryFile() { unlink(path); }
  std::string read() { std::ifstream in(path); return {std::istreambuf_iterator<char>(in),{}}; }
};
gnutls_datum_t certificate() { return {const_cast<unsigned char*>(trust_fixture_certificate),sizeof(trust_fixture_certificate)}; }
}
TEST(CertificateKey, ExactSPKIAndDigests) {
  ASSERT_TRUE(viewer::CertificateKey::supported());
  viewer::CertificateKey key(trust_fixture_certificate,sizeof(trust_fixture_certificate));
  EXPECT_EQ(key.bytes(),std::vector<uint8_t>(std::begin(trust_fixture_spki),std::end(trust_fixture_spki)));
  EXPECT_EQ(key.digest(GNUTLS_DIG_SHA256),std::vector<uint8_t>(std::begin(trust_fixture_sha256),std::end(trust_fixture_sha256)));
  EXPECT_THROW(key.digest(UINT32_MAX),std::invalid_argument);
  EXPECT_THROW(viewer::CertificateKey(nullptr,1),std::invalid_argument);
  EXPECT_THROW(viewer::CertificateKey(trust_fixture_certificate,65537),std::invalid_argument);
  EXPECT_THROW(viewer::CertificateKey(trust_fixture_certificate,3),std::invalid_argument);
  std::vector<std::thread> threads;
  for (int i=0;i<16;++i) threads.emplace_back([&] {
    viewer::CertificateKey independent(trust_fixture_certificate,sizeof(trust_fixture_certificate));
    EXPECT_EQ(independent.bytes(),key.bytes()); EXPECT_EQ(independent.digest(6),key.digest(6));
  });
  for (auto& thread: threads) thread.join();
}
TEST(CertificateKey, GnuTLSLegacyFileCompatibility) {
  ASSERT_GE(gnutls_global_init(),0);
  struct Cleanup { ~Cleanup() { gnutls_global_deinit(); } } cleanup;
  TemporaryFile file;
  auto cert = certificate();
  ASSERT_EQ(gnutls_store_pubkey(file.path,nullptr,"fixture.invalid","5902",GNUTLS_CRT_X509,&cert,0,0),0);
  gnutls_datum_t raw{const_cast<unsigned char*>(trust_fixture_spki),sizeof(trust_fixture_spki)}, base64{};
  ASSERT_EQ(gnutls_base64_encode2(&raw,&base64),0);
  std::string expected = "|g0|fixture.invalid|5902|0|" + std::string(reinterpret_cast<char*>(base64.data),base64.size) + "\n";
  gnutls_free(base64.data);
  EXPECT_EQ(file.read(),expected);
  EXPECT_EQ(gnutls_verify_stored_pubkey(file.path,nullptr,"fixture.invalid",nullptr,GNUTLS_CRT_X509,&cert,0),0);
  EXPECT_EQ(gnutls_verify_stored_pubkey(file.path,nullptr,"FIXTURE.invalid",nullptr,GNUTLS_CRT_X509,&cert,0),GNUTLS_E_NO_CERTIFICATE_FOUND);
  TemporaryFile commitment;
  gnutls_datum_t digest{const_cast<unsigned char*>(trust_fixture_sha256),sizeof(trust_fixture_sha256)};
  ASSERT_EQ(gnutls_store_commitment(commitment.path,nullptr,"*suffix",nullptr,GNUTLS_DIG_SHA256,&digest,0,0),0);
  std::string hex; const char* digits = "0123456789abcdef";
  for (auto byte: trust_fixture_sha256) { hex += digits[byte >> 4]; hex += digits[byte & 15]; }
  EXPECT_EQ(commitment.read(),"|c0|*suffix|*|0|6|"+hex+"\n");
  EXPECT_EQ(gnutls_verify_stored_pubkey(commitment.path,nullptr,"elsewhere.invalid",nullptr,GNUTLS_CRT_X509,&cert,0),0);
}
