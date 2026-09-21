/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/ProtocolSession.h>
#include <rfb/PixelFormat.h>
#include <rfb/encodings.h>
#include <rfb/Exception.h>
#include <rdr/MemInStream.h>
#include <rdr/MemOutStream.h>
#include <limits>

using namespace viewer;
namespace {
void handshake(rdr::MemOutStream& wire, int width = 2, int height = 2, const std::string& name = "fixture")
{
  const char version[] = "RFB 003.008\n";
  wire.writeBytes(reinterpret_cast<const uint8_t*>(version), 12);
  wire.writeU8(1); wire.writeU8(rfb::secTypeNone); wire.writeU32(0);
  wire.writeU16(width); wire.writeU16(height);
  rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0).write(&wire);
  wire.writeU32(name.size()); wire.writeBytes(reinterpret_cast<const uint8_t*>(name.data()),name.size());
}
void update(rdr::MemOutStream& wire, unsigned rectangles)
{
  wire.writeU8(0); wire.pad(1); wire.writeU16(rectangles);
}
void rect(rdr::MemOutStream& wire, int x, int y, int width, int height, int encoding)
{
  wire.writeU16(x); wire.writeU16(y); wire.writeU16(width); wire.writeU16(height);
  wire.writeU32(encoding);
}
void raw(rdr::MemOutStream& wire, int x, int y, int width, int height, uint8_t value)
{
  rect(wire,x,y,width,height,rfb::encodingRaw);
  for (int i = 0; i < width*height; ++i) {
    wire.writeU8(value); wire.writeU8(value+1); wire.writeU8(value+2); wire.writeU8(0);
  }
}
void bell(rdr::MemOutStream& wire) { wire.writeU8(2); }
void ready(ProtocolSession& session)
{
  for (int i = 0; !session.desktop().ready && i < 16; ++i)
    ASSERT_TRUE(session.processMessage());
  ASSERT_TRUE(session.desktop().ready);
}
void throughBell(ProtocolSession& session, uint64_t count)
{
  for (int i = 0; session.desktop().bells < count && i < 32; ++i)
    ASSERT_TRUE(session.processMessage());
  ASSERT_EQ(session.desktop().bells, count);
}
}

TEST(ProtocolSession, NegotiatedInformationIsBoundedImmutableAndAttemptScoped)
{
  rdr::MemOutStream wire, output;
  handshake(wire,2,2,std::string(1100,'x'));
  update(wire,1); raw(wire,0,0,2,2,10); bell(wire);
  update(wire,1); rect(wire,0,0,1,1,rfb::encodingCopyRect); wire.writeU16(1); wire.writeU16(1); bell(wire);
  rdr::MemInStream input(wire.data(),wire.length());
  rfb::SecurityClient security({rfb::secTypeNone}); ProtocolSession session(security);
  auto events = session.subscribeEvents();
  EXPECT_FALSE(events->snapshot().information);
  session.start("private-endpoint",input,output); ready(session);
  auto initial = events->snapshot().information;
  ASSERT_TRUE(initial); EXPECT_EQ(initial->protocolMajor,3u); EXPECT_EQ(initial->protocolMinor,8u);
  EXPECT_EQ(initial->securityType,rfb::secTypeNone); EXPECT_FALSE(initial->secure);
  EXPECT_EQ(initial->pixelFormat.bpp,32); EXPECT_EQ(initial->pixelFormat.depth,24);
  EXPECT_EQ(initial->lastEncoding,-1); EXPECT_EQ(initial->requestedEncoding,rfb::encodingTight);
  EXPECT_TRUE(initial->nameTruncated); EXPECT_EQ(std::string(initial->desktopName.data()),std::string(1024,'x'));
  throughBell(session,2);
  auto latest = events->snapshot().information; ASSERT_TRUE(latest);
  EXPECT_EQ(latest->lastEncoding,rfb::encodingRaw); EXPECT_GT(latest->bitsPerSecond,0u);
  EXPECT_EQ(initial->lastEncoding,-1); // A published value cannot change under readers.
  session.close(); EXPECT_FALSE(events->snapshot().information);
  rdr::MemOutStream nextWire, nextOutput; handshake(nextWire,2,2,"next desktop");
  rdr::MemInStream nextInput(nextWire.data(),nextWire.length());
  session.start("other-private-endpoint",nextInput,nextOutput); ready(session);
  auto next = events->snapshot().information; ASSERT_TRUE(next);
  EXPECT_EQ(std::string(next->desktopName.data()),"next desktop"); EXPECT_FALSE(next->nameTruncated);
  EXPECT_EQ(next->lastEncoding,-1); EXPECT_EQ(latest->lastEncoding,rfb::encodingRaw);
}

TEST(ProtocolSession, DecodesRawAndCopyRectForIndependentViews)
{
  rdr::MemOutStream wire, output;
  handshake(wire);
  update(wire,1); raw(wire,0,0,2,2,10); bell(wire);
  update(wire,2); raw(wire,0,0,1,1,20);
  rect(wire,1,1,1,1,rfb::encodingCopyRect); wire.writeU16(0); wire.writeU16(0); bell(wire);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
  auto first = session.attachView(), second = session.attachView();
  session.start("fixture",input,output);
  ready(session);
  EXPECT_EQ(session.desktop().name,"fixture");
  throughBell(session,1);
  ViewUpdate a,b;
  ASSERT_TRUE(first->take(a)); ASSERT_TRUE(second->take(b));
  EXPECT_EQ(a.frame,b.frame);
  EXPECT_EQ(a.frame->pixels.data()[0],10);
  auto held = a.frame;
  first.reset(); // Detaching a view must not affect protocol or other consumers.
  throughBell(session,2);
  ASSERT_TRUE(second->take(b));
  EXPECT_EQ(b.frame->pixels.data()[0],20);
  EXPECT_EQ(b.frame->pixels.data()[12],20);
  EXPECT_EQ(held->pixels.data()[0],10);
  auto late = session.attachView();
  ASSERT_TRUE(late->take(a));
  EXPECT_EQ(a.frame,b.frame);
  EXPECT_EQ(a.damage.width,2u); EXPECT_EQ(a.damage.height,2u);
}

