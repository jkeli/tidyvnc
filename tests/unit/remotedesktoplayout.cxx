/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/ProtocolSession.h>
#include <rfb/PixelFormat.h>
#include <rfb/encodings.h>
#include <rfb/screenTypes.h>
#include <rdr/MemInStream.h>
#include <rdr/MemOutStream.h>
#include <limits>
using namespace viewer;
namespace {
RemoteDesktopLayout layout(uint32_t width = 4, uint32_t height = 2) {
  return RemoteDesktopLayout(width, height, {{7, 0, 0, width, height, 0x12345678}});
}
void handshake(rdr::MemOutStream& wire) {
  wire.writeBytes(reinterpret_cast<const uint8_t*>("RFB 003.008\n"), 12);
  wire.writeU8(1); wire.writeU8(rfb::secTypeNone); wire.writeU32(0);
  wire.writeU16(2); wire.writeU16(2);
  rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0).write(&wire);
  wire.writeU32(0);
}
void reply(rdr::MemOutStream& wire, unsigned reason, unsigned result, const RemoteDesktopLayout& value) {
  wire.writeU8(0); wire.pad(1); wire.writeU16(1);
  wire.writeU16(reason); wire.writeU16(result); wire.writeU16(value.width()); wire.writeU16(value.height());
  wire.writeU32(rfb::pseudoEncodingExtendedDesktopSize);
  wire.writeU8(value.screens().size()); wire.pad(3);
  for (const auto& screen : value.screens()) {
    wire.writeU32(screen.id); wire.writeU16(screen.x); wire.writeU16(screen.y);
    wire.writeU16(screen.width); wire.writeU16(screen.height); wire.writeU32(screen.flags);
  }
  wire.writeU8(2); // Bell makes deterministic stop points between replies.
}
void through(ProtocolSession& session, uint64_t bells) {
  for (int n = 0; session.desktop().bells < bells && n < 64; ++n) ASSERT_TRUE(session.processMessage());
  ASSERT_EQ(session.desktop().bells, bells);
}
std::vector<SessionEvent> drain(const std::shared_ptr<SessionEvents>& events) {
  std::vector<SessionEvent> result; SessionEvent event;
  while (events->take(event)) result.push_back(event);
  return result;
}
std::vector<SessionEvent> completions(const std::shared_ptr<SessionEvents>& events) {
  std::vector<SessionEvent> result;
  for (const auto& event : drain(events)) if (event.kind == SessionEventKind::Completion) result.push_back(event);
  return result;
}
}
TEST(RemoteDesktopLayout, ValidatesWireBoundsIdentitiesAndPreservesFlags)
{
  const auto maximum = std::numeric_limits<uint32_t>::max();
  EXPECT_THROW(RemoteDesktopLayout(0, 2, {{0,0,0,1,1,0}}), std::invalid_argument);
  EXPECT_THROW(RemoteDesktopLayout(65536, 2, {{0,0,0,1,1,0}}), std::invalid_argument);
  EXPECT_THROW(RemoteDesktopLayout(2, 2, {}), std::invalid_argument);
  EXPECT_THROW(RemoteDesktopLayout(2, 2, {{0,0,0,0,1,0}}), std::invalid_argument);
  EXPECT_THROW(RemoteDesktopLayout(2, 2, {{0,maximum,0,2,2,0}}), std::invalid_argument);
  EXPECT_THROW(RemoteDesktopLayout(2, 2, {{0,1,0,maximum,2,0}}), std::invalid_argument);
  EXPECT_THROW(RemoteDesktopLayout(2, 2, {{4,0,0,1,1,0},{4,1,1,1,1,0}}), std::invalid_argument);
  auto source = std::vector<RemoteScreen>{{maximum,0,0,65535,65535,maximum}};
  RemoteDesktopLayout owned(65535,65535,source); source[0].flags = 0;
  EXPECT_EQ(owned.screens()[0].flags, maximum); EXPECT_EQ(owned.screens()[0].id, maximum);
  std::vector<RemoteScreen> screens;
  for (unsigned i = 0; i < 255; ++i) screens.push_back({i,0,0,1,1,0}); // Overlap remains legal.
  EXPECT_NO_THROW(RemoteDesktopLayout(2,2,screens));
  screens.push_back({255,0,0,1,1,0}); EXPECT_THROW(RemoteDesktopLayout(2,2,screens), std::invalid_argument);
}
TEST(RemoteDesktopLayout, WritesOwnedTopologyAndCompletesOnlyAfterServerReply)
{
  rdr::MemOutStream wire, output; handshake(wire);
  reply(wire, rfb::reasonServer, 0, layout(2));
  RemoteDesktopLayout desired(4,2,{{7,0,0,2,2,0x12345678},{9,2,0,2,2,0xffffffff}});
  reply(wire, rfb::reasonClient, 0, desired);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone})); auto events = session.subscribeEvents();
  session.start("fixture",input,output); through(session,1); drain(events);
  auto oldLayout = events->snapshot().layout;
  ASSERT_TRUE(oldLayout); EXPECT_EQ(oldLayout->width(),2u);
  EXPECT_TRUE(events->snapshot().supportsDesktopResize);
  const auto before = output.length();
  auto operation = session.requestDesktopLayout(desired,0,77); ASSERT_NE(operation,0u);
  ASSERT_EQ(output.length()-before,40u);
  rdr::MemInStream sent(output.data()+before,output.length()-before);
  EXPECT_EQ(sent.readU8(),251); sent.skip(1);
  EXPECT_EQ(sent.readU16(),4); EXPECT_EQ(sent.readU16(),2); EXPECT_EQ(sent.readU8(),2); sent.skip(1);
  for (const auto& screen : desired.screens()) {
    EXPECT_EQ(sent.readU32(),screen.id); EXPECT_EQ(sent.readU16(),screen.x); EXPECT_EQ(sent.readU16(),screen.y);
    EXPECT_EQ(sent.readU16(),screen.width); EXPECT_EQ(sent.readU16(),screen.height); EXPECT_EQ(sent.readU32(),screen.flags);
  }
  EXPECT_TRUE(events->snapshot().resizePending); EXPECT_TRUE(completions(events).empty());
  EXPECT_EQ(session.requestDesktopLayout(desired),0u);
  through(session,2);
  const auto finished = completions(events); ASSERT_EQ(finished.size(),1u);
  EXPECT_EQ(finished[0].operation,operation); EXPECT_EQ(finished[0].origin,77u);
  EXPECT_EQ(finished[0].result,OperationResult::Succeeded); EXPECT_FALSE(finished[0].snapshot.resizePending);
  ASSERT_TRUE(finished[0].snapshot.layout); EXPECT_EQ(finished[0].snapshot.layout->screens().size(),2u);
  EXPECT_EQ(finished[0].snapshot.width,4u); EXPECT_EQ(oldLayout->width(),2u);
}
TEST(RemoteDesktopLayout, OtherClientResizeDoesNotCompleteOurRequest)
{
  rdr::MemOutStream wire, output; handshake(wire);
  reply(wire,rfb::reasonServer,0,layout(2)); reply(wire,rfb::reasonOtherClient,0,layout(3));
  reply(wire,rfb::reasonClient,0,layout(4));
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone})); auto events = session.subscribeEvents();
  session.start("fixture",input,output); through(session,1); drain(events);
  const auto operation = session.requestDesktopLayout(layout()); ASSERT_NE(operation,0u);
  through(session,2); EXPECT_TRUE(completions(events).empty());
  EXPECT_EQ(events->snapshot().width,3u); EXPECT_TRUE(events->snapshot().resizePending);
  through(session,3); const auto done = completions(events); ASSERT_EQ(done.size(),1u);
  EXPECT_EQ(done[0].operation,operation); EXPECT_EQ(done[0].snapshot.width,4u);
}
TEST(RemoteDesktopLayout, RejectionPreservesActualLayoutAndNativeResult)
{
  for (unsigned result : {1u,2u,3u,99u}) {
    rdr::MemOutStream wire, output; handshake(wire);
    reply(wire,rfb::reasonServer,0,layout(2)); reply(wire,rfb::reasonClient,result,layout(4));
    rdr::MemInStream input(wire.data(),wire.length());
    ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone})); auto events = session.subscribeEvents();
    session.start("fixture",input,output); through(session,1); drain(events);
    const auto original = events->snapshot().layout;
    ASSERT_NE(session.requestDesktopLayout(layout()),0u); through(session,2);
    const auto done = completions(events); ASSERT_EQ(done.size(),1u);
    EXPECT_EQ(done[0].result,OperationResult::Failed); EXPECT_EQ(done[0].failure,OperationFailure::ServerRejected);
    EXPECT_EQ(done[0].nativeResult,result); EXPECT_EQ(done[0].snapshot.layout,original);
    EXPECT_EQ(done[0].snapshot.state,SessionState::Connected); EXPECT_FALSE(done[0].snapshot.resizePending);
    EXPECT_NE(session.requestDesktopLayout(layout(3)),0u);
  }
}
TEST(RemoteDesktopLayout, TimeoutBlocksNewRequestsUntilLateReplyWithoutDoubleCompletion)
{
  rdr::MemOutStream wire, output; handshake(wire);
  reply(wire,rfb::reasonServer,0,layout(2)); reply(wire,rfb::reasonOtherClient,0,layout(3));
  reply(wire,rfb::reasonClient,0,layout(4));
  rdr::MemInStream input(wire.data(),wire.length());
  auto now = SessionScheduler::TimePoint{}; SessionTiming timing;
  timing.now = [&] { return now; }; timing.desktopResizeTimeout = std::chrono::milliseconds(10);
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}),{},{},nullptr,{},timing);
  auto events = session.subscribeEvents(); session.start("fixture",input,output); through(session,1); drain(events);
  auto operation = session.requestDesktopLayout(layout(),0,123); ASSERT_NE(operation,0u);
  now += timing.desktopResizeTimeout; session.dispatchScheduled();
  auto done = completions(events); ASSERT_EQ(done.size(),1u);
  EXPECT_EQ(done[0].operation,operation); EXPECT_EQ(done[0].failure,OperationFailure::TimedOut);
  EXPECT_EQ(done[0].origin,123u); EXPECT_TRUE(done[0].snapshot.resizePending);
  const auto length = output.length(); EXPECT_EQ(session.requestDesktopLayout(layout(5)),0u);
  EXPECT_EQ(output.length(),length);
  through(session,2); EXPECT_TRUE(events->snapshot().resizePending); EXPECT_TRUE(completions(events).empty());
  through(session,3); EXPECT_FALSE(events->snapshot().resizePending); EXPECT_TRUE(completions(events).empty());
  EXPECT_NE(session.requestDesktopLayout(layout(5)),0u);
}
TEST(RemoteDesktopLayout, AdmissionChecksSupportViewOnlyBudgetAndReservedOperation)
{
  rdr::MemOutStream wire, output; handshake(wire); wire.writeU8(2);
  reply(wire,rfb::reasonServer,0,layout(2));
  rdr::MemInStream input(wire.data(),wire.length());
  SessionBufferLimits limits; limits.framebufferBytes = 16;
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}),{},limits);
  auto events = session.subscribeEvents(); session.start("fixture",input,output); through(session,1);
  EXPECT_FALSE(events->snapshot().supportsDesktopResize); EXPECT_EQ(session.requestDesktopLayout(layout(2)),0u);
  through(session,2); drain(events); const auto before = output.length();
  EXPECT_EQ(session.requestDesktopLayout(layout(3)),0u);
  session.inputQueue()->setViewOnly(true); EXPECT_EQ(session.requestDesktopLayout(layout(2)),0u);
  session.inputQueue()->setViewOnly(false); EXPECT_EQ(session.requestDesktopLayout(layout(2),9999),0u);
  EXPECT_EQ(output.length(),before);
  const auto operation = events->reserve(events->snapshot().generation,19);
  EXPECT_EQ(session.requestDesktopLayout(layout(2),operation),operation);
  session.close(); auto done = completions(events); ASSERT_EQ(done.size(),1u);
  EXPECT_EQ(done[0].result,OperationResult::Cancelled); EXPECT_EQ(done[0].origin,19u);
  EXPECT_FALSE(events->snapshot().supportsDesktopResize); EXPECT_FALSE(events->snapshot().layout);
}
TEST(RemoteDesktopLayout, SameDimensionsCanChangeScreenTopology)
{
  rdr::MemOutStream wire, output; handshake(wire);
  reply(wire,rfb::reasonServer,0,layout(2));
  const RemoteDesktopLayout split(2,2,{{4,0,0,1,2,0},{5,1,0,1,2,0}});
  reply(wire,rfb::reasonClient,0,split);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone})); auto events = session.subscribeEvents();
  session.start("fixture",input,output); through(session,1); drain(events);
  ASSERT_NE(session.requestDesktopLayout(split),0u); through(session,2);
  auto done = completions(events); ASSERT_EQ(done.size(),1u);
  EXPECT_EQ(done[0].result,OperationResult::Succeeded); EXPECT_EQ(done[0].snapshot.layout->screens().size(),2u);
}
TEST(RemoteDesktopLayout, CloseCancelsTimerAndReconnectClearsPendingCapability)
{
  rdr::MemOutStream wire, output; handshake(wire); reply(wire,rfb::reasonServer,0,layout(2));
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone})); auto events = session.subscribeEvents();
  session.start("fixture",input,output); through(session,1); drain(events);
  const auto operation = session.requestDesktopLayout(layout()); ASSERT_NE(operation,0u);
  const auto generation = events->snapshot().generation; session.close();
  auto done = completions(events); ASSERT_EQ(done.size(),1u); EXPECT_EQ(done[0].result,OperationResult::Cancelled);
  SessionScheduler::TimePoint deadline; EXPECT_FALSE(session.nextDeadline(deadline));
  rdr::MemOutStream next; handshake(next); next.writeU8(2); rdr::MemInStream again(next.data(),next.length());
  session.start("fixture",again,output); through(session,1);
  EXPECT_GT(events->snapshot().generation,generation); EXPECT_FALSE(events->snapshot().resizePending);
  EXPECT_FALSE(events->snapshot().supportsDesktopResize); EXPECT_EQ(session.requestDesktopLayout(layout()),0u);
  EXPECT_TRUE(completions(events).empty());
}
TEST(RemoteDesktopLayout, CompletionCapacityRejectsBeforeWriting)
{
  rdr::MemOutStream wire, output; handshake(wire); reply(wire,rfb::reasonServer,0,layout(2));
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone})); auto events = session.subscribeEvents();
  session.start("fixture",input,output); through(session,1); drain(events);
  std::vector<uint64_t> reserved;
  while (auto id = events->reserve(events->snapshot().generation)) reserved.push_back(id);
  const auto length = output.length(); EXPECT_EQ(session.requestDesktopLayout(layout()),0u);
  EXPECT_EQ(output.length(),length); EXPECT_FALSE(events->snapshot().resizePending);
  for (auto id : reserved) events->complete(id,OperationResult::Cancelled);
  drain(events); EXPECT_NE(session.requestDesktopLayout(layout()),0u);
}
TEST(RemoteDesktopLayout, WriteFailureSettlesReservationAndCancelsDeadline)
{
  struct Output : rdr::MemOutStream {
    bool fail = false;
    void flush() override { if (fail) throw std::runtime_error("fixture write failure"); }
  } output;
  rdr::MemOutStream wire; handshake(wire); reply(wire,rfb::reasonServer,0,layout(2));
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone})); auto events = session.subscribeEvents();
  session.start("fixture",input,output); through(session,1); drain(events);
  auto operation = events->reserve(events->snapshot().generation,91); output.fail = true;
  EXPECT_THROW(session.requestDesktopLayout(layout(),operation),std::runtime_error);
  const auto done = completions(events); ASSERT_EQ(done.size(),1u);
  EXPECT_EQ(done[0].operation,operation); EXPECT_EQ(done[0].origin,91u);
  EXPECT_EQ(done[0].result,OperationResult::Failed);
  EXPECT_FALSE(session.desktop().active); EXPECT_FALSE(events->snapshot().resizePending);
  SessionScheduler::TimePoint deadline; EXPECT_FALSE(session.nextDeadline(deadline));
}
TEST(RemoteDesktopLayout, RejectsInvalidResizeDeadline)
{
  for (auto milliseconds : {0,60001}) {
    SessionTiming timing; timing.desktopResizeTimeout = std::chrono::milliseconds(milliseconds);
    EXPECT_THROW(ProtocolSession(rfb::SecurityClient({rfb::secTypeNone}),{},{},nullptr,{},timing),std::invalid_argument);
  }
}
