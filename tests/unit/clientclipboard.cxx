/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */

#include <gtest/gtest.h>
#include <rfb/CConnection.h>
#include <rfb/CMsgReader.h>
#include <rfb/Exception.h>
#include <rfb/PixelBuffer.h>
#include <rfb/clipboardTypes.h>
#include <rdr/MemInStream.h>
#include <rdr/MemOutStream.h>
#include <rdr/ZlibOutStream.h>

#include <atomic>
#include <thread>
#include <vector>

namespace {
class Connection : public rfb::CConnection {
public:
  using CConnection::CConnection;
  std::vector<std::string> texts;
  int bells = 0;
  unsigned providedFlags = 0;
  bool failProvide = false;
  void getUserPasswd(bool, std::string*, std::string*) override {}
  bool verifyCertificate(unsigned int, const uint8_t*, size_t) override { return false; }
  bool verifyHostKey(const uint8_t*, size_t, const char*) override { return false; }
  void initDone() override
  { setFramebuffer(new rfb::ManagedPixelBuffer(server.pf(), server.width(), server.height())); }
  void bell() override { ++bells; }
  void serverCutText(const char* text) override { texts.emplace_back(text); }
  void handleClipboardProvide(uint32_t flags, const size_t* lengths,
                              const uint8_t* const* data) override
  {
    if (failProvide) throw std::runtime_error("fixture clipboard delivery failure");
    providedFlags = flags;
    unsigned num = 0;
    for (unsigned i = 0; i < 16; ++i) {
      if (flags & (1 << i)) {
        texts.emplace_back(reinterpret_cast<const char*>(data[num]), lengths[num]);
        ++num;
      }
    }
  }
};

class LegacyGuard {
public:
  LegacyGuard() : cut(core::Configuration::getParam("MaxCutText")->getValueStr()),
                  security(rfb::SecurityClient::secTypes.getValueStr()) {}
  ~LegacyGuard()
  {
    core::Configuration::setParam("MaxCutText", cut.c_str());
    rfb::SecurityClient::secTypes.setParam(security.c_str());
  }
private:
  std::string cut, security;
};

void plain(rdr::MemOutStream& wire, const std::string& text)
{
  wire.writeU8(3); // ServerCutText
  wire.pad(3);
  wire.writeU32(text.size());
  wire.writeBytes(reinterpret_cast<const uint8_t*>(text.data()), text.size());
}

void extended(rdr::MemOutStream& wire, unsigned flags,
              const std::vector<std::string>& texts)
{
  rdr::MemOutStream compressed;
  rdr::ZlibOutStream zlib(&compressed);
  for (const auto& text : texts) {
    zlib.writeU32(text.size());
    zlib.writeBytes(reinterpret_cast<const uint8_t*>(text.data()), text.size());
  }
  zlib.flush();
  wire.writeU8(3);
  wire.pad(3);
  wire.writeU32(0u - (4 + compressed.length()));
  wire.writeU32(rfb::clipboardProvide | flags);
  wire.writeBytes(compressed.data(), compressed.length());
}

// Real RFB 3.8 / None handshake and ServerInit: verifies the connection passes
// its construction-time limits into the reader created after authentication.
void consume(Connection& connection, rdr::MemOutStream& messages)
{
  rdr::MemOutStream wire, output;
  const char version[] = "RFB 003.008\n";
  wire.writeBytes(reinterpret_cast<const uint8_t*>(version), 12);
  wire.writeU8(1);
  wire.writeU8(rfb::secTypeNone);
  wire.writeU32(0);
  wire.writeU16(1);
  wire.writeU16(1);
  rfb::PixelFormat(32, 24, false, true, 255, 255, 255, 16, 8, 0).write(&wire);
  wire.writeU32(0); // Empty server name
  wire.writeBytes(messages.data(), messages.length());
  wire.writeU8(2); // Bell proves the next message remains aligned
  rdr::MemInStream input(wire.data(), wire.length());
  connection.setStreams(&input, &output);
  connection.initialiseProtocol();
  try {
    for (int steps = 0; connection.bells == 0 && steps < 32; ++steps) {
      if (!connection.processMsg())
        throw std::logic_error("Incomplete clipboard fixture");
    }
    if (connection.bells != 1)
      throw std::logic_error("Missing trailing bell");
  } catch (...) {
    connection.close();
    throw;
  }
  connection.close();
}
} // namespace

TEST(ClientClipboard, PlainTextBoundaryAndZeroLimit)
{
  for (uint32_t cap : {0u, 4u, 5u}) {
    rfb::ClientMessageLimits limits;
    limits.maxCutText = cap;
    Connection connection(rfb::SecurityClient({rfb::secTypeNone}), limits);
    rdr::MemOutStream wire;
    plain(wire, "hello");
    plain(wire, "");
    consume(connection, wire);
    EXPECT_EQ(connection.texts, (cap == 5 ? std::vector<std::string>{"hello", ""}
                                         : std::vector<std::string>{""}));
  }
}