TEST(ProtocolSession, ResizePreservesOverlapAndPublishesFullDamage)
{
  rdr::MemOutStream wire, output;
  handshake(wire);
  update(wire,1); raw(wire,0,0,2,2,10); bell(wire);
  update(wire,1); rect(wire,0,0,3,2,rfb::pseudoEncodingDesktopSize); bell(wire);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
  auto view = session.attachView();
  session.start("fixture",input,output);
  throughBell(session,1);
  ViewUpdate data;
  ASSERT_TRUE(view->take(data)); auto old = data.frame;
  throughBell(session,2);
  ASSERT_TRUE(view->take(data));
  EXPECT_EQ(session.desktop().width,3u);
  EXPECT_EQ(data.frame->pixels.stride(),12u);
  EXPECT_GT(data.frame->sizeGeneration,old->sizeGeneration);
  EXPECT_EQ(data.damage.width,3u); EXPECT_EQ(data.damage.height,2u);
  EXPECT_EQ(data.frame->pixels.data()[0],10);
  EXPECT_EQ(data.frame->pixels.data()[8],0);
  EXPECT_EQ(old->pixels.width(),2u);
}

TEST(ProtocolSession, CursorShapeAndHideUseRetainedRgba)
{
  rdr::MemOutStream wire, output;
  handshake(wire);
  update(wire,1);
  rect(wire,0,0,1,1,rfb::pseudoEncodingCursor);
  wire.writeU8(10); wire.writeU8(20); wire.writeU8(30); wire.writeU8(0);
  wire.writeU8(0x80); bell(wire);
  update(wire,1); rect(wire,0,0,0,0,rfb::pseudoEncodingCursor); bell(wire);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
  auto view = session.attachView(); session.start("fixture",input,output);
  throughBell(session,1);
  ViewUpdate data;
  ASSERT_TRUE(view->take(data)); ASSERT_TRUE(data.cursor);
  auto held = data.cursor;
  EXPECT_EQ(held->pixels.format(),PixelFormat::RGBA8);
  EXPECT_EQ(held->pixels.alpha(),AlphaMode::Straight);
  EXPECT_EQ(held->pixels.data()[0],30); EXPECT_EQ(held->pixels.data()[3],255);
  throughBell(session,2);
  ASSERT_TRUE(view->take(data)); EXPECT_TRUE(data.cursorChanged); EXPECT_FALSE(data.cursor);
  EXPECT_EQ(held->pixels.data()[2],10);
}

TEST(ProtocolSession, BackpressureRetriesLatestCompleteFrameWithoutNetworkInput)
{
  rdr::MemOutStream wire, output;
  handshake(wire);
  update(wire,1); raw(wire,0,0,2,2,10); bell(wire);
  update(wire,1); raw(wire,0,0,2,2,20); bell(wire);
  rdr::MemInStream input(wire.data(),wire.length());
  SessionBufferLimits limits; limits.publicationBytes=32;
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}),{},limits);
  auto view = session.attachView(); session.start("fixture",input,output);
  ready(session);
  ViewUpdate data;
  ASSERT_TRUE(view->take(data)); auto initial = data.frame; data=ViewUpdate();
  throughBell(session,1);
  ASSERT_TRUE(view->take(data));
  EXPECT_EQ(data.frame->pixels.data()[0],10);
  throughBell(session,2);
  EXPECT_FALSE(view->take(data));
  EXPECT_FALSE(session.retryPublication());
  initial.reset();
  EXPECT_TRUE(session.retryPublication());
  ASSERT_TRUE(view->take(data));
  EXPECT_EQ(data.frame->pixels.data()[0],20);
  EXPECT_LE(session.publicationBytesInUse(),32u);
}

TEST(ProtocolSession, CloseReconnectAndDestructionKeepLeasesSafe)
{
  FrameLease held;
  std::shared_ptr<FrameSubscription> view;
  rdr::MemOutStream wire, output;
  handshake(wire); update(wire,1); raw(wire,0,0,2,2,11); bell(wire);
  rdr::MemInStream input(wire.data(),wire.length());
  {
    ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
    view=session.attachView(); session.start("fixture",input,output);
    EXPECT_THROW(session.start("fixture",input,output),std::logic_error);
    throughBell(session,1);
    ViewUpdate data; ASSERT_TRUE(view->take(data)); held=data.frame;
    session.close(); session.close();
    EXPECT_FALSE(session.desktop().active);
    ASSERT_TRUE(view->take(data)); EXPECT_FALSE(data.frame);
    EXPECT_EQ(data.generation,2u);
    EXPECT_THROW(session.processMessage(),std::logic_error);
    input.reposition(0);
    session.start("fixture",input,output);
    throughBell(session,1);
    ASSERT_TRUE(view->take(data)); EXPECT_EQ(data.frame->generation,2u);
    EXPECT_EQ(held->generation,1u);
  }
  ViewUpdate clear; ASSERT_TRUE(view->take(clear)); EXPECT_FALSE(clear.frame);
  EXPECT_EQ(held->pixels.data()[0],11);
}

TEST(ProtocolSession, OversizedResizeClosesAttemptAndPreservesOldLease)
{
  rdr::MemOutStream wire, output;
  handshake(wire); update(wire,1); raw(wire,0,0,2,2,10); bell(wire);
  update(wire,1); rect(wire,0,0,8,8,rfb::pseudoEncodingDesktopSize);
  rdr::MemInStream input(wire.data(),wire.length());
  SessionBufferLimits limits; limits.framebufferBytes=32;
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}),{},limits);
  auto view=session.attachView(); session.start("fixture",input,output);
  throughBell(session,1);
  ViewUpdate data; ASSERT_TRUE(view->take(data)); auto held=data.frame;
  EXPECT_THROW({ for (int i=0;i<8;++i) session.processMessage(); },std::length_error);
  EXPECT_FALSE(session.desktop().active);
  ASSERT_TRUE(view->take(data)); EXPECT_FALSE(data.frame);
  EXPECT_EQ(held->pixels.data()[0],10);
}

TEST(ProtocolSession, PublicationWaitsForCompleteUpdate)
{
  rdr::MemOutStream wire, output;
  handshake(wire); update(wire,2);
  raw(wire,0,0,1,1,10); raw(wire,1,1,1,1,20); bell(wire);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
  auto view=session.attachView(); session.start("fixture",input,output);
  ready(session);
  ViewUpdate data; ASSERT_TRUE(view->take(data));
  ASSERT_TRUE(session.processMessage()); // Update header; two rectangles pending.
  EXPECT_FALSE(session.retryPublication());
  EXPECT_FALSE(view->take(data));
  throughBell(session,1);
  ASSERT_TRUE(view->take(data));
  EXPECT_EQ(data.frame->pixels.data()[0],10);
  EXPECT_EQ(data.frame->pixels.data()[12],20);
}

