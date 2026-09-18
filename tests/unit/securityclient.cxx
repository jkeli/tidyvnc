/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include <gtest/gtest.h>

#include <rfb/CConnection.h>
#include <rfb/Exception.h>
#include <rfb/SecurityClient.h>
#include <rdr/MemInStream.h>
#include <rdr/MemOutStream.h>

#include <atomic>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {

class TestConnection : public rfb::CConnection {
public:
  TestConnection() = default;
  explicit TestConnection(const rfb::SecurityClient& policy) : CConnection(policy) {}
  void getUserPasswd(bool, std::string*, std::string*) override
  { throw std::logic_error("Unexpected credential request during type selection"); }
  bool verifyCertificate(unsigned int, const uint8_t*, size_t) override { return false; }
  bool verifyHostKey(const uint8_t*, size_t, const char*) override { return false; }
  void initDone() override {}
  void bell() override {}
};

class LegacyPolicyGuard {
public:
  LegacyPolicyGuard() : saved(rfb::SecurityClient::secTypes.getValueStr()) {}
  ~LegacyPolicyGuard() { rfb::SecurityClient::secTypes.setParam(saved.c_str()); }
private:
  std::string saved;
};

// Drive the real protocol version and security-type negotiation. Close while
// streams are still alive, including on rejection. No authentication is faked.
std::vector<uint8_t> negotiate(TestConnection& connection,
                               const std::vector<uint8_t>& offered,
                               bool version33 = false)
{
  const char* version = version33 ? "RFB 003.003\n" : "RFB 003.008\n";
  std::vector<uint8_t> wire(version, version + 12);
  if (version33) {
    wire.insert(wire.end(), {0, 0, 0, offered.at(0)});
  } else {
    wire.push_back(offered.size());
    wire.insert(wire.end(), offered.begin(), offered.end());
  }
  rdr::MemInStream input(wire.data(), wire.size());
  rdr::MemOutStream output;
  connection.setStreams(&input, &output);
  connection.initialiseProtocol();
  try {
    if (!connection.processMsg() || !connection.processMsg())
      throw std::logic_error("Incomplete negotiation fixture");
  } catch (...) {
    connection.close();
    throw;
  }
  connection.close();
  return {output.data(), output.data() + output.length()};
}

} // namespace

TEST(SecurityClient, ExplicitPolicyCopiesAndDeduplicates)
{
  std::list<uint32_t> types = {rfb::secTypeVncAuth, rfb::secTypePlain, rfb::secTypeVncAuth};
  rfb::SecurityClient policy(types);
  types.clear();
  EXPECT_EQ((std::list<uint32_t>{rfb::secTypeVncAuth, rfb::secTypePlain}),
            policy.GetEnabledExtSecTypes());
  EXPECT_EQ((std::list<uint8_t>{rfb::secTypeVeNCrypt, rfb::secTypeVncAuth}),
            policy.GetEnabledSecTypes());
}

TEST(SecurityClient, RejectsUnsupportedExplicitTypes)
{
  for (uint32_t type : {uint32_t(rfb::secTypeInvalid), uint32_t(rfb::secTypeVeNCrypt),
                        uint32_t(rfb::secTypeTight), uint32_t(0xffffffff)})
    EXPECT_THROW(rfb::SecurityClient(std::list<uint32_t>{type}), std::invalid_argument);
#ifndef HAVE_GNUTLS
  EXPECT_THROW(rfb::SecurityClient(std::list<uint32_t>{rfb::secTypeTLSVnc}), std::invalid_argument);
#endif
#ifndef HAVE_NETTLE
  EXPECT_THROW(rfb::SecurityClient(std::list<uint32_t>{rfb::secTypeRA2}), std::invalid_argument);
#endif
  for (uint32_t type : rfb::SecurityClient::supportedTypes())
    EXPECT_NO_THROW(rfb::SecurityClient(std::list<uint32_t>{type}));
}

TEST(SecurityClient, RejectsEmbeddedNullInTLSOptions)
{
  for (int field = 0; field < 3; ++field) {
    rfb::ClientTLSOptions options;
    std::string* value = field == 0 ? &options.priority : field == 1 ? &options.caFile : &options.crlFile;
    *value = std::string("prefix\0suffix", 13);
    EXPECT_THROW(rfb::SecurityClient(std::list<uint32_t>{rfb::secTypeVncAuth}, options),
                 std::invalid_argument);
  }
}

