/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/core/ProtocolSession.h>
#include <rfb/encodings.h>
#include <rdr/MemInStream.h>
#include <rdr/MemOutStream.h>
#include <gtest/gtest.h>
#include <algorithm>
#include <future>

using namespace viewer;
namespace {
const rfb::PixelFormat full(32, 24, false, true, 255, 255, 255, 16, 8, 0);
void handshake(rdr::MemOutStream& wire, bool old = false, const rfb::PixelFormat& format = full)
{
  wire.writeBytes(reinterpret_cast<const uint8_t*>(old ? "RFB 003.003\n" : "RFB 003.008\n"), 12);
  if (old) wire.writeU32(rfb::secTypeNone);
  else { wire.writeU8(1); wire.writeU8(rfb::secTypeNone); wire.writeU32(0); }
  wire.writeU16(1); wire.writeU16(1); format.write(&wire);
  wire.writeU32(0);
}
void rawUpdate(rdr::MemOutStream& wire, uint32_t pixel, bool small = false)
{
  wire.writeU8(0); wire.pad(1); wire.writeU16(1);
  wire.writeU16(0); wire.writeU16(0); wire.writeU16(1); wire.writeU16(1);
  wire.writeU32(rfb::encodingRaw);
  if (small) wire.writeU8(pixel); else wire.writeU32(pixel);
  wire.writeU8(2); // Bell marks the completed frame boundary.
}
void ready(ProtocolSession& session)
{
  for (int i = 0; !session.desktop().ready && i < 20; ++i) ASSERT_TRUE(session.processMessage());
  ASSERT_TRUE(session.desktop().ready);
}
void throughBell(ProtocolSession& session, uint64_t count)
{
  for (int i = 0; session.desktop().bells < count && i < 20; ++i) ASSERT_TRUE(session.processMessage());
  ASSERT_EQ(session.desktop().bells, count);
}
struct Messages {
  std::vector<int> encodings;
  std::vector<rfb::PixelFormat> formats;
};
Messages messages(rdr::MemOutStream& output, size_t skip = 14)
{
  rdr::MemInStream input(output.data(), output.length());
  input.skip(skip);
  Messages result;
  while (input.pos() < output.length()) {
    const int kind = input.readU8();
    if (kind == 0) {
      input.skip(3); rfb::PixelFormat format; format.read(&input); result.formats.push_back(format);
    } else if (kind == 2) {
      input.skip(1); const int count = input.readU16();
      result.encodings.clear();
      for (int i = 0; i < count; ++i) result.encodings.push_back(input.readS32());
    } else if (kind == 3) {
      input.skip(9);
    } else throw std::runtime_error("Unexpected client message");
  }
  return result;
}
bool has(const Messages& wire, int encoding)
{
  return std::find(wire.encodings.begin(), wire.encodings.end(), encoding) != wire.encodings.end();
}
EncodingOptions manual(const OptionPatch& extra = {})
{
  return EncodingOptions().withPatch({{"AutoSelect", "off"}}, OptionSource::Session)
    .withPatch(extra, OptionSource::Session);
}
void drain(const std::shared_ptr<SessionEvents>& events)
{
  SessionEvent event; while (events->take(event)) {}
}
}

TEST(SessionEncoding, InitialHintsUseValidatedSnapshot)
{
  const auto options = manual({{"PreferredEncoding", "ZRLE"}, {"QualityLevel", "3"},
    {"CustomCompressLevel", "on"}, {"CompressLevel", "9"}});
  rdr::MemOutStream wire, output; handshake(wire);
  rdr::MemInStream input(wire.data(), wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr, options);
  session.start("fixture", input, output); ready(session);
  const auto sent = messages(output);
  const auto preference = std::find(sent.encodings.begin(), sent.encodings.end(), rfb::encodingZRLE);
  const auto tight = std::find(sent.encodings.begin(), sent.encodings.end(), rfb::encodingTight);
  EXPECT_LT(preference, tight);
  EXPECT_TRUE(has(sent, rfb::pseudoEncodingQualityLevel0 + 3));
  EXPECT_TRUE(has(sent, rfb::pseudoEncodingCompressLevel0 + 9));
  EXPECT_TRUE(has(sent, rfb::encodingJPEG));
}

TEST(SessionEncoding, NoJpegRemovesBothLossyHintsAndStandaloneEncoding)
{
  rdr::MemOutStream wire, output; handshake(wire);
  rdr::MemInStream input(wire.data(), wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr,
    manual({{"NoJPEG", "on"}, {"PreferredEncoding", "JPEG"}}));
  session.start("fixture", input, output); ready(session);
  const auto sent = messages(output);
  EXPECT_FALSE(has(sent, rfb::encodingJPEG));
  for (int level = 0; level <= 9; ++level) {
    EXPECT_FALSE(has(sent, rfb::pseudoEncodingQualityLevel0 + level));
    EXPECT_FALSE(has(sent, rfb::pseudoEncodingCompressLevel0 + level));
  }
  EXPECT_TRUE(has(sent, rfb::encodingTight));
}