TEST(ProtocolSession, MissingCredentialHandlerFailsClosedWithoutWidgets)
{
  rdr::MemOutStream wire, output;
  wire.writeBytes(reinterpret_cast<const uint8_t*>("RFB 003.008\n"),12);
  wire.writeU8(1); wire.writeU8(rfb::secTypeVncAuth); wire.pad(16);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeVncAuth}));
  auto view=session.attachView();
  EXPECT_THROW(session.start(std::string("a\0b",3),input,output),std::invalid_argument);
  session.start("fixture",input,output);
  EXPECT_THROW({ for (int i=0;i<16;++i) session.processMessage(); },rfb::auth_cancelled);
  EXPECT_FALSE(session.desktop().active);
  ViewUpdate clear; ASSERT_TRUE(view->take(clear));
  EXPECT_EQ(clear.generation,2u); EXPECT_FALSE(clear.frame);
}

TEST(ProtocolSession, CredentialHandlerCompletesRealVncHandshakeAndCannotReenterClose)
{
  struct Authentication : SessionAuthentication {
    ProtocolSession* session = nullptr;
    unsigned calls = 0;
    void credentials(bool secure, std::string* user, std::string* password) override {
      EXPECT_FALSE(secure); EXPECT_EQ(user,nullptr);
      EXPECT_THROW(session->close(),std::logic_error);
      *password="fixture-password";
      ++calls;
    }
  };
  auto auth=std::make_shared<Authentication>();
  rdr::MemOutStream initialization, wire, output;
  handshake(initialization);
  wire.writeBytes(reinterpret_cast<const uint8_t*>("RFB 003.008\n"),12);
  wire.writeU8(1); wire.writeU8(rfb::secTypeVncAuth); wire.pad(16);
  // Copy SecurityResult and ServerInit from the None fixture.
  wire.writeBytes(initialization.data()+14,initialization.length()-14);
  bell(wire);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeVncAuth}),{},{},auth);
  auth->session=&session;
  session.start("fixture",input,output);
  throughBell(session,1);
  EXPECT_EQ(auth->calls,1u);
  EXPECT_TRUE(session.desktop().ready);
  ASSERT_GE(output.length(),30u); // Version + type + DES response + ClientInit.
  bool nonzero=false;
  for (size_t i=13;i<29;++i) nonzero |= output.data()[i]!=0;
  EXPECT_TRUE(nonzero);
}

TEST(ProtocolSession, RejectsDimensionsThatOverflowUnderlyingRfbAllocation)
{
  rdr::MemOutStream wire, output;
  handshake(wire,65535,65535);
  rdr::MemInStream input(wire.data(),wire.length());
  SessionBufferLimits limits;
  limits.framebufferBytes=std::numeric_limits<size_t>::max();
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}),{},limits);
  session.start("fixture",input,output);
  EXPECT_THROW({ for(int i=0;i<16;++i) session.processMessage(); },std::length_error);
  EXPECT_FALSE(session.desktop().active);
  EXPECT_EQ(session.publicationBytesInUse(),0u);
}

