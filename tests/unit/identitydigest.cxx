/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// IdentityDigest (plans/native-ui-winui TODO W2.3): the internal SHA-256
// against FIPS 180-4 / NIST vectors, and the shared conformance corpus
// (tests/conformance/identity-digest.json) through tidyvnc_identity_digest.
#include <tidyvnc.h>

#include <cstring>
#include <map>
#include <string>

#include <gtest/gtest.h>

#include <viewer/core/IdentityDigest.h>

#include "conformance-json.h"

namespace {

std::string digest(const std::string& input)
{
  viewer::Sha256 hash;
  hash.update(input);
  return viewer::Sha256::hex(hash.finish());
}

tidyvnc_bytes bytes(const std::string& text) { return {reinterpret_cast<const uint8_t*>(text.data()), text.size()}; }

template <class T> T init()
{
  T value{};
  value.size = sizeof(T);
  value.version = TIDYVNC_ABI_VERSION;
  return value;
}

const std::map<std::string, uint32_t> kinds = {
  {"credential", TIDYVNC_IDENTITY_CREDENTIAL}, {"trustCertificate", TIDYVNC_IDENTITY_TRUST_CERTIFICATE},
  {"trustHostKey", TIDYVNC_IDENTITY_TRUST_HOST_KEY}, {"sshRoute", TIDYVNC_IDENTITY_SSH_ROUTE},
  {"sshIntent", TIDYVNC_IDENTITY_SSH_INTENT}, {"sshResolved", TIDYVNC_IDENTITY_SSH_RESOLVED}};
const std::map<std::string, uint32_t> reasons = {
  {"tooLong", TIDYVNC_IDENTITY_TOO_LONG}, {"invalidText", TIDYVNC_IDENTITY_INVALID_TEXT},
  {"invalidEndpoint", TIDYVNC_IDENTITY_INVALID_ENDPOINT}, {"invalidAuthentication", TIDYVNC_IDENTITY_INVALID_AUTHENTICATION},
  {"unexpectedUsername", TIDYVNC_IDENTITY_UNEXPECTED_USERNAME}, {"invalidGateway", TIDYVNC_IDENTITY_INVALID_GATEWAY},
  {"invalidAlias", TIDYVNC_IDENTITY_INVALID_ALIAS}};

} // namespace