TEST(SecurityClient, CompiledCapabilitiesAreIndependentOfLegacyPolicy)
{
  LegacyPolicyGuard restore;
  ASSERT_TRUE(rfb::SecurityClient::secTypes.setParam(
    rfb::SecurityClient::secTypes.getDefaultStr().c_str()));
  rfb::SecurityClient defaults;
  EXPECT_EQ(defaults.GetEnabledExtSecTypes(), rfb::SecurityClient::supportedTypes());
  const auto supported = rfb::SecurityClient::supportedTypes();
  ASSERT_TRUE(rfb::SecurityClient::secTypes.setParam("None"));
  EXPECT_EQ(supported, rfb::SecurityClient::supportedTypes());
}

TEST(SecurityClient, ConnectionsSnapshotExplicitAndLegacyPolicies)
{
  LegacyPolicyGuard restore;
  ASSERT_TRUE(rfb::SecurityClient::secTypes.setParam("None"));
  TestConnection legacy;
  rfb::SecurityClient policy(std::list<uint32_t>{rfb::secTypeVncAuth});
  TestConnection explicitPolicy(policy);
  policy.DisableSecType(rfb::secTypeVncAuth);
  policy.EnableSecType(rfb::secTypeNone);
  ASSERT_TRUE(rfb::SecurityClient::secTypes.setParam("Plain"));
  auto first = negotiate(legacy, {rfb::secTypeNone, rfb::secTypeVncAuth});
  auto second = negotiate(explicitPolicy, {rfb::secTypeNone, rfb::secTypeVncAuth});
  ASSERT_EQ(13u, first.size());
  ASSERT_EQ(13u, second.size());
  EXPECT_EQ(rfb::secTypeNone, first.back());
  EXPECT_EQ(rfb::secTypeVncAuth, second.back());
  EXPECT_EQ("Plain", rfb::SecurityClient::secTypes.getValueStr());
}

TEST(SecurityClient, ServerPreferenceOrderIsPreserved)
{
  rfb::SecurityClient policy(std::list<uint32_t>{rfb::secTypeVncAuth, rfb::secTypeNone});
  TestConnection connection(policy);
  auto bytes = negotiate(connection, {rfb::secTypeNone, rfb::secTypeVncAuth});
  ASSERT_EQ(13u, bytes.size());
  EXPECT_EQ(rfb::secTypeNone, bytes.back());
}

TEST(SecurityClient, EmptyPolicyDoesNotFallBackToDefaults)
{
  rfb::SecurityClient policy(std::list<uint32_t>{});
  TestConnection connection(policy);
  EXPECT_THROW(negotiate(connection, {rfb::secTypeNone, rfb::secTypeVncAuth,
                                      rfb::secTypeVeNCrypt}), rfb::protocol_error);
}

TEST(SecurityClient, Version33HonoursExplicitPolicy)
{
  rfb::SecurityClient policy(std::list<uint32_t>{rfb::secTypeVncAuth});
  TestConnection accepted(policy), rejected(policy);
  EXPECT_EQ(12u, negotiate(accepted, {rfb::secTypeVncAuth}, true).size());
  EXPECT_THROW(negotiate(rejected, {rfb::secTypeNone}, true), rfb::protocol_error);
}

TEST(SecurityClient, VeNCryptIsOnlyAdvertisedForConfiguredSubtypes)
{
  rfb::SecurityClient plain(std::list<uint32_t>{rfb::secTypePlain});
  rfb::SecurityClient vnc(std::list<uint32_t>{rfb::secTypeVncAuth});
  TestConnection accepted(plain), rejected(vnc);
  auto bytes = negotiate(accepted, {rfb::secTypeVeNCrypt});
  ASSERT_EQ(13u, bytes.size());
  EXPECT_EQ(rfb::secTypeVeNCrypt, bytes.back());
  EXPECT_THROW(negotiate(rejected, {rfb::secTypeVeNCrypt}), rfb::protocol_error);
}

TEST(SecurityClient, ConcurrentConnectionsChooseDifferentTypes)
{
  std::atomic<bool> failed(false);
  std::vector<std::thread> workers;
  for (int worker = 0; worker < 4; ++worker) {
    workers.emplace_back([&, worker] {
      const uint8_t type = worker % 2 ? rfb::secTypeNone : rfb::secTypeVncAuth;
      for (int i = 0; i < 50; ++i) {
        rfb::SecurityClient policy(std::list<uint32_t>{type});
        TestConnection connection(policy);
        auto bytes = negotiate(connection, {rfb::secTypeNone, rfb::secTypeVncAuth});
        if (bytes.size() != 13 || bytes.back() != type)
          failed.store(true);
      }
    });
  }
  for (auto& worker : workers)
    worker.join();
  EXPECT_FALSE(failed.load());
}