TEST(ProtocolSession, EventSubscriptionStartsWithCurrentConnectedSnapshot)
{
  rdr::MemOutStream wire,output; handshake(wire);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
  session.start("fixture",input,output); ready(session);
  auto events=session.subscribeEvents();
  SessionEvent event; ASSERT_TRUE(events->take(event));
  EXPECT_EQ(event.kind,SessionEventKind::Snapshot);
  EXPECT_EQ(event.snapshot.state,SessionState::Connected); EXPECT_EQ(event.snapshot.width,2u);
  EXPECT_THROW(session.subscribeEvents(),std::logic_error);
  session.close(); ASSERT_TRUE(events->take(event));
  EXPECT_EQ(event.snapshot.state,SessionState::Closed);
}
TEST(ProtocolSession, RefreshCompletionIsReservedAndDeliveredExactlyOnce)
{
  rdr::MemOutStream wire,output; handshake(wire);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
  EXPECT_EQ(session.requestRefresh(),0u);
  session.start("fixture",input,output); ready(session);
  auto events=session.subscribeEvents(2); // Snapshot plus one completion.
  auto operation=session.requestRefresh(); ASSERT_NE(operation,0u);
  EXPECT_EQ(session.requestRefresh(),0u);
  SessionEvent event; ASSERT_TRUE(events->take(event)); ASSERT_TRUE(events->take(event));
  EXPECT_EQ(event.kind,SessionEventKind::Completion); EXPECT_EQ(event.operation,operation);
  EXPECT_EQ(event.result,OperationResult::Succeeded); EXPECT_FALSE(events->take(event));
  EXPECT_GT(session.requestRefresh(),operation);
}
TEST(ProtocolSession, ReservedCommandsRequirePendingIdentityAndLeaveCompletionToHost)
{
  rdr::MemOutStream wire, output; handshake(wire);
  rdr::MemInStream input(wire.data(), wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
  session.start("fixture", input, output); ready(session);
  auto events = session.subscribeEvents(4);
  auto id = events->reserve(session.desktop().generation);
  ASSERT_NE(id, 0u);
  EXPECT_EQ(session.requestRefresh(id + 1), 0u);
  EXPECT_EQ(session.requestRefresh(id), id);
  EXPECT_TRUE(events->pending(id, 1));
  EXPECT_FALSE(events->pending(id, 2));
  EXPECT_TRUE(events->complete(id, OperationResult::Succeeded));
  auto changed = session.encodingOptions().withPatch({{"QualityLevel", "3"}}, OptionSource::Session);
  EXPECT_EQ(session.applyEncodingOptions(changed, id), 0u);
  EXPECT_EQ(session.encodingOptions().qualityLevel(), 8);
  id = events->reserve(1); ASSERT_NE(id, 0u);
  EXPECT_EQ(session.applyEncodingOptions(changed, id), id);
  EXPECT_EQ(session.encodingOptions().qualityLevel(), 3);
  EXPECT_TRUE(events->pending(id, 1));
  EXPECT_TRUE(events->complete(id, OperationResult::Succeeded));
}
TEST(ProtocolSession, HostTerminalOwnershipCleansResourcesWithoutPublishingPrematureFailure)
{
  rdr::MemOutStream wire, output; handshake(wire);
  rdr::MemInStream input(wire.data(), wire.length());
  std::shared_ptr<SessionEvents> events;
  {
    ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr, {}, {},
                            SessionTerminalOwnership::Host);
    events = session.subscribeEvents();
    session.start("fixture", input, output); ready(session);
    const auto operation = events->reserve(1);
    session.close(true);
    EXPECT_FALSE(session.desktop().active);
    EXPECT_EQ(session.snapshot().state, SessionState::Failed);
    EXPECT_EQ(events->snapshot().state, SessionState::Connected);
    EXPECT_TRUE(events->pending(operation, 1));
    EXPECT_TRUE(events->complete(operation, OperationResult::Failed));
  }
  EXPECT_FALSE(events->sealed());
  auto terminal = events->snapshot(); terminal.state = SessionState::Failed;
  terminal.endReason = SessionEndReason::TransportFailure;
  EXPECT_TRUE(events->publish(SessionEventKind::State, terminal));
  events->seal(OperationResult::Failed);
  EXPECT_TRUE(events->sealed());
}
TEST(ProtocolSession, EventOverflowClosesAttemptAndReleasesHeldInput)
{
  rdr::MemOutStream wire,output; handshake(wire); bell(wire); bell(wire);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
  session.start("fixture",input,output); ready(session);
  auto events=session.subscribeEvents(2);
  auto queue=session.inputQueue(); queue->key(1,1,'a',0,true); session.drainInput();
  const auto before=output.length();
  ASSERT_TRUE(session.processMessage()); // First bell fills the queue.
  EXPECT_THROW(session.processMessage(),std::runtime_error);
  EXPECT_FALSE(session.desktop().active); EXPECT_FALSE(queue->status().connected);
  ASSERT_EQ(output.length()-before,8u); EXPECT_EQ(output.data()[before],4);
  EXPECT_EQ(output.data()[before+1],0); // Real RFB key release during teardown.
  SessionEvent event; ASSERT_TRUE(events->take(event)); ASSERT_TRUE(events->take(event));
  ASSERT_TRUE(events->take(event)); EXPECT_EQ(event.kind,SessionEventKind::Overflow);
  EXPECT_FALSE(events->take(event));
}
TEST(ProtocolSession, EventStreamSurvivesReconnectWithOrderedGenerations)
{
  rdr::MemOutStream wire,output; handshake(wire);
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
  auto events=session.subscribeEvents();
  for (int i=0;i<2;++i) {
    rdr::MemInStream input(wire.data(),wire.length());
    session.start("fixture",input,output); ready(session); session.close();
  }
  SessionEvent event; uint64_t sequence=0,generation=0; unsigned connected=0,closed=0;
  while (events->take(event)) {
    EXPECT_GT(event.sequence,sequence); EXPECT_GE(event.snapshot.generation,generation);
    sequence=event.sequence; generation=event.snapshot.generation;
    connected += event.snapshot.state==SessionState::Connected;
    closed += event.snapshot.state==SessionState::Closed;
  }
  EXPECT_EQ(connected,2u); EXPECT_EQ(closed,2u); EXPECT_EQ(generation,2u);
}
TEST(ProtocolSession, FrameStatisticsCoalesceAndRetainedEventsSealOnDestruction)
{
  SessionScheduler::TimePoint now{};
  SessionTiming timing; timing.now = [&] { return now; };
  std::shared_ptr<SessionEvents> events;
  rdr::MemOutStream wire,output; handshake(wire);
  for (int i=0;i<10;++i) { update(wire,1); raw(wire,0,0,1,1,i); }
  bell(wire);
  rdr::MemInStream input(wire.data(),wire.length());
  {
    ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr, {}, timing);
    session.start("fixture",input,output); ready(session);
    events=session.subscribeEvents(4); throughBell(session,1);
    EXPECT_EQ(events->snapshot().frames,10u);
    now += timing.statisticsInterval;
    EXPECT_EQ(session.dispatchScheduled(), 1u);
  }
  EXPECT_TRUE(events->sealed());
  SessionEvent event; unsigned statistics=0,closed=0;
  while (events->take(event)) {
    if (event.kind==SessionEventKind::Statistics) { ++statistics; EXPECT_EQ(event.snapshot.frames,10u); }
    closed += event.snapshot.state==SessionState::Closed;
  }
  EXPECT_EQ(statistics,1u); EXPECT_EQ(closed,1u);
}

TEST(ProtocolSession, DesktopEventCarriesResizedDimensionsAndQueueCanBeReplacedAfterSeal)
{
  rdr::MemOutStream wire,output; handshake(wire);
  update(wire,1); rect(wire,0,0,3,4,rfb::pseudoEncodingDesktopSize); bell(wire);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
  session.start("fixture",input,output); ready(session);
  auto events=session.subscribeEvents(2);
  SessionEvent event; ASSERT_TRUE(events->take(event));
  throughBell(session,1); // Desktop + Bell; obsolete statistics can be reclaimed.
  ASSERT_TRUE(events->take(event)); EXPECT_EQ(event.kind,SessionEventKind::Desktop);
  EXPECT_EQ(event.snapshot.width,3u); EXPECT_EQ(event.snapshot.height,4u);
  ASSERT_TRUE(events->take(event)); EXPECT_EQ(event.kind,SessionEventKind::Bell);
  // Release the coordinator on its owning executor. Existing data stays readable.
  events->seal(OperationResult::Cancelled);
  auto replacement=session.subscribeEvents();
  ASSERT_TRUE(replacement->take(event)); EXPECT_EQ(event.kind,SessionEventKind::Snapshot);
  EXPECT_EQ(event.snapshot.width,3u); EXPECT_EQ(event.snapshot.bells,1u);
}
TEST(ProtocolSession, EventAdmissionFailureDuringStartLeavesNoLiveAttempt)
{
  rdr::MemOutStream wire,output; handshake(wire);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
  auto events=session.subscribeEvents(2);
  ASSERT_NE(events->reserve(1),0u); // Snapshot and promised completion occupy the stream.
  EXPECT_THROW(session.start("fixture",input,output),std::runtime_error);
  EXPECT_FALSE(session.desktop().active); EXPECT_TRUE(events->sealed());
  EXPECT_FALSE(session.inputQueue()->status().connected);
  SessionEvent event; ASSERT_TRUE(events->take(event)); ASSERT_TRUE(events->take(event));
  EXPECT_EQ(event.kind,SessionEventKind::Completion); EXPECT_EQ(event.result,OperationResult::Failed);
  ASSERT_TRUE(events->take(event)); EXPECT_EQ(event.kind,SessionEventKind::Overflow);
  auto replacement=session.subscribeEvents();
  ASSERT_TRUE(replacement->take(event)); EXPECT_EQ(event.snapshot.state,SessionState::Failed);
}

