/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Encodes a patterned framebuffer with the project's server-side EncodeManager
// and decodes it with the client CConnection/DecodeManager, for each supported
// wire encoding. Lossless encodings must reproduce every pixel; Tight/JPEG must
// stay within a small error bound and actually use JPEG for the photographic area.

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include <gtest/gtest.h>
#include <rfb/CConnection.h>
#include <rfb/CMsgReader.h>
#include <rfb/CMsgWriter.h>
#include <rfb/Decoder.h>
#include <rfb/EncodeManager.h>
#include <rfb/PixelBuffer.h>
#include <rfb/SConnection.h>
#include <rfb/SMsgWriter.h>
#include <rfb/UpdateTracker.h>
#include <rfb/encodings.h>
#include <rdr/MemInStream.h>
#include <rdr/MemOutStream.h>

#include <cstdlib>
#include <map>
#include <memory>
#include <vector>

namespace {
const rfb::PixelFormat format(32, 24, false, true, 255, 255, 255, 16, 8, 0);
constexpr int width = 96, height = 64;

class Server : public rfb::SConnection {
public:
  Server() : SConnection(rfb::AccessDefault)
  {
    setStreams(nullptr, &out);
    setWriter(new rfb::SMsgWriter(&client, &out));
    client.setPF(format);
    client.setDimensions(width, height);
  }
  // Separate from construction: setEncodings is virtual.
  void configure(const std::vector<int32_t>& encodings)
  {
    static_cast<rfb::SMsgHandler*>(this)->setEncodings(encodings.size(), encodings.data());
    manager.reset(new rfb::EncodeManager(this));
  }
  void write(const rfb::PixelBuffer* pb)
  {
    rfb::UpdateInfo update;
    update.changed = core::Region(pb->getRect());
    manager->writeUpdate(update, pb, nullptr);
  }
  void setAccessRights(rfb::AccessRights) override {}
  void setDesktopSize(int, int, const rfb::ScreenSet&) override {}
  void keyEvent(uint32_t, uint32_t, bool) override {}
  void pointerEvent(const core::Point&, uint16_t) override {}
  rdr::MemOutStream out;
private:
  std::unique_ptr<rfb::EncodeManager> manager;
};

class Client : public rfb::CConnection {
public:
  Client(const uint8_t* data, size_t length) : in(data, length)
  {
    setStreams(&in, &discard);
    setState(RFBSTATE_NORMAL);
    setReader(new rfb::CMsgReader(this, &in));
    setWriter(new rfb::CMsgWriter(&server, &discard));
    server.setPF(format);
    setDesktopSize(width, height);
  }
  void decodeAll() { while (in.avail() > 0) processMsg(); }
  const rfb::PixelBuffer* frame() { return getFramebuffer(); }
  std::map<int, int> rects;
  void resizeFramebuffer() override { setFramebuffer(new rfb::ManagedPixelBuffer(format, server.width(), server.height())); }
  bool dataRect(const core::Rect& r, int encoding) override { ++rects[encoding]; return CConnection::dataRect(r, encoding); }
  void initDone() override {}
  void setColourMapEntries(int, int, uint16_t*) override {}
  void bell() override {}
  void serverCutText(const char*) override {}
  void getUserPasswd(bool, std::string*, std::string*) override {}
  bool verifyCertificate(unsigned int, const uint8_t*, size_t) override { return false; }
  bool verifyHostKey(const uint8_t*, size_t, const char*) override { return false; }
private:
  rdr::MemInStream in;
  rdr::MemOutStream discard;
};

// Left third: smooth gradient with deterministic noise (photographic). Middle:
// a four-colour pattern (palette-friendly). Right: one solid block.
std::unique_ptr<rfb::ManagedPixelBuffer> pattern()
{
  std::unique_ptr<rfb::ManagedPixelBuffer> pb(new rfb::ManagedPixelBuffer(format, width, height));
  int stride;
  uint8_t* pixels = pb->getBufferRW(pb->getRect(), &stride);
  unsigned seed = 12345;
  for (int y = 0; y < height; ++y)
    for (int x = 0; x < width; ++x) {
      uint8_t* p = pixels + (y * stride + x) * 4;
      uint8_t r, g, b;
      if (x < width / 3) {
        seed = seed * 1103515245 + 12345;
        const int noise = int((seed >> 16) % 9) - 4;
        r = uint8_t(std::min(255, std::max(0, x * 8 + noise)));
        g = uint8_t(std::min(255, std::max(0, y * 4 + noise)));
        b = uint8_t(std::min(255, std::max(0, 128 + noise)));
      } else if (x < 2 * width / 3) {
        static const uint8_t colours[4][3] = {{255, 0, 0}, {0, 128, 0}, {0, 0, 255}, {250, 250, 250}};
        const auto* c = colours[((x / 4) + (y / 4)) % 4];
        r = c[0]; g = c[1]; b = c[2];
      } else {
        r = 30; g = 60; b = 90;
      }
      const uint8_t rgb[3] = {r, g, b};
      format.bufferFromRGB(p, rgb, 1);
    }
  pb->commitBufferRW(pb->getRect());
  return pb;
}

struct Result { std::map<int, int> rects; int maximumError = 0; double meanError = 0; };
Result roundTrip(const std::vector<int32_t>& encodings)
{
  auto source = pattern();
  Server server;
  server.configure(encodings);
  server.write(source.get());
  Client client(server.out.data(), server.out.length());
  client.decodeAll();
  Result result; result.rects = client.rects;
  int sourceStride, decodedStride;
  const uint8_t* a = source->getBuffer(source->getRect(), &sourceStride);
  const uint8_t* b = client.frame()->getBuffer(client.frame()->getRect(), &decodedStride);
  long total = 0;
  for (int y = 0; y < height; ++y)
    for (int x = 0; x < width; ++x) {
      uint8_t ra[3], rb[3];
      format.rgbFromBuffer(ra, a + (y * sourceStride + x) * 4, 1);
      format.rgbFromBuffer(rb, b + (y * decodedStride + x) * 4, 1);
      for (int c = 0; c < 3; ++c) {
        const int error = std::abs(int(ra[c]) - int(rb[c]));
        result.maximumError = std::max(result.maximumError, error); total += error;
      }
    }
  result.meanError = double(total) / (width * height * 3);
  return result;
}
int nonTrivial(const Result& result, int encoding) { auto it = result.rects.find(encoding); return it == result.rects.end() ? 0 : it->second; }
}

