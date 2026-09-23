/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/SSHGateway.h>
#include <stdexcept>
#include <string>

using namespace viewer;

TEST(SSHGateway, DecimalPortIsStrict)
{
  uint32_t port = 7;
  EXPECT_TRUE(parseDecimalPort("0", port)); EXPECT_EQ(port, 0u);
  EXPECT_TRUE(parseDecimalPort("05500", port)); EXPECT_EQ(port, 5500u);
  EXPECT_TRUE(parseDecimalPort("65535", port)); EXPECT_EQ(port, 65535u);
  for (const auto* bad : {"", "65536", "+1", "-1", " 1", "1 ", "0x10", "99999999999999999999"}) {
    port = 7;
    EXPECT_FALSE(parseDecimalPort(bad, port)) << bad;
    EXPECT_EQ(port, 7u);
  }
}

TEST(SSHGateway, CanonicalFormsAndPortIntent)
{
  const auto plain = SSHGateway::parse("alice@GATEWAY.invalid");
  EXPECT_TRUE(plain.hasUser); EXPECT_EQ(plain.user, "alice");
  EXPECT_EQ(plain.host, "gateway.invalid"); EXPECT_EQ(plain.port, 22u); EXPECT_FALSE(plain.portIsExplicit);
  EXPECT_EQ(plain.canonicalURI, "ssh://alice@gateway.invalid");
  const auto explicitPort = SSHGateway::parse("ssh://gateway.invalid:22");
  EXPECT_FALSE(explicitPort.hasUser); EXPECT_TRUE(explicitPort.portIsExplicit);
  EXPECT_EQ(explicitPort.canonicalURI, "ssh://gateway.invalid:22");
  const auto scoped = SSHGateway::parse("ssh://alice@[fe80::1%en0]:2222");
  EXPECT_EQ(scoped.host, "fe80::1"); EXPECT_EQ(scoped.scope, "en0"); EXPECT_EQ(scoped.port, 2222u);
  EXPECT_EQ(scoped.canonicalURI, "ssh://alice@[fe80::1%en0]:2222");
  const auto ipv6 = SSHGateway::parse("[::1]");
  EXPECT_EQ(ipv6.canonicalURI, "ssh://[::1]");
  for (const auto* text : {"alice@GATEWAY.invalid", "ssh://gateway.invalid:2222", "ssh://alice@[fe80::1%en0]:22", "[::1]"}) {
    const auto first = SSHGateway::parse(text);
    const auto again = SSHGateway::parse(first.canonicalURI);
    EXPECT_EQ(again.canonicalURI, first.canonicalURI) << text;
  }
}

TEST(SSHGateway, BoundsAndRejectedSyntax)
{
  const auto maximum = SSHGateway::parse(std::string(4090, 'a'));
  EXPECT_EQ(maximum.canonicalURI.size(), 4096u);
  EXPECT_THROW(SSHGateway::parse(std::string(4091, 'a')), std::invalid_argument); // canonical form too long
  EXPECT_THROW(SSHGateway::parse(std::string(4097, 'a')), std::invalid_argument);
  EXPECT_NO_THROW(SSHGateway::parse(std::string(255, 'u') + "@host"));
  EXPECT_THROW(SSHGateway::parse(std::string(256, 'u') + "@host"), std::invalid_argument);
  for (const auto* bad : {"", "gateway:2222", "a@b@host", "@host", "us er@host", "user:password@host",
                          "ssh://host:0", "ssh://host:65536", "ssh://host:", "ssh://h:1:2", "[::1]:22",
                          "ssh://[::1]x", "[::1", "-oProxyCommand=x", "host/path", "host\\\\path",
                          "ssh://", "host name", "ho$t"})
    EXPECT_THROW(SSHGateway::parse(bad), std::invalid_argument) << bad;
  EXPECT_THROW(SSHGateway::parse(std::string("ho\0st", 5)), std::invalid_argument);
}