TEST(ProtocolSession, StatisticsUseOneMonotonicDeadlineAndStopWhenIdle)
{
  SessionScheduler::TimePoint now{}, deadline;
  SessionTiming timing; timing.now = [&] { return now; };
  rdr::MemOutStream wire, output; handshake(wire);
  for (int i = 0; i < 3; ++i) { update(wire,1); raw(wire,0,0,1,1,i); bell(wire); }
  rdr::MemInStream input(wire.data(), wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr, {}, timing);
  auto events = session.subscribeEvents();
  session.start("fixture", input, output); ready(session);
  SessionEvent event; while (events->take(event)) {}
  EXPECT_THROW(session.dispatchScheduled(0), std::invalid_argument);
  EXPECT_TRUE(session.desktop().ready);
  throughBell(session, 1);
  ASSERT_TRUE(session.nextDeadline(deadline));
  EXPECT_EQ(deadline, SessionScheduler::TimePoint{} + timing.statisticsInterval);
  while (events->take(event)) EXPECT_NE(event.kind, SessionEventKind::Statistics);
  now += std::chrono::milliseconds(99);
  EXPECT_EQ(session.dispatchScheduled(), 0u);
  throughBell(session, 2);
  ASSERT_TRUE(session.nextDeadline(deadline));
  EXPECT_EQ(deadline, SessionScheduler::TimePoint{} + timing.statisticsInterval);
  while (events->take(event)) EXPECT_NE(event.kind, SessionEventKind::Statistics);
  now += std::chrono::milliseconds(1);
  EXPECT_EQ(session.dispatchScheduled(), 1u);
  ASSERT_TRUE(events->take(event)); EXPECT_EQ(event.kind, SessionEventKind::Statistics);
  EXPECT_EQ(event.snapshot.frames, 2u); EXPECT_FALSE(events->take(event));
  ASSERT_TRUE(event.snapshot.information); EXPECT_EQ(event.snapshot.information->lastEncoding,rfb::encodingRaw);
  EXPECT_FALSE(session.nextDeadline(deadline)); EXPECT_EQ(session.dispatchScheduled(), 0u);
  throughBell(session, 3);
  ASSERT_TRUE(session.nextDeadline(deadline)); EXPECT_EQ(deadline, now + timing.statisticsInterval);
}

TEST(ProtocolSession, TimedBackpressureRetriesWithoutNewNetworkData)
{
  SessionScheduler::TimePoint now{}, deadline;
  SessionTiming timing; timing.now = [&] { return now; };
  SessionBufferLimits limits; limits.publicationBytes = 32;
  rdr::MemOutStream wire, output; handshake(wire);
  update(wire,1); raw(wire,0,0,2,2,10); bell(wire);
  update(wire,1); raw(wire,0,0,2,2,20); bell(wire);
  rdr::MemInStream input(wire.data(), wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}), {}, limits, nullptr, {}, timing);
  auto view = session.attachView(); session.start("fixture", input, output); ready(session);
  ViewUpdate frame; ASSERT_TRUE(view->take(frame)); auto initial = frame.frame; frame = {};
  throughBell(session, 1); ASSERT_TRUE(view->take(frame));
  throughBell(session, 2); EXPECT_FALSE(view->take(frame));
  ASSERT_TRUE(session.nextDeadline(deadline)); EXPECT_EQ(deadline, now + timing.publicationRetryInterval);
  now = deadline; EXPECT_EQ(session.dispatchScheduled(), 1u); // Still at the budget limit.
  EXPECT_EQ(session.dispatchScheduled(), 0u); // No busy retry at the same time.
  ASSERT_TRUE(session.nextDeadline(deadline)); EXPECT_EQ(deadline, now + timing.publicationRetryInterval);
  initial.reset(); now = deadline;
  EXPECT_EQ(session.dispatchScheduled(), 1u);
  ASSERT_TRUE(view->take(frame)); EXPECT_EQ(frame.frame->pixels.data()[0], 20);
  EXPECT_FALSE(session.nextDeadline(deadline));
}

TEST(ProtocolSession, TimerCannotPublishAnIncompleteUpdateAndNaturalPublicationCancelsRetry)
{
  SessionScheduler::TimePoint now{}, deadline;
  SessionTiming timing; timing.now = [&] { return now; };
  rdr::MemOutStream wire, output; handshake(wire); update(wire,2);
  raw(wire,0,0,1,1,10); raw(wire,1,1,1,1,20); bell(wire);
  rdr::MemInStream input(wire.data(), wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr, {}, timing);
  auto view = session.attachView(); session.start("fixture", input, output); ready(session);
  ViewUpdate frame; ASSERT_TRUE(view->take(frame));
  ASSERT_TRUE(session.processMessage()); // Only the update header has arrived.
  EXPECT_FALSE(session.retryPublication());
  ASSERT_TRUE(session.nextDeadline(deadline)); now = deadline;
  EXPECT_EQ(session.dispatchScheduled(), 1u); EXPECT_FALSE(view->take(frame));
  ASSERT_TRUE(session.nextDeadline(deadline));
  throughBell(session, 1); ASSERT_TRUE(view->take(frame));
  EXPECT_EQ(frame.frame->pixels.data()[12], 20);
  EXPECT_FALSE(session.nextDeadline(deadline));
}

TEST(ProtocolSession, CloseAndReconnectDiscardBothTimerKinds)
{
  SessionScheduler::TimePoint now{}, deadline;
  SessionTiming timing; timing.now = [&] { return now; };
  SessionBufferLimits limits; limits.publicationBytes = 16;
  rdr::MemOutStream wire, output; handshake(wire);
  update(wire,1); raw(wire,0,0,2,2,10); bell(wire);
  rdr::MemInStream input(wire.data(), wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}), {}, limits, nullptr, {}, timing);
  auto events = session.subscribeEvents();
  session.start("fixture", input, output); throughBell(session, 1);
  ASSERT_TRUE(session.nextDeadline(deadline));
  session.close(); session.close();
  EXPECT_FALSE(session.nextDeadline(deadline));
  now += std::chrono::seconds(1); EXPECT_EQ(session.dispatchScheduled(), 0u);
  SessionEvent event; while (events->take(event)) EXPECT_NE(event.kind, SessionEventKind::Statistics);
  input.reposition(0); session.start("fixture", input, output); ready(session);
  EXPECT_EQ(session.desktop().generation, 2u);
  EXPECT_EQ(session.dispatchScheduled(), 0u); EXPECT_FALSE(session.nextDeadline(deadline));
  throughBell(session, 1);
  ASSERT_TRUE(session.nextDeadline(deadline)); EXPECT_GT(deadline, now);
}