TEST(ClientClipboard, LegacyConnectionCapturesLimitBeforeHandshake)
{
  LegacyGuard restore;
  ASSERT_TRUE(rfb::SecurityClient::secTypes.setParam("None"));
  ASSERT_TRUE(core::Configuration::setParam("MaxCutText", "4"));
  Connection legacy;
  Connection explicitDefaults(rfb::SecurityClient({rfb::secTypeNone}));
  ASSERT_TRUE(core::Configuration::setParam("MaxCutText", "0"));
  rdr::MemOutStream wire;
  plain(wire, "four");
  plain(wire, "longer");
  consume(legacy, wire);
  consume(explicitDefaults, wire);
  EXPECT_EQ(legacy.texts, (std::vector<std::string>{"four"}));
  EXPECT_EQ(explicitDefaults.texts, (std::vector<std::string>{"four", "longer"}));
}

TEST(ClientClipboard, ExtendedWireLimitSkipsAndPreservesAlignment)
{
  rfb::ClientMessageLimits limits;
  limits.maxCutText = 4;
  Connection connection(rfb::SecurityClient({rfb::secTypeNone}), limits);
  rdr::MemOutStream wire;
  extended(wire, rfb::clipboardUTF8, {"hello"});
  consume(connection, wire);
  EXPECT_TRUE(connection.texts.empty());
  EXPECT_EQ(connection.providedFlags, 0u);
}

TEST(ClientClipboard, DecompressedLimitDropsOnlyOversizedFormat)
{
  rfb::ClientMessageLimits limits;
  limits.maxCutText = 128;
  Connection connection(rfb::SecurityClient({rfb::secTypeNone}), limits);
  limits.maxCutText = 2048; // Caller mutation must not change the snapshot.
  rdr::MemOutStream wire;
  extended(wire, rfb::clipboardUTF8 | rfb::clipboardHTML,
           {std::string(1024, 'a'), "<p>ok</p>"});
  ASSERT_LT(wire.length() - 8, 128u);
  consume(connection, wire);
  EXPECT_EQ(connection.texts, (std::vector<std::string>{"<p>ok</p>"}));
  EXPECT_EQ(connection.providedFlags, rfb::clipboardProvide | rfb::clipboardHTML);
}

TEST(ClientClipboard, RejectsUnrepresentableLimitsAndExtendedLength)
{
  rfb::SecurityClient policy({rfb::secTypeNone});
  rfb::ClientMessageLimits limits;
  limits.maxCutText = 0x80000000u;
  EXPECT_THROW(Connection(policy, limits), std::invalid_argument);
  EXPECT_THROW(rfb::CMsgReader(nullptr, nullptr, limits), std::invalid_argument);
  Connection connection(policy);
  rdr::MemOutStream wire;
  wire.writeU8(3);
  wire.pad(3);
  wire.writeU32(0x80000000u);
  EXPECT_THROW(consume(connection, wire), rfb::protocol_error);
}

TEST(ClientClipboard, ConcurrentSessionsUseIndependentLimits)
{
  std::atomic<bool> failed{false};
  auto run = [&](uint32_t cap) {
    try {
      for (int i = 0; i < 20; ++i) {
        rfb::ClientMessageLimits limits;
        limits.maxCutText = cap;
        Connection connection(rfb::SecurityClient({rfb::secTypeNone}), limits);
        rdr::MemOutStream wire;
        extended(wire, rfb::clipboardUTF8, {std::string(1024, 'a')});
        consume(connection, wire);
        if (connection.texts.size() != (cap >= 1024 ? 1u : 0u))
          failed = true;
      }
    } catch (...) { failed = true; }
  };
  std::thread small(run, 128), large(run, 2048);
  small.join();
  large.join();
  EXPECT_FALSE(failed);
}

TEST(ClientClipboard, ProvideCallbackFailureReleasesDecodedFormats)
{
  Connection connection(rfb::SecurityClient({rfb::secTypeNone}));
  connection.failProvide = true;
  rdr::MemOutStream wire;
  extended(wire, rfb::clipboardUTF8 | rfb::clipboardHTML, {"text", "<p>text</p>"});
  EXPECT_THROW(consume(connection, wire), std::runtime_error);
  EXPECT_TRUE(connection.texts.empty());
}

TEST(ClientClipboard, TruncatedLaterFormatReleasesEarlierDecodedText)
{
  Connection connection(rfb::SecurityClient({rfb::secTypeNone}));
  rdr::MemOutStream wire;
  extended(wire, rfb::clipboardUTF8 | rfb::clipboardHTML, {"text"});
  EXPECT_THROW(consume(connection, wire), std::runtime_error);
  EXPECT_TRUE(connection.texts.empty());
}
