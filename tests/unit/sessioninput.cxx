/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/ProtocolSession.h>
#include <rfb/PixelFormat.h>
#include <rfb/encodings.h>
#include <rdr/MemInStream.h>
#include <rdr/MemOutStream.h>
#include <future>

using namespace viewer;
namespace {
struct WireEvent {
  uint8_t type, value;
  uint32_t symbol, code;
  uint16_t x, y;
};
class Output : public rdr::MemOutStream {
public:
  void flush() override { if (failed) throw std::runtime_error("Transport failed"); }
  bool failed=false;
};
class Fixture {
public:
  explicit Fixture(SessionBufferLimits limits = {})
    : session(rfb::SecurityClient({rfb::secTypeNone}),{},limits), queue(session.inputQueue()) {
    wire.writeBytes(reinterpret_cast<const uint8_t*>("RFB 003.008\n"),12);
    wire.writeU8(1); wire.writeU8(rfb::secTypeNone); wire.writeU32(0);
    wire.writeU16(100); wire.writeU16(80);
    rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0).write(&wire);
    wire.writeU32(0);
  }
  ~Fixture() { session.close(); }
  void connect() {
    input.reset(new rdr::MemInStream(wire.data(),wire.length()));
    session.start("fixture",*input,output);
    for (int i=0;i<16 && !session.desktop().ready;++i)
      if (!session.processMessage()) throw std::runtime_error("Incomplete fixture handshake");
    if (!session.desktop().ready) throw std::runtime_error("Fixture did not connect");
    offset=output.length();
  }
  std::vector<WireEvent> events() {
    rdr::MemInStream bytes(output.data()+offset,output.length()-offset);
    std::vector<WireEvent> result;
    while (bytes.avail()) {
      WireEvent event{};
      event.type=bytes.readU8();
      if (!bytes.hasData(event.type==255 ? 11 : event.type==4 ? 7 : 5)) throw std::runtime_error("Truncated input event");
      event.value=bytes.readU8();
      if (event.type==4) { bytes.skip(2); event.symbol=bytes.readU32(); }
      else if (event.type==5) {
        event.x=bytes.readU16(); event.y=bytes.readU16();
        if (event.value & 0x80) {
          if (!bytes.hasData(1)) throw std::runtime_error("Missing extended buttons");
          event.code=bytes.readU8();
        }
      }
      else if (event.type==255) {
        event.value=bytes.readU16(); event.symbol=bytes.readU32(); event.code=bytes.readU32();
      }
      else throw std::runtime_error("Unexpected wire message");
      result.push_back(event);
    }
    offset=output.length(); return result;
  }
  rdr::MemOutStream wire;
  Output output;
  std::unique_ptr<rdr::MemInStream> input;
  ProtocolSession session;
  std::shared_ptr<InputQueue> queue;
  size_t offset=0;
};
}
TEST(SessionInput, RejectsBeforeConnectionAndStaleAfterReconnect)
{
  Fixture f;
  EXPECT_EQ(f.queue->key(1,1,'a',0,true),InputResult::NotConnected);
  f.connect(); EXPECT_EQ(f.queue->key(0,1,'a',0,true),InputResult::StaleGeneration);
  EXPECT_EQ(f.queue->key(1,1,'a',0,true),InputResult::Accepted);
  f.session.close(); EXPECT_EQ(f.queue->status().queued,0u);
  f.connect();
  EXPECT_EQ(f.queue->key(1,1,'a',0,true),InputResult::StaleGeneration);
  EXPECT_EQ(f.queue->key(2,1,'b',0,true),InputResult::Accepted);
  EXPECT_TRUE(f.session.drainInput());
  auto events=f.events(); ASSERT_EQ(events.size(),1u); EXPECT_EQ(events[0].symbol,'b');
}
TEST(SessionInput, PreservesTransitionsAndCoalescesOnlyAdjacentMotion)
{
  Fixture f; f.connect();
  EXPECT_EQ(f.queue->pointer(1,1,2,0),InputResult::Accepted);
  EXPECT_EQ(f.queue->pointer(1,3,4,0),InputResult::Coalesced);
  EXPECT_EQ(f.queue->pointer(1,5,6,1),InputResult::Accepted);
  EXPECT_EQ(f.queue->pointer(1,7,8,1),InputResult::Accepted);
  EXPECT_EQ(f.queue->pointer(1,9,10,1),InputResult::Coalesced);
  EXPECT_EQ(f.queue->key(1,4,'a',0,true),InputResult::Accepted);
  EXPECT_EQ(f.queue->pointer(1,11,12,1),InputResult::Accepted);
  EXPECT_EQ(f.queue->pointer(1,13,14,0),InputResult::Accepted);
  EXPECT_EQ(f.queue->key(1,4,0,0,false),InputResult::Accepted);
  EXPECT_TRUE(f.session.drainInput());
  auto e=f.events(); ASSERT_EQ(e.size(),7u);
  EXPECT_EQ(e[0].x,3); EXPECT_EQ(e[0].value,0);
  EXPECT_EQ(e[1].x,5); EXPECT_EQ(e[1].value,1);
  EXPECT_EQ(e[2].x,9); EXPECT_EQ(e[3].type,4); EXPECT_EQ(e[3].value,1);
  EXPECT_EQ(e[4].x,11); EXPECT_EQ(e[5].x,13); EXPECT_EQ(e[5].value,0);
  EXPECT_EQ(e[6].symbol,'a'); EXPECT_EQ(e[6].value,0);
}
TEST(SessionInput, RepeatAndReleaseUseOriginalKeyMapping)
{
  Fixture f; f.connect();
  f.queue->key(1,4,'a',0,true); f.queue->key(1,4,'A',0,true);
  f.queue->key(1,5,0,0,false); f.queue->key(1,4,'z',0,false);
  f.session.drainInput();
  auto e=f.events(); ASSERT_EQ(e.size(),3u);
  for (auto event:e) EXPECT_EQ(event.symbol,'a');
  EXPECT_EQ(e[0].value,1); EXPECT_EQ(e[1].value,1); EXPECT_EQ(e[2].value,0);
}
TEST(SessionInput, NegotiatedExtendedInputKeepsPhysicalKeycodesAndExtraButtons)
{
  Fixture f;
  f.wire.writeU8(0); f.wire.pad(1); f.wire.writeU16(2);
  for (int encoding : {rfb::pseudoEncodingQEMUKeyEvent,rfb::pseudoEncodingExtendedMouseButtons}) {
    f.wire.pad(8); f.wire.writeU32(encoding);
  }
  f.wire.writeU8(2); // Bell marks the complete capability update.
  f.connect();
  for (int i=0;i<16 && !f.session.desktop().bells;++i) ASSERT_TRUE(f.session.processMessage());
  ASSERT_EQ(f.session.desktop().bells,1u); f.offset=f.output.length();
  f.queue->key(1,7,0,0x1e,true); f.queue->pointer(1,4,5,0x100);
  f.queue->key(1,7,0,0,false); f.session.drainInput();
  f.queue->setFocused(1,false); f.session.drainInput();
  auto e=f.events(); ASSERT_EQ(e.size(),4u);
  EXPECT_EQ(e[0].type,255); EXPECT_EQ(e[0].value,1); EXPECT_EQ(e[0].code,0x1eu);
  EXPECT_EQ(e[1].type,5); EXPECT_EQ(e[1].value,0x80); EXPECT_EQ(e[1].code,2u);
  EXPECT_EQ(e[2].type,255); EXPECT_EQ(e[2].value,0); EXPECT_EQ(e[2].code,0x1eu);
  EXPECT_EQ(e[3].type,5); EXPECT_EQ(e[3].value,0);
}
TEST(SessionInput, FullQueueStillCoalescesMotionWithoutDroppingTransition)
{
  SessionBufferLimits limits; limits.inputCommands=2;
  Fixture f(limits); f.connect();
  f.queue->pointer(1,1,1,1); f.queue->pointer(1,2,2,1);
  EXPECT_EQ(f.queue->pointer(1,3,3,1),InputResult::Coalesced);
  EXPECT_EQ(f.queue->status().queued,2u); EXPECT_EQ(f.queue->status().overflows,0u);
  f.session.drainInput(); auto e=f.events(); ASSERT_EQ(e.size(),2u);
  EXPECT_EQ(e[0].x,1); EXPECT_EQ(e[1].x,3);
}
TEST(SessionInput, FocusLossReleasesHeldKeysAndButtonsBeforeNewInput)
{
  Fixture f; f.connect();
  f.queue->key(1,1,0xffe1,0,true); f.queue->key(1,2,'a',0,true);
  f.queue->pointer(1,8,9,1); f.session.drainInput(); f.events();
  f.queue->key(1,3,'b',0,true);
  EXPECT_EQ(f.queue->setFocused(1,false),InputResult::Accepted);
  EXPECT_EQ(f.queue->key(1,2,0,0,false),InputResult::Unfocused);
  EXPECT_EQ(f.queue->setFocused(1,true),InputResult::Accepted);
  f.queue->key(1,4,'c',0,true); f.session.drainInput();
  auto e=f.events(); ASSERT_EQ(e.size(),4u);
  EXPECT_EQ(e[0].symbol,'a'); EXPECT_EQ(e[0].value,0);
  EXPECT_EQ(e[1].symbol,0xffe1u); EXPECT_EQ(e[1].value,0);
  EXPECT_EQ(e[2].type,5); EXPECT_EQ(e[2].value,0); EXPECT_EQ(e[2].x,8);
  EXPECT_EQ(e[3].symbol,'c'); EXPECT_EQ(e[3].value,1);
}
TEST(SessionInput, ViewOnlyIsEnforcedInCoreAndReleasesExistingInput)
{
  Fixture f; f.queue->setViewOnly(true); f.connect();
  EXPECT_EQ(f.queue->key(1,1,'a',0,true),InputResult::ViewOnly);
  EXPECT_EQ(f.queue->pointer(1,0,0,1),InputResult::ViewOnly);
  f.session.drainInput(); EXPECT_TRUE(f.events().empty());
  f.queue->setViewOnly(false); f.queue->key(1,1,'a',0,true);
  f.queue->pointer(1,2,3,1); f.session.drainInput(); f.events();
  f.queue->key(1,2,'b',0,true); f.queue->setViewOnly(true); f.session.drainInput();
  auto e=f.events(); ASSERT_EQ(e.size(),2u);
  EXPECT_EQ(e[0].symbol,'a'); EXPECT_EQ(e[0].value,0); EXPECT_EQ(e[1].value,0);
  f.session.close(); f.connect(); EXPECT_TRUE(f.queue->status().viewOnly);
}
TEST(SessionInput, QueueOverflowReleasesInsteadOfLosingKeyUp)
{
  SessionBufferLimits limits; limits.inputCommands=2;
  Fixture f(limits); f.connect();
  f.queue->key(1,1,'a',0,true); f.queue->pointer(1,2,3,1);
  f.session.drainInput(); f.events();
  f.queue->key(1,2,'b',0,true); f.queue->key(1,3,'c',0,true);
  EXPECT_EQ(f.queue->key(1,1,0,0,false),InputResult::Overflow);
  auto status=f.queue->status(); EXPECT_EQ(status.queued,0u);
  EXPECT_EQ(status.overflows,1u); EXPECT_TRUE(status.releasePending); EXPECT_FALSE(status.focused);
  EXPECT_EQ(f.queue->key(1,4,'d',0,true),InputResult::Unfocused);
  f.session.drainInput();
  auto e=f.events(); ASSERT_EQ(e.size(),2u);
  EXPECT_EQ(e[0].symbol,'a'); EXPECT_EQ(e[0].value,0); EXPECT_EQ(e[1].value,0);
  f.queue->setFocused(1,true); f.queue->key(1,5,'e',0,true); f.session.drainInput();
  e=f.events(); ASSERT_EQ(e.size(),1u); EXPECT_EQ(e[0].symbol,'e');
}
TEST(SessionInput, HeldKeyLimitBoundsStateAcrossManyDrains)
{
  SessionBufferLimits limits; limits.heldKeys=1;
  Fixture f(limits); f.connect();
  f.queue->key(1,1,'a',0,true); f.session.drainInput(); f.events();
  f.queue->key(1,2,'b',0,true); EXPECT_FALSE(f.session.drainInput());
  auto e=f.events(); ASSERT_EQ(e.size(),1u); EXPECT_EQ(e[0].symbol,'a'); EXPECT_EQ(e[0].value,0);
  EXPECT_EQ(f.queue->status().overflows,1u); EXPECT_FALSE(f.queue->status().focused);
}
TEST(SessionInput, DisconnectReleasesHeldStateAndDiscardsUnsentCommands)
{
  Fixture f; f.connect();
  f.queue->key(1,1,'a',0,true); f.queue->pointer(1,2,3,1);
  f.session.drainInput(); f.events(); f.queue->key(1,2,'b',0,true);
  f.session.close(); f.session.close();
  auto e=f.events(); ASSERT_EQ(e.size(),2u); EXPECT_EQ(e[0].value,0); EXPECT_EQ(e[1].value,0);
  EXPECT_FALSE(f.queue->status().connected); EXPECT_EQ(f.queue->status().queued,0u);
}
TEST(SessionInput, RetainedMailboxIsSafeAfterSessionDestruction)
{
  std::shared_ptr<InputQueue> queue;
  { Fixture f; f.connect(); queue=f.queue; f.queue->key(1,1,'a',0,true); }
  EXPECT_FALSE(queue->status().connected);
  EXPECT_EQ(queue->key(2,1,'a',0,true),InputResult::NotConnected);
}
TEST(SessionInput, FailedWriteClosesAttemptAndInvalidatesQueuedInput)
{
  Fixture f; f.connect();
  f.queue->key(1,1,'a',0,true); f.session.drainInput();
  f.queue->pointer(1,2,3,1); f.output.failed=true;
  EXPECT_THROW(f.session.drainInput(),std::runtime_error);
  EXPECT_FALSE(f.session.desktop().active); EXPECT_FALSE(f.queue->status().connected);
  EXPECT_EQ(f.queue->status().generation,2u); EXPECT_EQ(f.queue->status().queued,0u);
  EXPECT_NO_THROW(f.session.close());
}
TEST(SessionInput, ProtocolFailureAlsoReleasesInput)
{
  Fixture f; f.wire.writeU8(255); f.connect();
  f.queue->key(1,1,'a',0,true); f.queue->pointer(1,2,3,1);
  f.session.drainInput(); f.events();
  EXPECT_THROW(f.session.processMessage(),std::exception);
  auto e=f.events(); ASSERT_EQ(e.size(),2u); EXPECT_EQ(e[0].value,0); EXPECT_EQ(e[1].value,0);
  EXPECT_FALSE(f.queue->status().connected);
}
TEST(SessionInput, ValidatesLimitsAndClampsCoordinatesAtProtocolBoundary)
{
  SessionBufferLimits limits; limits.inputCommands=0;
  EXPECT_THROW(Fixture{limits},std::invalid_argument);
  limits.inputCommands=1; limits.heldKeys=0;
  EXPECT_THROW(Fixture{limits},std::invalid_argument);
  Fixture f; f.connect();
  EXPECT_EQ(f.queue->pointer(1,0,0,0x8000),InputResult::Invalid);
  EXPECT_EQ(f.queue->key(1,1,0,0,true),InputResult::Invalid);
  f.queue->pointer(1,-100,1000,0); f.session.drainInput();
  auto e=f.events(); ASSERT_EQ(e.size(),1u); EXPECT_EQ(e[0].x,0); EXPECT_EQ(e[0].y,79);
}
TEST(SessionInput, IndependentSessionsAndConcurrentProducerKeepInputSeparate)
{
  Fixture a,b; a.connect(); b.connect();
  a.queue->setViewOnly(true);
  auto producer=std::async(std::launch::async,[&] {
    for (int i=0;i<10000;++i) {
      auto result=b.queue->pointer(1,i%100,i%80,0);
      if (result!=InputResult::Accepted && result!=InputResult::Coalesced)
        throw std::runtime_error("Motion unexpectedly rejected");
    }
  });
  while (producer.wait_for(std::chrono::milliseconds(0))!=std::future_status::ready)
    b.session.drainInput();
  producer.get(); b.session.drainInput();
  EXPECT_TRUE(a.events().empty());
  auto e=b.events(); ASSERT_FALSE(e.empty()); EXPECT_EQ(e.back().x,99); EXPECT_EQ(e.back().y,79);
}