TEST(ProtocolSession, TimersAreIndependentBetweenSessions)
{
  SessionScheduler::TimePoint now{};
  SessionTiming quick, slow;
  quick.now = slow.now = [&] { return now; };
  slow.statisticsInterval = std::chrono::milliseconds(250);
  rdr::MemOutStream wire, firstOutput, secondOutput; handshake(wire);
  update(wire,1); raw(wire,0,0,2,2,10); bell(wire);
  rdr::MemInStream firstInput(wire.data(), wire.length()), secondInput(wire.data(), wire.length());
  ProtocolSession first(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr, {}, quick);
  ProtocolSession second(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr, {}, slow);
  auto firstEvents = first.subscribeEvents(), secondEvents = second.subscribeEvents();
  first.start("first", firstInput, firstOutput); second.start("second", secondInput, secondOutput);
  throughBell(first, 1); throughBell(second, 1);
  now += quick.statisticsInterval;
  EXPECT_EQ(first.dispatchScheduled(), 1u); EXPECT_EQ(second.dispatchScheduled(), 0u);
  first.close();
  now = SessionScheduler::TimePoint{} + slow.statisticsInterval;
  EXPECT_EQ(second.dispatchScheduled(), 1u); EXPECT_TRUE(second.desktop().ready);
  EXPECT_EQ(first.dispatchScheduled(), 0u);
}

TEST(ProtocolSession, TimerCallbackFailureClosesAttemptAndCancelsRemainingWork)
{
  SessionScheduler::TimePoint now{}, deadline;
  SessionTiming timing; timing.now = [&] { return now; };
  SessionBufferLimits limits; limits.publicationBytes = 16;
  rdr::MemOutStream wire, output; handshake(wire);
  update(wire,1); raw(wire,0,0,2,2,10); bell(wire);
  rdr::MemInStream input(wire.data(), wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}), {}, limits, nullptr, {}, timing);
  auto events = session.subscribeEvents();
  session.start("fixture", input, output); throughBell(session, 1);
  // The publication retry callback must reschedule; this clock cannot represent
  // another deadline. Its exception must unwind before destroying the attempt.
  now = SessionScheduler::TimePoint::max();
  EXPECT_THROW(session.dispatchScheduled(), std::overflow_error);
  EXPECT_FALSE(session.desktop().active); EXPECT_FALSE(session.nextDeadline(deadline));
  EXPECT_EQ(events->snapshot().state, SessionState::Failed);
  EXPECT_EQ(session.dispatchScheduled(), 0u);
}

TEST(ProtocolSession, RejectsInvalidTimingPolicy)
{
  SessionTiming timing;
  timing.now = {};
  EXPECT_THROW(ProtocolSession(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr, {}, timing), std::invalid_argument);
  timing = SessionTiming(); timing.statisticsInterval = std::chrono::milliseconds(0);
  EXPECT_THROW(ProtocolSession(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr, {}, timing), std::invalid_argument);
  timing = SessionTiming(); timing.publicationRetryInterval = std::chrono::seconds(61);
  EXPECT_THROW(ProtocolSession(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr, {}, timing), std::invalid_argument);
}

namespace {
void expectPointers(rdr::MemOutStream& output, std::initializer_list<std::array<int,3>> events)
{
  ASSERT_EQ(output.length(), events.size()*6);
  size_t offset = 0;
  for (const auto& event : events) {
    const auto* bytes = output.data()+offset;
    EXPECT_EQ(bytes[0],5); EXPECT_EQ(bytes[1],event[0]);
    EXPECT_EQ((bytes[2]<<8)|bytes[3],event[1]); EXPECT_EQ((bytes[4]<<8)|bytes[5],event[2]);
    offset += 6;
  }
  output.clear();
}
}
TEST(ProtocolSession, MiddleButtonDelayPreservesDragOriginAndLateChord)
{
  SessionScheduler::TimePoint now{};
  SessionTiming timing; timing.now = [&] { return now; };
  rdr::MemOutStream wire, output; handshake(wire,100,100);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr, {}, timing);
  session.start("fixture",input,output); ready(session); output.clear();
  const auto queue = session.inputQueue(); queue->setPolicy(false,true);
  queue->pointer(1,10,10,1); session.drainInput(); expectPointers(output,{{0,10,10}});
  queue->pointer(1,20,20,1); session.drainInput(); expectPointers(output,{});
  now += std::chrono::milliseconds(49); session.dispatchScheduled(); expectPointers(output,{});
  now += std::chrono::milliseconds(1); session.dispatchScheduled();
  expectPointers(output,{{1,10,10},{1,20,20}});
  queue->pointer(1,21,20,5); session.drainInput(); expectPointers(output,{{5,21,20}});
  queue->pointer(1,21,20,0); session.drainInput(); expectPointers(output,{{4,21,20},{0,21,20}});
  session.close();
}
TEST(ProtocolSession, MiddleButtonChordReleaseAndPhysicalWheelButtons)
{
  SessionScheduler::TimePoint now{};
  SessionTiming timing; timing.now = [&] { return now; };
  rdr::MemOutStream wire, output; handshake(wire,100,100);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr, {}, timing);
  session.start("fixture",input,output); ready(session); output.clear();
  const auto queue = session.inputQueue(); queue->setPolicy(false,true);
  queue->pointer(1,10,10,1); session.drainInput(); expectPointers(output,{{0,10,10}});
  queue->pointer(1,20,20,5); session.drainInput(); expectPointers(output,{{2,10,10}});
  queue->pointer(1,20,20,13); session.drainInput(); expectPointers(output,{{10,20,20}});
  queue->pointer(1,20,20,4); session.drainInput(); expectPointers(output,{{2,20,20}});
  queue->pointer(1,20,20,0); session.drainInput(); expectPointers(output,{{0,20,20}});
  now += std::chrono::milliseconds(60); session.dispatchScheduled(); expectPointers(output,{});
  queue->pointer(1,30,30,2); session.drainInput(); expectPointers(output,{{2,30,30}});
  session.close(); expectPointers(output,{{0,30,30}});
}
TEST(ProtocolSession, PendingMiddleButtonPressCannotCrossRoutingOrSessionLifetime)
{
  for (int mode = 0; mode < 7; ++mode) {
    SCOPED_TRACE(mode);
    SessionScheduler::TimePoint now{};
    SessionTiming timing; timing.now = [&] { return now; };
    rdr::MemOutStream wire, output; handshake(wire,100,100);
    rdr::MemInStream input(wire.data(),wire.length());
    ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr, {}, timing);
    session.start("fixture",input,output); ready(session); output.clear();
    const auto queue = session.inputQueue(); queue->setPolicy(false,true);
    queue->pointer(1,10,10,1); session.drainInput(); expectPointers(output,{{0,10,10}});
    switch (mode) {
    case 0: queue->setFocused(1,false); queue->setFocused(1,true); break;
    case 1: queue->setViewOnly(true); queue->setViewOnly(false); break;
    case 2: queue->setPolicy(false,false); queue->setPolicy(false,true); break;
    case 6: EXPECT_EQ(queue->releaseAll(1),InputResult::Accepted); EXPECT_TRUE(queue->status().focused); break;
    case 3: session.close(); break;
    case 4:
      session.close(); input.reposition(0);
      session.start("replacement",input,output); ready(session); output.clear(); break;
    case 5:
      for (size_t i = 0; i < 257; ++i) queue->key(1,1,'A',0,true);
      EXPECT_EQ(queue->status().overflows,1u); queue->setFocused(1,true); break;
    }
    now += std::chrono::milliseconds(60); session.dispatchScheduled();
    session.drainInput(); expectPointers(output,{});
    session.close();
  }
}

