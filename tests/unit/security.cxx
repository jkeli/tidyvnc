/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */

#include <gtest/gtest.h>
#include <rfb/Security.h>

#include <atomic>
#include <thread>
#include <vector>

TEST(Security, SerializationPreservesOrderAndSkipsUnknownTypes)
{
  rfb::Security policy;
  EXPECT_EQ(policy.ToString(), "");
  policy.EnableSecType(0xffffffff);
  EXPECT_EQ(policy.ToString(), "");
  policy.EnableSecType(rfb::secTypeX509Plain);
  policy.EnableSecType(rfb::secTypeNone);
  policy.EnableSecType(rfb::secTypeInvalid);
  policy.EnableSecType(rfb::secTypeVncAuth);
  policy.EnableSecType(rfb::secTypeNone);
  EXPECT_EQ(policy.ToString(), "X509Plain,None,VncAuth");
}

TEST(Security, SerializationHasNoFixedCapacity)
{
  // The complete recognized vocabulary exceeds the former 128-byte buffer.
  // Serialization is independent of compiled authentication implementations.
  const std::vector<uint32_t> types = {
    rfb::secTypeNone, rfb::secTypeVncAuth, rfb::secTypeTight,
    rfb::secTypeRA2, rfb::secTypeRA2ne, rfb::secTypeRA256, rfb::secTypeRAne256,
    rfb::secTypeSSPI, rfb::secTypeSSPIne, rfb::secTypeVeNCrypt,
    rfb::secTypeDH, rfb::secTypeMSLogonII, rfb::secTypePlain,
    rfb::secTypeTLSNone, rfb::secTypeTLSVnc, rfb::secTypeTLSPlain,
    rfb::secTypeX509None, rfb::secTypeX509Vnc, rfb::secTypeX509Plain
  };
  const std::string expected =
    "None,VncAuth,Tight,RA2,RA2ne,RA2_256,RA2ne_256,SSPI,SSPIne,VeNCrypt,"
    "DH,MSLogonII,Plain,TLSNone,TLSVnc,TLSPlain,X509None,X509Vnc,X509Plain";
  ASSERT_GT(expected.size(), 127u);
  rfb::Security policy;
  for (uint32_t type : types)
    policy.EnableSecType(type);
  EXPECT_EQ(policy.ToString(), expected);

  // Verify the serialized names can still be used by configuration consumers.
  size_t start = 0;
  for (uint32_t type : types) {
    const size_t end = expected.find(',', start);
    EXPECT_EQ(rfb::secTypeNum(expected.substr(start, end - start).c_str()), type);
    start = end + 1;
  }
}

TEST(Security, SerializedValuesSurviveOtherCallsMutationAndDestruction)
{
  std::string saved;
  {
    rfb::Security first, second;
    first.EnableSecType(rfb::secTypeVncAuth);
    second.EnableSecType(rfb::secTypeX509Plain);
    auto original = first.ToString();
    EXPECT_EQ(second.ToString(), "X509Plain");
    first.DisableSecType(rfb::secTypeVncAuth);
    first.EnableSecType(rfb::secTypeNone);
    EXPECT_EQ(first.ToString(), "None");
    EXPECT_EQ(original, "VncAuth");
    saved = std::move(original);
  }
  EXPECT_EQ(saved, "VncAuth");
}

TEST(Security, ConcurrentSerializationUsesOwnedStorage)
{
  rfb::Security first, second;
  first.EnableSecType(rfb::secTypeNone);
  second.EnableSecType(rfb::secTypeX509Plain);
  second.EnableSecType(rfb::secTypeTLSVnc);
  std::atomic<bool> failed{false};
  auto run = [&](const rfb::Security& policy, const char* expected) {
    for (int i = 0; i < 10000; ++i) {
      auto text = policy.ToString();
      std::this_thread::yield();
      if (text != expected)
        failed = true;
    }
  };
  std::thread a(run, std::cref(first), "None");
  std::thread b(run, std::cref(second), "X509Plain,TLSVnc");
  std::thread c(run, std::cref(first), "None");
  a.join();
  b.join();
  c.join();
  EXPECT_FALSE(failed);
}