TEST(IdentityDigest, Sha256MatchesFipsVectors)
{
  EXPECT_EQ("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", digest(""));
  EXPECT_EQ("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", digest("abc"));
  EXPECT_EQ("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
            digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"));
  EXPECT_EQ("cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
            digest("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"));
  // One million 'a', fed in uneven pieces across block boundaries.
  viewer::Sha256 hash;
  const std::string chunk(997, 'a');
  size_t fed = 0;
  while (fed + chunk.size() <= 1000000) { hash.update(chunk); fed += chunk.size(); }
  hash.update(std::string(1000000 - fed, 'a'));
  EXPECT_EQ("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", viewer::Sha256::hex(hash.finish()));
  // Padding edges: 55, 56 and 64 bytes.
  EXPECT_EQ("9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318", digest(std::string(55, 'a')));
  EXPECT_EQ("b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a", digest(std::string(56, 'a')));
  EXPECT_EQ("ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb", digest(std::string(64, 'a')));
}

TEST(IdentityDigest, AdvertisedAndValidatesStructures)
{
  auto abi = init<tidyvnc_abi_info>();
  ASSERT_EQ(TIDYVNC_OK, tidyvnc_get_abi(&abi, nullptr));
  EXPECT_NE(0u, abi.features & TIDYVNC_FEATURE_IDENTITY_DIGEST);

  auto request = init<tidyvnc_identity_request>();
  auto out = init<tidyvnc_identity>();
  auto error = init<tidyvnc_error>();
  request.kind = 99;
  std::memset(out.text, 'x', sizeof(out.text));
  EXPECT_EQ(TIDYVNC_INVALID_ARGUMENT, tidyvnc_identity_digest(&request, &out, &error));
  EXPECT_EQ(TIDYVNC_DOMAIN_IDENTITY, error.domain);
  EXPECT_EQ(static_cast<uint32_t>(TIDYVNC_IDENTITY_INVALID_KIND), error.detail);
  EXPECT_EQ('x', out.text[0]); // Untouched on failure.
  EXPECT_EQ(TIDYVNC_INVALID_ARGUMENT, tidyvnc_identity_digest(nullptr, &out, nullptr));
  EXPECT_EQ(TIDYVNC_INVALID_ARGUMENT, tidyvnc_identity_digest(&request, nullptr, nullptr));
  request.kind = TIDYVNC_IDENTITY_TRUST_CERTIFICATE;
  const std::string endpoint = "HOST:1";
  request.endpoint = bytes(endpoint);
  request.version = TIDYVNC_ABI_VERSION + 1;
  EXPECT_EQ(TIDYVNC_ABI_MISMATCH, tidyvnc_identity_digest(&request, &out, nullptr));
  request.version = TIDYVNC_ABI_VERSION;
  request.endpoint = {nullptr, 3};
  EXPECT_EQ(TIDYVNC_INVALID_ARGUMENT, tidyvnc_identity_digest(&request, &out, nullptr));
  request.endpoint = bytes(endpoint);
  ASSERT_EQ(TIDYVNC_OK, tidyvnc_identity_digest(&request, &out, nullptr));
  EXPECT_STREQ("v1:c0f8fafc6b5249a1e7119d3a3594523a5947e50d04d78ec64be2ec1192f0d047", out.text);
  // No input text survives in the identity.
  EXPECT_EQ(nullptr, std::strstr(out.text, "host"));
}

TEST(IdentityDigest, SharedConformanceCorpus)
{
  const auto corpus = conformance::load(std::string(TIDYVNC_CONFORMANCE_DIR) + "/identity-digest.json");
  ASSERT_EQ("IdentityDigest", corpus["module"].string());
  std::map<std::string, std::string> results;
  size_t expected = 0, relations = 0, errors = 0;
  for (const auto& entry : corpus["cases"].items) {
    const auto name = entry["name"].string();
    SCOPED_TRACE(name);
    auto request = init<tidyvnc_identity_request>();
    const auto kind = entry["kind"].string();
    ASSERT_TRUE(kinds.count(kind)) << kind;
    request.kind = kinds.at(kind);
    const auto endpoint = kind == "sshRoute" || kind == "sshIntent" ? conformance::text(entry, "gateway", "")
                        : kind == "sshResolved" ? conformance::text(entry, "host", "")
                        : conformance::text(entry, "endpoint", "");
    const auto route = conformance::text(entry, "route", "");
    const auto username = conformance::text(entry, "username", "");
    const auto alias = conformance::text(entry, "alias", "");
    request.endpoint = bytes(endpoint); request.route = bytes(route);
    request.username = bytes(username); request.host_key_alias = bytes(alias);
    request.allow_unix_sockets = entry.flag("allowUnixSockets", true) ? 1 : 0;
    request.security_type = entry.u32("securityType", 0);
    const auto shape = entry.string("shape", "");
    request.shape = shape == "passwordOnly" ? TIDYVNC_IDENTITY_PASSWORD_ONLY : shape == "usernamePassword" ? TIDYVNC_IDENTITY_USERNAME_PASSWORD : 0;
    request.port = entry.u32("port", 22);

    auto out = init<tidyvnc_identity>();
    auto error = init<tidyvnc_error>();
    const auto status = tidyvnc_identity_digest(&request, &out, &error);
    if (entry.has("error")) {
      const auto reason = entry["error"].string();
      ASSERT_TRUE(reasons.count(reason)) << reason;
      EXPECT_NE(TIDYVNC_OK, status);
      EXPECT_EQ(TIDYVNC_DOMAIN_IDENTITY, error.domain);
      EXPECT_EQ(reasons.at(reason), error.detail);
      EXPECT_EQ(reason == "tooLong" ? TIDYVNC_RESOURCE_LIMIT : TIDYVNC_INVALID_ARGUMENT, status);
      ++errors;
      continue;
    }
    ASSERT_EQ(TIDYVNC_OK, status) << error.message;
    const std::string value = out.text;
    ASSERT_FALSE(results.count(name)) << "duplicate case name";
    results[name] = value;
    if (entry.has("expect")) { EXPECT_EQ(entry["expect"].string(), value); ++expected; }
    if (entry.has("sameAs")) {
      ASSERT_TRUE(results.count(entry["sameAs"].string()));
      EXPECT_EQ(results.at(entry["sameAs"].string()), value); ++relations;
    }
    if (entry.has("differsFrom")) {
      ASSERT_TRUE(results.count(entry["differsFrom"].string()));
      EXPECT_NE(results.at(entry["differsFrom"].string()), value); ++relations;
    }
  }
  EXPECT_GE(expected, 15u);
  EXPECT_GE(relations, 20u);
  EXPECT_GE(errors, 15u);
}