TEST(ProtocolSession, MiddleButtonTimersAndPolicyAreSessionLocal)
{
  SessionScheduler::TimePoint now{};
  SessionTiming timing; timing.now = [&] { return now; };
  rdr::MemOutStream wire, firstOutput, secondOutput; handshake(wire,100,100);
  rdr::MemInStream firstInput(wire.data(),wire.length()), secondInput(wire.data(),wire.length());
  ProtocolSession first(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr, {}, timing);
  ProtocolSession second(rfb::SecurityClient({rfb::secTypeNone}), {}, {}, nullptr, {}, timing);
  first.start("first",firstInput,firstOutput); ready(first); firstOutput.clear();
  second.start("second",secondInput,secondOutput); ready(second); secondOutput.clear();
  first.inputQueue()->setPolicy(false,true); second.inputQueue()->setPolicy(false,true);
  first.inputQueue()->pointer(1,10,10,1); first.drainInput(); expectPointers(firstOutput,{{0,10,10}});
  second.inputQueue()->pointer(1,20,20,4); second.drainInput(); expectPointers(secondOutput,{{0,20,20}});
  first.close(); now += std::chrono::milliseconds(50);
  first.dispatchScheduled(); second.dispatchScheduled();
  expectPointers(firstOutput,{}); expectPointers(secondOutput,{{4,20,20}});
  second.close(); expectPointers(secondOutput,{{0,20,20}});
}

TEST(ProtocolSession, ExplicitInputReleaseDropsQueuedInputAndPreservesPolicy)
{
  rdr::MemOutStream wire,output; handshake(wire);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
  const auto queue = session.inputQueue();
  EXPECT_EQ(queue->releaseAll(1),InputResult::NotConnected);
  session.start("fixture",input,output); ready(session); output.clear();
  ASSERT_EQ(queue->key(1,1,'A',0,true),InputResult::Accepted); session.drainInput(); output.clear();
  ASSERT_EQ(queue->key(1,2,'B',0,true),InputResult::Accepted);
  auto before = queue->status();
  EXPECT_EQ(queue->releaseAll(2),InputResult::StaleGeneration);
  EXPECT_EQ(queue->status().routingRevision,before.routingRevision);
  ASSERT_EQ(queue->releaseAll(1),InputResult::Accepted);
  EXPECT_TRUE(queue->status().focused); EXPECT_EQ(queue->status().queued,0u);
  EXPECT_GT(queue->status().routingRevision,before.routingRevision);
  session.drainInput(); ASSERT_EQ(output.length(),8u);
  EXPECT_EQ(output.data()[0],4); EXPECT_EQ(output.data()[1],0); EXPECT_EQ(output.data()[7],'A');
  output.clear(); ASSERT_EQ(queue->key(1,3,'C',0,true),InputResult::Accepted);
  session.drainInput(); ASSERT_EQ(output.length(),8u); EXPECT_EQ(output.data()[7],'C');
  queue->setPolicy(true,true); queue->setFocused(1,false);
  ASSERT_EQ(queue->releaseAll(1),InputResult::Accepted);
  EXPECT_TRUE(queue->status().viewOnly); EXPECT_TRUE(queue->status().emulateMiddle); EXPECT_FALSE(queue->status().focused);
  session.close(); EXPECT_EQ(queue->releaseAll(1),InputResult::StaleGeneration);
  EXPECT_EQ(queue->releaseAll(queue->status().generation),InputResult::NotConnected);
}

TEST(ProtocolSession, SharedFlagIsOwnedAndSentOnEachHandshake)
{
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}));
  for (bool shared : {false,true,false}) {
    session.setShared(shared);
    rdr::MemOutStream wire, output; handshake(wire);
    rdr::MemInStream input(wire.data(),wire.length());
    session.start("fixture",input,output); ready(session);
    ASSERT_GT(output.length(),13u);
    EXPECT_EQ(output.data()[13],shared ? 1 : 0); // version (12), security choice (1), ClientInit (1).
    EXPECT_THROW(session.setShared(!shared),std::logic_error);
    session.close();
  }
}

