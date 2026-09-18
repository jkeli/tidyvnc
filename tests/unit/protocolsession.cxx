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
void handshake(rdr::MemOutStream& wire, int width = 2, int height = 2)
{
  const char version[] = "RFB 003.008\n";
  wire.writeBytes(reinterpret_cast<const uint8_t*>(version), 12);
  wire.writeU8(1); wire.writeU8(rfb::secTypeNone); wire.writeU32(0);
  wire.writeU16(width); wire.writeU16(height);
  rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0).write(&wire);
  wire.writeU32(7); wire.writeBytes(reinterpret_cast<const uint8_t*>("fixture"),7);
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