TEST(EncodingRoundTrip, LosslessEncodingsReproduceEveryPixel)
{
  for (int32_t encoding : {rfb::encodingRaw, rfb::encodingHextile, rfb::encodingZRLE, rfb::encodingTight}) {
    if (!rfb::Decoder::supported(encoding)) continue;
    std::vector<int32_t> encodings{encoding};
    if (encoding == rfb::encodingTight) encodings.push_back(rfb::pseudoEncodingCompressLevel0 + 2); // no JPEG hint
    const auto result = roundTrip(encodings);
    EXPECT_GT(nonTrivial(result, encoding), 0) << "encoding " << encoding << " was not used on the wire";
    EXPECT_EQ(result.maximumError, 0) << "encoding " << encoding;
  }
}

TEST(EncodingRoundTrip, TightJpegIsBoundedAndPreservesLosslessRegions)
{
  if (!rfb::Decoder::supported(rfb::encodingTight)) GTEST_SKIP() << "Tight decoder not compiled";
  const auto result = roundTrip({rfb::encodingTight, rfb::pseudoEncodingQualityLevel0 + 8,
                                 rfb::pseudoEncodingCompressLevel0 + 2});
  EXPECT_GT(nonTrivial(result, rfb::encodingTight), 0);
  EXPECT_GT(result.maximumError, 0) << "the photographic area should take the lossy JPEG path";
  EXPECT_LE(result.maximumError, 48);
  EXPECT_LT(result.meanError, 3.0);
}

TEST(EncodingRoundTrip, StandaloneJpegDecodesWithinBounds)
{
  if (!rfb::Decoder::supported(rfb::encodingJPEG)) GTEST_SKIP() << "JPEG decoder not compiled";
  const auto result = roundTrip({rfb::encodingJPEG, rfb::pseudoEncodingQualityLevel0 + 8});
  EXPECT_GT(nonTrivial(result, rfb::encodingJPEG), 0) << "JPEG was not used on the wire";
  EXPECT_GT(result.maximumError, 0);
  EXPECT_LE(result.maximumError, 64);
  EXPECT_LT(result.meanError, 4.0);
}

// No server encoder emits RRE, so its decoder is checked with a hand-built rect:
// background plus two subrectangles, one overlapping the edge of the other.
TEST(EncodingRoundTrip, HandBuiltRreRectDecodes)
{
  if (!rfb::Decoder::supported(rfb::encodingRRE)) GTEST_SKIP() << "RRE decoder not compiled";
  rdr::MemOutStream wire;
  auto pixel = [&](uint8_t r, uint8_t g, uint8_t b) { const uint8_t rgb[3] = {r, g, b}; uint8_t p[4]; format.bufferFromRGB(p, rgb, 1); wire.writeBytes(p, 4); };
  wire.writeU8(0); wire.pad(1); wire.writeU16(1);                    // FramebufferUpdate, one rect
  wire.writeU16(8); wire.writeU16(4); wire.writeU16(16); wire.writeU16(8); wire.writeS32(rfb::encodingRRE);
  wire.writeU32(2); pixel(10, 20, 30);                                // two subrects on background
  pixel(200, 0, 0); wire.writeU16(0); wire.writeU16(0); wire.writeU16(4); wire.writeU16(4);
  pixel(0, 200, 0); wire.writeU16(2); wire.writeU16(2); wire.writeU16(6); wire.writeU16(3);
  Client client(wire.data(), wire.length());
  client.decodeAll();
  EXPECT_EQ(client.rects[rfb::encodingRRE], 1);
  auto at = [&](int x, int y) {
    int stride; const uint8_t* p = client.frame()->getBuffer(client.frame()->getRect(), &stride);
    uint8_t rgb[3]; format.rgbFromBuffer(rgb, p + (y * stride + x) * 4, 1); return std::vector<int>{rgb[0], rgb[1], rgb[2]};
  };
  EXPECT_EQ(at(8 + 1, 4 + 1), (std::vector<int>{200, 0, 0}));   // first subrect
  EXPECT_EQ(at(8 + 3, 4 + 3), (std::vector<int>{0, 200, 0}));   // second, drawn over the first
  EXPECT_EQ(at(8 + 15, 4 + 7), (std::vector<int>{10, 20, 30})); // background
}
