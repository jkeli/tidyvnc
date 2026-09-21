/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/core/Endpoint.h>
#include <network/HostPort.h>
#include <network/TcpSocket.h>
#include <gtest/gtest.h>
#include <future>
#include <vector>

using viewer::Endpoint;
using viewer::EndpointError;
using viewer::EndpointErrorCode;
using viewer::EndpointTransport;

namespace {
void expectError(const std::string& input, EndpointErrorCode code)
{
  try {
    Endpoint::parse(input);
    FAIL() << "Accepted invalid endpoint";
  } catch (const EndpointError& error) {
    EXPECT_EQ(error.code, code);
    // Diagnostics must not embed input (possibly pasted secrets).
    EXPECT_STREQ(error.what(), "Invalid endpoint");
  }
}
}

TEST(Endpoint, PreservesLegacySyntax)
{
  struct Fixture { const char* text; const char* host; uint16_t port; };
  const Fixture fixtures[] = {
    {"", "localhost", 5900}, {" \t\r\n", "localhost", 5900},
    {":0", "localhost", 5900}, {":99", "localhost", 5999},
    {"::1", "localhost", 1}, {"[]:1", "localhost", 5901},
    {"2001::1", "2001", 1},
    {"host", "host", 5900}, {"host:5", "host", 5905},
    {"host:100", "host", 100}, {"host:5900", "host", 5900},
    {"host::99", "host", 99}, {"host::65535", "host", 65535},
    {"host: +005 ", "host", 5905}, {"host:: +005 ", "host", 5},
    {"  host \t:1 \n", "host", 5901},
    {" [host]::1 ", "host", 1}, {"[127.0.0.1]", "127.0.0.1", 5900},
    {"[::1]", "::1", 5900}, {"[::1]:2", "::1", 5902},
    {"2001:db8::20:1", "2001:db8::20:1", 5900},
    {"[2001:db8::20:1]::2", "2001:db8::20:1", 2}
  };
  for (const auto& fixture : fixtures) {
    SCOPED_TRACE(fixture.text);
    const auto endpoint = Endpoint::parse(fixture.text);
    std::string host;
    int port;
    network::getHostAndPort(fixture.text, &host, &port);
    EXPECT_EQ(endpoint.host(), fixture.host);
    EXPECT_EQ(endpoint.port(), fixture.port);
    EXPECT_EQ(endpoint.host(), host);
    EXPECT_EQ(endpoint.port(), port);
    EXPECT_EQ(endpoint.transport(), EndpointTransport::Tcp);
    EXPECT_TRUE(endpoint.path().empty());
    EXPECT_EQ(endpoint.original(), fixture.text);
  }
}

TEST(Endpoint, CanonicalDestinationsKeepOriginalLabels)
{
  const auto first = Endpoint::parse(" EXAMPLE.invalid:1 ");
  EXPECT_EQ(first, Endpoint::parse("example.invalid::5901"));
  EXPECT_EQ(first.original(), " EXAMPLE.invalid:1 ");
  EXPECT_EQ(Endpoint::parse("[2001:0DB8:0:0:0:0:0:1]:1"),
            Endpoint::parse("[2001:db8::1]::5901"));
  EXPECT_EQ(Endpoint::parse("[2001:0DB8:0:0:0:0:0:1]").networkHost(),
            "2001:db8::1");
}

TEST(Endpoint, DoesNotCollapseAliasesOrRoutes)
{
  EXPECT_NE(Endpoint::parse("localhost"), Endpoint::parse("127.0.0.1"));
  EXPECT_NE(Endpoint::parse("host"), Endpoint::parse("host."));
  EXPECT_NE(Endpoint::parse("host"), Endpoint::parse("alias"));
  EXPECT_NE(Endpoint::parse("host:1"), Endpoint::parse("host:2"));
  EXPECT_NE(Endpoint::parse("127.0.0.1"), Endpoint::parse("[::ffff:127.0.0.1]"));
  EXPECT_NE(Endpoint::parse("host", true, "gateway-a"),
            Endpoint::parse("host", true, "gateway-b"));
  EXPECT_NE(Endpoint::parse("host"), Endpoint::parse("host", true, "direct"));
  EXPECT_EQ(Endpoint::parse("HOST:0", true, "gateway-a"),
            Endpoint::parse("host::5900", true, "gateway-a"));
}

TEST(Endpoint, ScopedIpv6Identity)
{
  const auto endpoint = Endpoint::parse("[FE80:0:0:0:0:0:0:1%en0]:1");
  EXPECT_EQ(endpoint.host(), "fe80::1");
  EXPECT_EQ(endpoint.scope(), "en0");
  EXPECT_EQ(endpoint.networkHost(), "fe80::1%en0");
  EXPECT_EQ(endpoint, Endpoint::parse("[fe80::1%en0]::5901"));
  EXPECT_EQ(Endpoint::parse("fe80:0::1%en0").port(), 5900);
  EXPECT_NE(endpoint, Endpoint::parse("[fe80::1%en1]:1"));
  EXPECT_NE(endpoint, Endpoint::parse("[fe80::1%EN0]:1"));
  EXPECT_NE(Endpoint::parse("[fe80::1%1]"), Endpoint::parse("[fe80::1%01]"));
  EXPECT_NE(Endpoint::parse("[fe80::1]"), Endpoint::parse("[fe80::1%en0]"));
}

