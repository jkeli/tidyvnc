/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// LegacyKnownHosts (plans/native-ui-winui TODO W2.5): the shared corpus
// (tests/conformance/legacy-known-hosts.json) through the core with the
// corpus's key material, and, with GnuTLS, files GnuTLS itself wrote read
// through tidyvnc_known_hosts_lookup with a real certificate key.
#include <tidyvnc.h>

#include <cstring>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include <viewer/core/LegacyKnownHosts.h>

#include "conformance-json.h"

#ifdef TIDYVNC_KNOWN_HOSTS_GNUTLS
#include <gnutls/gnutls.h>
#include "../viewer/trust-fixture.h"
#include "test-files.h"
#endif

namespace {

std::vector<uint8_t> base64(const std::string& text)
{
  // Test helper for the corpus key only (canonical input).
  static const std::string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::vector<uint8_t> out;
  uint32_t buffer = 0;
  int bits = 0;
  for (char c : text) {
    if (c == '=') break;
    buffer = (buffer << 6) | uint32_t(alphabet.find(c));
    bits += 6;
    if (bits >= 8) { bits -= 8; out.push_back(uint8_t(buffer >> bits)); }
  }
  return out;
}

std::vector<uint8_t> hex(const std::string& text)
{
  std::vector<uint8_t> out;
  for (size_t i = 0; i + 1 < text.size(); i += 2) out.push_back(uint8_t(std::stoul(text.substr(i, 2), nullptr, 16)));
  return out;
}

const char* problemName(viewer::KnownHostsProblem problem)
{
  switch (problem) {
  case viewer::KnownHostsProblem::TooLarge: return "tooLarge";
  case viewer::KnownHostsProblem::Corrupt: return "corrupt";
  case viewer::KnownHostsProblem::UnsupportedFormat: return "unsupportedFormat";
  case viewer::KnownHostsProblem::UnsupportedDigest: return "unsupportedDigest";
  }
  return "?";
}

tidyvnc_bytes bytes(const std::string& text) { return {reinterpret_cast<const uint8_t*>(text.data()), text.size()}; }

template <class T> T init()
{
  T value{};
  value.size = sizeof(T);
  value.version = TIDYVNC_ABI_VERSION;
  return value;
}

} // namespace

TEST(LegacyKnownHosts, SharedConformanceCorpus)
{
  const auto corpus = conformance::load(std::string(TIDYVNC_CONFORMANCE_DIR) + "/legacy-known-hosts.json");
  ASSERT_EQ("LegacyKnownHosts", corpus["module"].string());
  const auto spki = base64(corpus["key"]["spki"].string());
  const auto& digests = corpus["key"]["digests"];
  const auto digest = [&digests](uint32_t algorithm) {
    const auto name = std::to_string(algorithm);
    if (!digests.has(name)) throw viewer::KnownHostsError(viewer::KnownHostsProblem::UnsupportedDigest, 0);
    return hex(digests[name].string());
  };
  size_t cases = 0;
  for (const auto& entry : corpus["cases"].items) {
    SCOPED_TRACE(entry["name"].string());
    ++cases;
    const auto file = entry["file"].type == conformance::Json::Type::Null ? std::string() : conformance::text(entry["file"]);
    const auto host = entry["host"].string();
    const uint64_t now = entry["now"].u32();
    if (entry.has("error")) {
      try {
        viewer::LegacyKnownHosts::lookup(viewer::LegacyKnownHosts::parse(file), host, spki, now, digest);
        ADD_FAILURE() << "accepted";
      } catch (const viewer::KnownHostsError& error) {
        EXPECT_STREQ(entry["error"].string().c_str(), problemName(error.problem));
      }
      continue;
    }
    const auto match = viewer::LegacyKnownHosts::lookup(viewer::LegacyKnownHosts::parse(file), host, spki, now, digest);
    const auto state = entry["state"].string();
    EXPECT_EQ(state, match.state == viewer::KnownHostsMatch::State::Match ? "match"
                     : match.state == viewer::KnownHostsMatch::State::Changed ? "changed" : "missing");
    EXPECT_EQ(entry.flag("wildcard", false), match.wildcard);
    EXPECT_EQ(entry.flag("hasMore", false), match.hasMore);
    EXPECT_EQ(corpus["received"].string(), match.received);
    const auto& expected = entry["expected"].items;
    ASSERT_EQ(expected.size(), match.expected.size());
    for (size_t i = 0; i < expected.size(); i++) {
      if (expected[i].has("spki")) {
        EXPECT_FALSE(match.expected[i].commitment);
        EXPECT_EQ(expected[i]["spki"].string(), match.expected[i].text);
      } else {
        EXPECT_TRUE(match.expected[i].commitment);
        EXPECT_EQ(expected[i]["commitment"].u32(), match.expected[i].algorithm);
        EXPECT_EQ(expected[i]["digest"].string(), match.expected[i].text);
      }
    }
  }
  EXPECT_GE(cases, 25u);
}