TEST(ProtocolSession, PointerIntervalKeepsFirstDeadlineAndImmediateTransitions)
{
  SessionScheduler::TimePoint now{}; SessionTiming timing;
  timing.now = [&] { return now; }; timing.pointerEventInterval = std::chrono::milliseconds(17);
  rdr::MemOutStream wire, output; handshake(wire,100,100);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}),{}, {},nullptr,{},timing);
  session.start("fixture",input,output); ready(session); output.clear(); auto queue = session.inputQueue();
  queue->pointer(1,10,10,0); session.drainInput(); expectPointers(output,{});
  now += std::chrono::milliseconds(10);
  queue->pointer(1,20,20,0); session.drainInput(); expectPointers(output,{});
  now += std::chrono::milliseconds(6); session.dispatchScheduled(); expectPointers(output,{});
  now += std::chrono::milliseconds(1); session.dispatchScheduled(); expectPointers(output,{{0,20,20}});
  queue->pointer(1,25,25,0); session.drainInput();
  queue->pointer(1,30,30,1); session.drainInput(); expectPointers(output,{{1,30,30}});
  queue->pointer(1,31,31,9); session.drainInput(); expectPointers(output,{{9,31,31}});
  queue->pointer(1,32,32,1); session.drainInput(); expectPointers(output,{{1,32,32}});
  queue->pointer(1,33,33,0); session.drainInput(); expectPointers(output,{{0,33,33}});
  now += std::chrono::milliseconds(17); session.dispatchScheduled(); expectPointers(output,{{0,33,33}});
  queue->pointer(1,40,40,0); session.drainInput(); expectPointers(output,{});
  queue->key(1,65,65,0,true); session.drainInput();
  ASSERT_EQ(output.length(),14u); EXPECT_EQ(output.data()[0],5); EXPECT_EQ(output.data()[5],40);
  EXPECT_EQ(output.data()[6],4); output.clear();
  now += std::chrono::milliseconds(17); session.dispatchScheduled(); expectPointers(output,{});
}

TEST(ProtocolSession, PointerIntervalCannotCrossRoutingOrAttemptLifetime)
{
  for (int transition = 0; transition < 6; ++transition) {
    SessionScheduler::TimePoint now{}; SessionTiming timing;
    timing.now = [&] { return now; }; timing.pointerEventInterval = std::chrono::milliseconds(17);
    SessionBufferLimits limits; limits.inputCommands = 2;
    rdr::MemOutStream wire, output; handshake(wire,100,100);
    rdr::MemInStream input(wire.data(),wire.length());
    ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}),{},limits,nullptr,{},timing);
    session.start("fixture",input,output); ready(session); output.clear(); auto queue = session.inputQueue();
    queue->pointer(1,10,10,0); session.drainInput(); expectPointers(output,{});
    if (transition == 0) { queue->setFocused(1,false); queue->setFocused(1,true); }
    if (transition == 1) { queue->setViewOnly(true); queue->setViewOnly(false); }
    if (transition == 2) queue->releaseAll(1);
    if (transition == 3) queue->setPolicy(false,true);
    if (transition == 4) {
      queue->key(1,65,65,0,true); queue->key(1,66,66,0,true);
      ASSERT_EQ(queue->key(1,67,67,0,true),InputResult::Overflow);
    }
    if (transition == 5) session.close();
    // Dispatch before draining the producer's release barrier: revision checking
    // must reject the old callback even though cleanup has not run yet.
    now += std::chrono::milliseconds(20); session.dispatchScheduled(); expectPointers(output,{});
    session.drainInput(); expectPointers(output,{});
    session.close();
    rdr::MemOutStream nextWire, nextOutput; handshake(nextWire,100,100);
    rdr::MemInStream nextInput(nextWire.data(),nextWire.length());
    session.start("next",nextInput,nextOutput); ready(session); nextOutput.clear();
    now += std::chrono::milliseconds(20); session.dispatchScheduled(); expectPointers(nextOutput,{});
  }
}

TEST(ProtocolSession, PointerTimingRunsAfterMiddleButtonEmulation)
{
  SessionScheduler::TimePoint now{}; SessionTiming timing;
  timing.now = [&] { return now; }; timing.pointerEventInterval = std::chrono::milliseconds(17);
  rdr::MemOutStream wire, output; handshake(wire,100,100);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeNone}),{}, {},nullptr,{},timing);
  session.start("fixture",input,output); ready(session); output.clear(); auto queue = session.inputQueue();
  queue->setPolicy(false,true); session.drainInput();
  queue->pointer(1,10,10,1); session.drainInput(); expectPointers(output,{});
  now += std::chrono::milliseconds(17); session.dispatchScheduled(); expectPointers(output,{{0,10,10}});
  queue->pointer(1,20,20,1); session.drainInput(); expectPointers(output,{});
  now += std::chrono::milliseconds(33); session.dispatchScheduled(); expectPointers(output,{{1,10,10}});
  now += std::chrono::milliseconds(17); session.dispatchScheduled(); expectPointers(output,{{1,20,20}});
  queue->pointer(1,21,21,0); session.drainInput(); expectPointers(output,{{0,21,21}});
}

TEST(ProtocolSession, PointerIntervalBoundsZeroAndIndependentSessions)
{
  SessionTiming bad; bad.pointerEventInterval = std::chrono::milliseconds(-1);
  EXPECT_THROW(ProtocolSession(rfb::SecurityClient({rfb::secTypeNone}),{}, {},nullptr,{},bad),std::invalid_argument);
  bad.pointerEventInterval = std::chrono::milliseconds(int64_t(INT_MAX)+1);
  EXPECT_THROW(ProtocolSession(rfb::SecurityClient({rfb::secTypeNone}),{}, {},nullptr,{},bad),std::invalid_argument);
  SessionScheduler::TimePoint now{}; SessionTiming delayed; delayed.now = [&] { return now; };
  delayed.pointerEventInterval = std::chrono::milliseconds(INT_MAX);
  rdr::MemOutStream wire, firstOutput, secondOutput; handshake(wire,100,100);
  rdr::MemInStream firstInput(wire.data(),wire.length()), secondInput(wire.data(),wire.length());
  ProtocolSession first(rfb::SecurityClient({rfb::secTypeNone}),{}, {},nullptr,{},delayed);
  ProtocolSession second(rfb::SecurityClient({rfb::secTypeNone}));
  first.start("first",firstInput,firstOutput); second.start("second",secondInput,secondOutput);
  ready(first); ready(second); firstOutput.clear(); secondOutput.clear();
  first.inputQueue()->pointer(1,10,10,0); first.drainInput(); expectPointers(firstOutput,{});
  second.inputQueue()->pointer(1,20,20,0); second.drainInput(); expectPointers(secondOutput,{{0,20,20}});
  now += std::chrono::milliseconds(INT_MAX); first.dispatchScheduled(8); expectPointers(firstOutput,{{0,10,10}});
}