TEST(SessionEncoding, ReducedWireColorStillPublishesBgra)
{
  for (int level = 0; level <= 2; ++level) {
    rdr::MemOutStream wire, output; handshake(wire);
    // Full red in the three retained reduced-color layouts.
    rawUpdate(wire, level == 0 ? 4 : level == 1 ? 48 : 224, true);
    rdr::MemInStream input(wire.data(), wire.length());
    ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr,
      manual({{"FullColor", "off"}, {"LowColorLevel", std::to_string(level)}}));
    auto view = session.attachView();
    session.start("fixture", input, output); throughBell(session, 1);
    const auto sent = messages(output);
    ASSERT_EQ(sent.formats.size(), 1u); EXPECT_EQ(sent.formats[0].bpp, 8);
    ViewUpdate frame; ASSERT_TRUE(view->take(frame)); ASSERT_TRUE(frame.frame);
    EXPECT_EQ(frame.frame->pixels.format(), PixelFormat::BGRA8);
    EXPECT_EQ(frame.frame->pixels.data()[0], 0);
    EXPECT_EQ(frame.frame->pixels.data()[1], 0);
    EXPECT_EQ(frame.frame->pixels.data()[2], 255);
  }
}

TEST(SessionEncoding, LiveApplicationCompletesOnceAndSurvivesReconnect)
{
  rdr::MemOutStream wire, output; handshake(wire);
  rawUpdate(wire, 0); rawUpdate(wire, 4, true);
  rdr::MemInStream input(wire.data(), wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
  auto events = session.subscribeEvents(); auto view = session.attachView();
  session.start("fixture", input, output); ready(session); drain(events);
  const auto options = manual({{"FullColor", "off"}, {"LowColorLevel", "0"}, {"QualityLevel", "1"}});
  const auto operation = session.applyEncodingOptions(options);
  ASSERT_NE(operation, 0u);
  SessionEvent event; ASSERT_TRUE(events->take(event));
  EXPECT_EQ(event.kind, SessionEventKind::Completion);
  EXPECT_EQ(event.operation, operation); EXPECT_EQ(event.result, OperationResult::Succeeded);
  EXPECT_FALSE(events->take(event));
  throughBell(session, 1); // This update still uses the old negotiated format.
  throughBell(session, 2); // Now the requested 8-color format is active.
  ViewUpdate frame; ASSERT_TRUE(view->take(frame)); ASSERT_TRUE(frame.frame);
  EXPECT_EQ(frame.frame->pixels.data()[2], 255);
  EXPECT_TRUE(has(messages(output), rfb::pseudoEncodingQualityLevel0 + 1));
  session.close(); drain(events); input.reposition(0); output.clear();
  session.start("fixture", input, output); ready(session);
  EXPECT_FALSE(session.encodingOptions().fullColor());
  const auto sent = messages(output);
  ASSERT_EQ(sent.formats.size(), 1u); EXPECT_EQ(sent.formats[0].depth, 3);
  EXPECT_TRUE(has(sent, rfb::pseudoEncodingQualityLevel0 + 1));
}

TEST(SessionEncoding, RejectedAdmissionDoesNotMutateSettings)
{
  rdr::MemOutStream wire, output; handshake(wire);
  rdr::MemInStream input(wire.data(), wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
  const auto options = manual({{"QualityLevel", "1"}});
  EXPECT_EQ(session.applyEncodingOptions(options), 0u);
  auto events = session.subscribeEvents(2); drain(events);
  session.start("fixture", input, output); ready(session); // Two queued state events.
  EXPECT_EQ(session.applyEncodingOptions(options), 0u);
  EXPECT_EQ(session.encodingOptions().qualityLevel(), 8);
  EXPECT_TRUE(session.desktop().ready);
  drain(events);
  EXPECT_NE(session.applyEncodingOptions(options), 0u);
  session.close();
  EXPECT_EQ(session.applyEncodingOptions(EncodingOptions()), 0u);
  EXPECT_EQ(session.encodingOptions().qualityLevel(), 1);
}

TEST(SessionEncoding, OldServersKeepNegotiatedPixelFormat)
{
  rdr::MemOutStream wire, output; handshake(wire, true);
  rawUpdate(wire, 0x00ff0000);
  rdr::MemInStream input(wire.data(), wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr,
                          manual({{"FullColor", "off"}}));
  auto view = session.attachView();
  session.start("fixture", input, output); throughBell(session, 1);
  EXPECT_TRUE(messages(output, 13).formats.empty());
  ViewUpdate frame; ASSERT_TRUE(view->take(frame)); ASSERT_TRUE(frame.frame);
  // writeU32 is big-endian: this value supplies green in the little-endian PF.
  EXPECT_EQ(frame.frame->pixels.data()[1], 255);
  EXPECT_FALSE(session.encodingOptions().fullColor());
}

TEST(SessionEncoding, ConcurrentSessionsKeepDifferentHints)
{
  auto worker = [](int quality, bool jpeg) {
    rdr::MemOutStream wire, output; handshake(wire);
    rdr::MemInStream input(wire.data(), wire.length());
    ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr,
      manual({{"QualityLevel", std::to_string(quality)}, {"NoJPEG", jpeg ? "off" : "on"}}));
    session.start("fixture", input, output); ready(session);
    const auto sent = messages(output);
    EXPECT_EQ(has(sent, rfb::encodingJPEG), jpeg);
    EXPECT_EQ(has(sent, rfb::pseudoEncodingQualityLevel0 + quality), jpeg);
  };
  auto one = std::async(std::launch::async, worker, 1, true);
  auto two = std::async(std::launch::async, worker, 9, false);
  one.get(); two.get();
}