TEST(LegacyKnownHosts, AbiReportsLinesAndLeavesOutputOnFailure)
{
  auto abi = init<tidyvnc_abi_info>();
  ASSERT_EQ(TIDYVNC_OK, tidyvnc_get_abi(&abi, nullptr));
  EXPECT_NE(0u, abi.features & TIDYVNC_FEATURE_KNOWN_HOSTS);
  const std::string spki("\x01\x02\x03", 3), host = "fixture.invalid";
  auto out = init<tidyvnc_known_hosts_match>();
  auto error = init<tidyvnc_error>();
  ASSERT_EQ(TIDYVNC_OK, tidyvnc_known_hosts_lookup(bytes("# none\n|g0|fixture.invalid|*|0|AQID\n"), bytes(host), bytes(spki), 0, 100, &out, &error));
  EXPECT_EQ(static_cast<uint32_t>(TIDYVNC_KNOWN_HOSTS_MATCH), out.state);
  ASSERT_EQ(1u, out.count);
  EXPECT_EQ(static_cast<uint32_t>(TIDYVNC_KNOWN_HOSTS_SPKI), out.expected[0].kind);
  EXPECT_STREQ(out.received, out.expected[0].text);

  auto untouched = out;
  EXPECT_EQ(TIDYVNC_INVALID_ARGUMENT,
            tidyvnc_known_hosts_lookup(bytes("# fine\n|g0|fixture.invalid|*|0|AQID\n|g0|bad\n"), bytes(host), bytes(spki), 0, 100, &out, &error));
  EXPECT_EQ(TIDYVNC_DOMAIN_KNOWN_HOSTS, error.domain);
  EXPECT_EQ((3u << 8) | TIDYVNC_KNOWN_HOSTS_CORRUPT, error.detail);
  EXPECT_EQ(0, std::memcmp(&untouched, &out, sizeof(out)));
  // A commitment needs the certificate key.
  EXPECT_EQ(TIDYVNC_UNSUPPORTED,
            tidyvnc_known_hosts_lookup(bytes("|c0|fixture.invalid|*|0|6|00\n"), bytes(host), bytes(spki), 0, 100, &out, &error));
  EXPECT_EQ(static_cast<uint32_t>(TIDYVNC_KNOWN_HOSTS_UNSUPPORTED_DIGEST), error.detail & 0xff);
  // No key at all, and a missing file is simply missing.
  EXPECT_EQ(TIDYVNC_INVALID_ARGUMENT, tidyvnc_known_hosts_lookup(bytes(""), bytes(host), {nullptr, 0}, 0, 100, &out, nullptr));
  ASSERT_EQ(TIDYVNC_OK, tidyvnc_known_hosts_lookup({nullptr, 0}, bytes(host), bytes(spki), 0, 100, &out, nullptr));
  EXPECT_EQ(static_cast<uint32_t>(TIDYVNC_KNOWN_HOSTS_MISSING), out.state);
}

#ifdef TIDYVNC_KNOWN_HOSTS_GNUTLS
// Files written by GnuTLS (as the retained viewer does) are read identically.
TEST(LegacyKnownHosts, ReadsFilesWrittenByGnuTLS)
{
  ASSERT_GE(gnutls_global_init(), 0);
  struct Cleanup { ~Cleanup() { gnutls_global_deinit(); } } cleanup;
  const std::string certificate(reinterpret_cast<const char*>(trust_fixture_certificate), sizeof(trust_fixture_certificate));
  tidyvnc_handle key = 0;
  ASSERT_EQ(TIDYVNC_OK, tidyvnc_certificate_key_create(bytes(certificate), &key, nullptr));
  gnutls_datum_t datum{const_cast<unsigned char*>(trust_fixture_certificate), sizeof(trust_fixture_certificate)};

  testfiles::TemporaryFile stored;
  ASSERT_EQ(0, gnutls_store_pubkey(stored.path.c_str(), nullptr, "fixture.invalid", "5902", GNUTLS_CRT_X509, &datum, 0, 0));
  testfiles::TemporaryFile committed;
  gnutls_datum_t digest{const_cast<unsigned char*>(trust_fixture_sha256), sizeof(trust_fixture_sha256)};
  ASSERT_EQ(0, gnutls_store_commitment(committed.path.c_str(), nullptr, "*suffix", nullptr, GNUTLS_DIG_SHA256, &digest, 0, 0));

  for (const auto* file : {&stored, &committed}) {
    const auto text = file->read();
    for (const std::string host : {"fixture.invalid", "FIXTURE.invalid", "elsewhere.invalid"}) {
      SCOPED_TRACE(text + " " + host);
      const int legacy = gnutls_verify_stored_pubkey(file->path.c_str(), nullptr, host.c_str(), nullptr, GNUTLS_CRT_X509, &datum, 0);
      auto out = init<tidyvnc_known_hosts_match>();
      ASSERT_EQ(TIDYVNC_OK, tidyvnc_known_hosts_lookup(bytes(text), bytes(host), {nullptr, 0}, key, 100, &out, nullptr));
      EXPECT_EQ(legacy == 0, out.state == TIDYVNC_KNOWN_HOSTS_MATCH);
    }
  }
  EXPECT_EQ(TIDYVNC_OK, tidyvnc_release(key, nullptr));
}
#endif
