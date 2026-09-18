/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */

#include <gtest/gtest.h>

#include <rfb/PixelBuffer.h>
#include <rfb/ServerParams.h>
#include <rfb/TightConstants.h>
#include <rfb/TightDecoder.h>
#include <rdr/MemInStream.h>
#include <rdr/MemOutStream.h>
#include <rdr/ZlibOutStream.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <thread>
#include <vector>

namespace {

const rfb::PixelFormat rgb565(16, 16, false, true, 31, 63, 31, 11, 5, 0);
// Exercise the generic 32-bit gradient path, not the separate RGB888 path.
const rfb::PixelFormat rgb565in32(32, 16, false, true, 31, 63, 31, 11, 5, 0);
const rfb::PixelFormat rgb888(32, 24, false, true, 255, 255, 255, 16, 8, 0);

void writeCompact(rdr::OutStream& out, size_t length)
{
  for (int i = 0; i < 2; ++i) {
    if (length < 128) {
      out.writeU8(length);
      return;
    }
    out.writeU8((length & 127) | 128);
    length >>= 7;
  }
  out.writeU8(length);
}

// A constant image needs only one nonzero gradient residual: the first pixel.
// All later pixels predict the same colour, including the start of each row.
std::vector<uint8_t> constantGradient(const rfb::PixelFormat& pf, int w, int h,
                                     const std::array<uint8_t, 3>& colour)
{
  const int bytes = pf.is888() ? 3 : pf.bpp / 8;
  std::vector<uint8_t> residuals(w * h * bytes, 0);
  if (pf.is888())
    std::copy(colour.begin(), colour.end(), residuals.begin());
  else
    pf.bufferFromRGB(residuals.data(), colour.data(), 1);

  rdr::MemOutStream wire;
  wire.writeU8((rfb::tightExplicitFilter << 4) | 1); // reset stream 0
  wire.writeU8(rfb::tightFilterGradient);
  if (residuals.size() < 12)
    wire.writeBytes(residuals.data(), residuals.size());
  else {
    rdr::MemOutStream compressed;
    rdr::ZlibOutStream zlib(&compressed);
    zlib.writeBytes(residuals.data(), residuals.size());
    zlib.flush();
    writeCompact(wire, compressed.length());
    wire.writeBytes(compressed.data(), compressed.length());
  }
  return {wire.data(), wire.data() + wire.length()};
}

// Use the public wire parser and decoder, with a nonzero rectangle origin and
// padding around it. Compare every byte, including the untouched border.
bool decodeConstant(rfb::TightDecoder& decoder, const rfb::ServerParams& server,
                    const rfb::PixelFormat& outputPF, int w, int h,
                    const std::array<uint8_t, 3>& colour,
                    const std::vector<uint8_t>& wire)
{
  const int stride = w + 2;
  const int bytes = outputPF.bpp / 8;
  const core::Rect rect(1, 1, w + 1, h + 1);
  std::vector<uint8_t> pixels(stride * (h + 2) * bytes, 0xa5);
  auto expected = pixels;
  for (int y = 1; y <= h; ++y)
    for (int x = 1; x <= w; ++x)
      outputPF.bufferFromRGB(&expected[(y * stride + x) * bytes], colour.data(), 1);
  rfb::FullFramePixelBuffer buffer(outputPF, stride, h + 2, pixels.data(), stride);
  rdr::MemInStream input(wire.data(), wire.size());
  rdr::MemOutStream parsed;
  if (!decoder.readRect(rect, &input, server, &parsed))
    return false;
  decoder.decodeRect(rect, parsed.data(), parsed.length(), server, &buffer);
  return pixels == expected;
}

} // namespace

TEST(TightDecoder, GradientFormatsAndStrides)
{
  const std::array<uint8_t, 3> blue = {{0, 0, 255}};
  for (const auto& pf : {rgb565, rgb565in32, rgb888}) {
    rfb::ServerParams server;
    server.setPF(pf);
    rfb::TightDecoder decoder;
    for (int width : {1, 17, 2048}) {
      SCOPED_TRACE(::testing::Message() << "bpp=" << pf.bpp << " width=" << width);
      for (int height : {1, 7}) {
        auto wire = constantGradient(pf, width, height, blue);
        EXPECT_TRUE(decodeConstant(decoder, server, pf, width, height, blue, wire));
        EXPECT_TRUE(decodeConstant(decoder, server, rgb888, width, height, blue, wire));
      }
    }
  }
}

TEST(TightDecoder, ConcurrentGradientSessions)
{
  std::atomic<int> ready(0);
  std::atomic<bool> failed(false);
  std::vector<std::thread> workers;
  // Two workers per generic specialization, with incompatible previous rows.
  // No decoder, zlib stream, server state or framebuffer is shared.
  for (int worker = 0; worker < 4; ++worker) {
    workers.emplace_back([&, worker] {
      const auto& pf = worker < 2 ? rgb565 : rgb565in32;
      const std::array<uint8_t, 3> colour = {{0, 0, uint8_t(worker % 2 ? 255 : 0)}};
      rfb::ServerParams server;
      server.setPF(pf);
      rfb::TightDecoder decoder;
      auto wire = constantGradient(pf, 2048, 64, colour);
      ++ready;
      while (ready.load() != 4)
        std::this_thread::yield();
      for (int i = 0; i < 20; ++i) {
        if (!decodeConstant(decoder, server, pf, 2048, 64, colour, wire))
          failed.store(true);
      }
    });
  }
  for (auto& worker : workers)
    worker.join();
  EXPECT_FALSE(failed.load());
}
