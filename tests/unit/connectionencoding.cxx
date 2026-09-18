/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */

#include <gtest/gtest.h>
#include <rfb/CConnection.h>
#include <rfb/CMsgWriter.h>
#include <rfb/PixelBuffer.h>
#include <rfb/encodings.h>
#include <rdr/MemInStream.h>
#include <rdr/MemOutStream.h>

#include <algorithm>
#include <atomic>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {
class TestConnection : public rfb::CConnection {
public:
  TestConnection() = default;
  explicit TestConnection(const rfb::SecurityClient& policy) : CConnection(policy) {}
  ~TestConnection() override { close(); }

  // Exercise normal update callbacks with the real wire writer. Authentication
  // is deliberately outside this fixture; these tests cover encoding negotiation.
  void start()
  {
    setStreams(nullptr, &output);
    setWriter(new rfb::CMsgWriter(&server, &output));
    serverInit(4, 3, rfb::PixelFormat(32, 24, false, true, 255, 255, 255, 16, 8, 0), "fixture");
  }
  void nextUpdate()
  {
    output.clear();
    framebufferUpdateStart();
    framebufferUpdateEnd();
  }
  std::vector<uint32_t> encodings()
  {
    rdr::MemInStream input(output.data(), output.length());
    std::vector<uint32_t> result;
    if (input.readU8() == 2) {
      input.skip(1);
      const unsigned count = input.readU16();
      for (unsigned i = 0; i < count; ++i)
        result.push_back(input.readU32());
      if (input.readU8() != 3)
        throw std::logic_error("Missing framebuffer request");
    } else if (output.data()[0] != 3) {
      throw std::logic_error("Unexpected client message");
    }
    // One SetEncodings at most, followed by exactly one update request.
    if (output.length() != (result.empty() ? 10 : 14 + 4 * result.size()))
      throw std::logic_error("Unexpected wire length");
    return result;
  }
  void getUserPasswd(bool, std::string*, std::string*) override {}
  bool verifyCertificate(unsigned int, const uint8_t*, size_t) override { return false; }
  bool verifyHostKey(const uint8_t*, size_t, const char*) override { return false; }
  void bell() override {}
  void initDone() override
  {
    setFramebuffer(new rfb::ManagedPixelBuffer(server.pf(), server.width(), server.height()));
  }
private:
  rdr::MemOutStream output;
};

class LegacyJpegGuard {
public:
  LegacyJpegGuard() : saved(rfb::CConnection::noJpeg) {}
  ~LegacyJpegGuard() { rfb::CConnection::noJpeg.setParam(saved); }
private:
  bool saved;
};

bool contains(const std::vector<uint32_t>& encodings, uint32_t encoding)
{
  return std::find(encodings.begin(), encodings.end(), encoding) != encodings.end();
}

void expectPolicy(TestConnection& connection, bool allowed)
{
  const auto encodings = connection.encodings();
  EXPECT_EQ(contains(encodings, rfb::encodingJPEG), allowed);
  EXPECT_EQ(contains(encodings, rfb::pseudoEncodingQualityLevel0 + 8), allowed);
  EXPECT_TRUE(contains(encodings, rfb::encodingTight));
  EXPECT_TRUE(contains(encodings, rfb::encodingCopyRect));
  EXPECT_TRUE(contains(encodings, rfb::pseudoEncodingCompressLevel0 + 2));
}
} // namespace

TEST(ConnectionEncoding, LegacyDefaultsAreCapturedAtConstruction)
{
  LegacyJpegGuard restore;
  rfb::CConnection::noJpeg.setParam(false);
  TestConnection allowed;
  rfb::CConnection::noJpeg.setParam(true);
  TestConnection denied;
  rfb::CConnection::noJpeg.setParam(false);
  allowed.setQualityLevel(8);
  denied.setQualityLevel(8);
  allowed.start();
  denied.start();
  expectPolicy(allowed, true);
  expectPolicy(denied, false);
}

TEST(ConnectionEncoding, ExplicitPolicyDoesNotImportLegacyJpegDefault)
{
  LegacyJpegGuard restore;
  rfb::CConnection::noJpeg.setParam(true);
  TestConnection connection(rfb::SecurityClient({rfb::secTypeNone}));
  connection.setQualityLevel(8);
  connection.start();
  expectPolicy(connection, true);
}

TEST(ConnectionEncoding, LiveToggleRenegotiatesAndRestoresQuality)
{
  TestConnection connection(rfb::SecurityClient({rfb::secTypeNone}));
  connection.setPreferredEncoding(rfb::encodingJPEG);
  connection.setQualityLevel(8);
  connection.start();
  expectPolicy(connection, true);
  connection.setJpegAllowed(false);
  connection.nextUpdate();
  expectPolicy(connection, false);
  EXPECT_EQ(connection.getQualityLevel(), 8);
  connection.setJpegAllowed(false);
  connection.nextUpdate();
  EXPECT_TRUE(connection.encodings().empty());
  connection.setJpegAllowed(true);
  connection.nextUpdate();
  expectPolicy(connection, true);
  connection.nextUpdate();
  EXPECT_TRUE(connection.encodings().empty());
}

TEST(ConnectionEncoding, ConcurrentSessionsKeepIndependentPolicies)
{
  rfb::SecurityClient policy({rfb::secTypeNone});
  TestConnection first(policy), second(policy);
  std::atomic<bool> failed{false};
  auto run = [&](TestConnection& connection, bool initial) {
    try {
      connection.setQualityLevel(8);
      connection.setJpegAllowed(initial);
      connection.start();
      for (int i = 0; i < 100; ++i) {
        const bool allowed = (i % 2 == 0) == initial;
        const auto encodings = connection.encodings();
        if (contains(encodings, rfb::encodingJPEG) != allowed ||
            contains(encodings, rfb::pseudoEncodingQualityLevel0 + 8) != allowed)
          failed = true;
        connection.setJpegAllowed(!allowed);
        connection.nextUpdate();
      }
    } catch (...) { failed = true; }
  };
  std::thread a(run, std::ref(first), true);
  std::thread b(run, std::ref(second), false);
  a.join();
  b.join();
  EXPECT_FALSE(failed);
}