TEST(Endpoint, UnixPathBytesAndRoutesRemainDistinct)
{
  const std::string path = " ./VNC socket:1 ";
  const auto endpoint = Endpoint::parse(path, true, "route");
  EXPECT_EQ(endpoint.transport(), EndpointTransport::UnixSocket);
  EXPECT_EQ(endpoint.path(), path);
  EXPECT_EQ(endpoint.original(), path);
  EXPECT_EQ(endpoint.route(), "route");
  EXPECT_TRUE(endpoint.host().empty());
  EXPECT_TRUE(endpoint.scope().empty());
  EXPECT_TRUE(endpoint.networkHost().empty());
  EXPECT_EQ(endpoint.port(), 0);
  EXPECT_NE(endpoint, Endpoint::parse(path));
  EXPECT_NE(Endpoint::parse("./socket"), Endpoint::parse("dir/../socket"));
  EXPECT_NE(Endpoint::parse("./Socket"), Endpoint::parse("./socket"));
  expectError(std::string("/tmp/a\0b", 8), EndpointErrorCode::InvalidPath);
}

TEST(Endpoint, UnsupportedTransportIsExplicit)
{
  try {
    Endpoint::parse("/tmp/socket", false);
    FAIL();
  } catch (const EndpointError& error) {
    EXPECT_EQ(error.code, EndpointErrorCode::UnsupportedTransport);
  }
  EXPECT_EQ(Endpoint::parse("host:1", false).port(), 5901);
}

TEST(Endpoint, RejectsInvalidPortsWithoutIntegerWrap)
{
  for (const auto& text : {"host:", "host::", "host::0", "host:-1",
       "host::-1", "host:65536", "host::65536", "host::4294967297",
       "host::18446744073709551617", "host::+", "host:1x", "host:1 2",
       "[::1]garbage", "[::1] :1", "host::  ", "host::+ 1"}) {
    SCOPED_TRACE(text);
    expectError(text, EndpointErrorCode::InvalidPort);
  }
  expectError("host::" + std::string(4000, '9'), EndpointErrorCode::InvalidPort);
}

TEST(Endpoint, RejectsMalformedHostsAndScopes)
{
  expectError("[::1", EndpointErrorCode::UnmatchedBracket);
  for (const auto& text : {"ho st:1", "host]", "host[", "[host[inner]]",
       "[fe80::1%]", "[fe80::1%a%b]", "host%scope", "[gggg::1]",
       "[1:2:3]", "host\x01"}) {
    SCOPED_TRACE(text);
    expectError(text, EndpointErrorCode::InvalidHost);
  }
  expectError(std::string("host\0:1", 7), EndpointErrorCode::InvalidHost);
}

TEST(Endpoint, BoundsAndOwnedValues)
{
  expectError(std::string(4097, 'x'), EndpointErrorCode::TooLong);
  EXPECT_EQ(Endpoint::parse(std::string(4096, 'x')).host().size(), 4096u);
  for (const auto& route : {std::string(4097, 'x'), std::string("a\0b", 3)}) {
    try {
      Endpoint::parse("host", true, route);
      FAIL();
    } catch (const EndpointError& error) {
      EXPECT_EQ(error.code, route.size() > 4096 ? EndpointErrorCode::TooLong :
                                               EndpointErrorCode::InvalidRoute);
    }
  }
  std::string label = "Host:1", route = "gateway";
  const auto endpoint = Endpoint::parse(label, true, route);
  label.assign(100, 'x');
  route.clear();
  EXPECT_EQ(endpoint.original(), "Host:1");
  EXPECT_EQ(endpoint.route(), "gateway");
}

TEST(Endpoint, IndependentConcurrentParsing)
{
  std::vector<std::future<void>> workers;
  for (int index = 0; index < 4; ++index) {
    workers.push_back(std::async(std::launch::async, [index] {
      const std::string scope = "en" + std::to_string(index);
      for (int iteration = 0; iteration < 1000; ++iteration) {
        const auto endpoint = Endpoint::parse("[FE80::1%" + scope + "]:1",
                                               true, scope);
        EXPECT_EQ(endpoint.host(), "fe80::1");
        EXPECT_EQ(endpoint.scope(), scope);
        EXPECT_EQ(endpoint.route(), scope);
      }
    }));
  }
  for (auto& worker : workers) worker.get();
}

TEST(Endpoint, SharedParserPreservesReverseConnectionBase)
{
  const auto endpoint = network::parseHostAndPort("host:99", 5500);
  EXPECT_EQ(endpoint.host, "host");
  EXPECT_EQ(endpoint.port, 5599);
  std::string host;
  int port;
  network::getHostAndPort(":1", &host, &port, 5500);
  EXPECT_EQ(host, "localhost");
  EXPECT_EQ(port, 5501);
  EXPECT_EQ(network::parseHostAndPort("host::1", 5500).port, 1);
  EXPECT_THROW(network::parseHostAndPort("host", 0), network::HostPortError);
  EXPECT_THROW(network::parseHostAndPort("host", 65536), network::HostPortError);
  EXPECT_THROW(network::parseHostAndPort("host:99", 65535), network::HostPortError);
}

TEST(Endpoint, LegacyAdapterRejectsInvalidArgumentsWithoutPartialOutput)
{
  std::string host = "unchanged";
  int port = 1234;
  EXPECT_THROW(network::getHostAndPort(nullptr, &host, &port), std::invalid_argument);
  EXPECT_THROW(network::getHostAndPort("host", nullptr, &port), std::invalid_argument);
  EXPECT_THROW(network::getHostAndPort("host", &host, nullptr), std::invalid_argument);
  EXPECT_THROW(network::getHostAndPort("newhost::65536", &host, &port), std::runtime_error);
  EXPECT_EQ(host, "unchanged");
  EXPECT_EQ(port, 1234);
}
