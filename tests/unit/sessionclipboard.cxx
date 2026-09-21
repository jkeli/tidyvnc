/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/ProtocolSession.h>
#include <rfb/PixelFormat.h>
#include <rfb/clipboardTypes.h>
#include <rdr/MemInStream.h>
#include <rdr/MemOutStream.h>
#include <rdr/ZlibOutStream.h>
#include <rdr/ZlibInStream.h>
#include <type_traits>
#include <atomic>
#include <thread>
using namespace viewer;
namespace {
void handshake(rdr::MemOutStream& wire) {
  wire.writeBytes(reinterpret_cast<const uint8_t*>("RFB 003.008\n"),12);
  wire.writeU8(1); wire.writeU8(rfb::secTypeNone); wire.writeU32(0);
  wire.writeU16(2); wire.writeU16(2);
  rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0).write(&wire);
  wire.writeU32(0); wire.writeU8(2);
}
void plain(rdr::MemOutStream& wire,const std::string& text) {
  wire.writeU8(3); wire.pad(3); wire.writeU32(text.size());
  wire.writeBytes(reinterpret_cast<const uint8_t*>(text.data()),text.size()); wire.writeU8(2);
}
void action(rdr::MemOutStream& wire,uint32_t flags,bool caps = false) {
  wire.writeU8(3); wire.pad(3); wire.writeU32(caps ? 0u-8 : 0u-4); wire.writeU32(flags);
  if (caps) wire.writeU32(0);
  wire.writeU8(2);
}
void caps(rdr::MemOutStream& wire) {
  action(wire,rfb::clipboardUTF8|rfb::clipboardCaps|rfb::clipboardRequest|
         rfb::clipboardPeek|rfb::clipboardNotify|rfb::clipboardProvide,true);
}
void provided(rdr::MemOutStream& wire,const std::string& text) {
  rdr::MemOutStream compressed; rdr::ZlibOutStream zlib(&compressed);
  zlib.writeU32(text.size()); zlib.writeBytes(reinterpret_cast<const uint8_t*>(text.data()),text.size()); zlib.flush();
  wire.writeU8(3); wire.pad(3); wire.writeU32(0u-(4+compressed.length()));
  wire.writeU32(rfb::clipboardProvide|rfb::clipboardUTF8); wire.writeBytes(compressed.data(),compressed.length()); wire.writeU8(2);
}
void through(ProtocolSession& session,uint64_t count) {
  for (int i=0;session.desktop().bells<count && i<64;++i) ASSERT_TRUE(session.processMessage());
  ASSERT_EQ(session.desktop().bells,count);
}
struct Harness {
  explicit Harness(rdr::MemOutStream& wire,SessionBufferLimits limits = {})
    : input(wire.data(),wire.length()), session(rfb::SecurityClient({rfb::secTypeNone}),{},limits) {
    events=session.subscribeEvents(); session.start("fixture",input,output); through(session,1);
  }
  uint64_t generation() { return session.desktop().generation; }
  ClipboardPrepared prepare(const std::string& text) { return session.clipboard()->prepareLocal(generation(),text); }
  rdr::MemInStream input;
  rdr::MemOutStream output;
  ProtocolSession session;
  std::shared_ptr<SessionEvents> events;
};
}
TEST(SessionClipboard, ValidatesNormalizesAndBudgetsOwnedLocalText)
{
  static_assert(!std::is_copy_constructible<ClipboardText>::value,"Text budget must not be copied by value");
  rdr::MemOutStream wire; handshake(wire); SessionBufferLimits limits;
  limits.clipboardTextBytes=8; limits.clipboardRetainedBytes=8; Harness h(wire,limits);
  auto channel=h.session.clipboard();
  auto text=h.prepare("a\r\nb\rc"); ASSERT_EQ(text.result,ClipboardResult::Accepted);
  EXPECT_EQ(text.text->text(),"a\nb\nc"); EXPECT_EQ(channel->bytesInUse(),5u);
  EXPECT_EQ(h.prepare("123456789").result,ClipboardResult::TooLarge);
  EXPECT_EQ(h.prepare(std::string("a\0b",3)).result,ClipboardResult::InvalidText);
  EXPECT_EQ(h.prepare(std::string(1,char(0xff))).result,ClipboardResult::InvalidText);
  EXPECT_EQ(h.prepare("1234").result,ClipboardResult::Backpressure);
  text.text.reset(); EXPECT_EQ(channel->bytesInUse(),0u);
  EXPECT_EQ(h.prepare("").result,ClipboardResult::Accepted);
}
TEST(SessionClipboard, PlainTextReceiveCoalescesAndSuppressesTaggedEcho)
{
  rdr::MemOutStream wire; handshake(wire); plain(wire,"first"); plain(wire,std::string("caf\xe9\r\n",6));
  Harness h(wire); through(h.session,3);
  ClipboardUpdate update; ASSERT_TRUE(h.session.clipboard()->take(update));
  ASSERT_EQ(update.kind,ClipboardUpdateKind::Text); ASSERT_TRUE(update.text);
  EXPECT_EQ(update.text->text(),u8"café\n"); EXPECT_TRUE(update.text->fromRemote());
  EXPECT_EQ(h.session.clipboard()->prepareLocal(h.generation(),update.text->text(),update.text).result,ClipboardResult::Echo);
  EXPECT_FALSE(h.session.clipboard()->take(update));
  auto held=update.text; h.session.close(); EXPECT_EQ(held->text(),u8"café\n");
}
TEST(SessionClipboard, LegacySendUsesLatin1AndLfWithOwnedOffer)
{
  rdr::MemOutStream wire; handshake(wire); Harness h(wire);
  auto text=h.prepare(u8"café\r\n"); ASSERT_EQ(text.result,ClipboardResult::Accepted);
  const auto before=h.output.length(); ASSERT_NE(h.session.offerClipboard(text.text),0u);
  text.text.reset(); rdr::MemInStream sent(h.output.data()+before,h.output.length()-before);
  EXPECT_EQ(sent.readU8(),6); sent.skip(3); EXPECT_EQ(sent.readU32(),5u);
  std::string body(5,'\0'); sent.readBytes(reinterpret_cast<uint8_t*>(&body[0]),body.size());
  EXPECT_EQ(body,std::string("caf\xe9\n",5));
  EXPECT_GT(h.session.clipboard()->bytesInUse(),0u);
  ASSERT_NE(h.session.clearClipboard(),0u); EXPECT_EQ(h.session.clipboard()->bytesInUse(),0u);
}
TEST(SessionClipboard, ExtendedOfferRespondsToRequestWithCrLfUtf8)
{
  rdr::MemOutStream wire; handshake(wire); caps(wire); action(wire,rfb::clipboardRequest|rfb::clipboardUTF8);
  Harness h(wire); through(h.session,2);
  const auto before=h.output.length(); auto prepared=h.prepare(u8"é\na");
  ASSERT_NE(h.session.offerClipboard(prepared.text),0u);
  rdr::MemInStream announce(h.output.data()+before,h.output.length()-before);
  EXPECT_EQ(announce.readU8(),6); announce.skip(3); EXPECT_EQ(announce.readS32(),-4);
  EXPECT_EQ(announce.readU32(),rfb::clipboardNotify|rfb::clipboardUTF8);
  const auto start=h.output.length(); through(h.session,3);
  rdr::MemInStream response(h.output.data()+start,h.output.length()-start);
  EXPECT_EQ(response.readU8(),6); response.skip(3); auto length=-response.readS32();
  EXPECT_EQ(response.readU32(),rfb::clipboardProvide|rfb::clipboardUTF8);
  rdr::ZlibInStream zlib; zlib.setUnderlying(&response,length-4); ASSERT_TRUE(zlib.hasData(4));
  const auto size=zlib.readU32(); ASSERT_TRUE(zlib.hasData(size));
  std::string body(size,'\0'); zlib.readBytes(reinterpret_cast<uint8_t*>(&body[0]),size);
  EXPECT_EQ(body,std::string(u8"é\r\na\0",6)); zlib.flushUnderlying(); zlib.setUnderlying(nullptr,0);
}
TEST(SessionClipboard, ExtendedNotifyRequestsAndReceivesText)
{
  rdr::MemOutStream wire; handshake(wire); caps(wire);
  action(wire,rfb::clipboardNotify|rfb::clipboardUTF8); provided(wire,std::string("remote\r\n\0",9));
  Harness h(wire); through(h.session,2); const auto before=h.output.length(); through(h.session,3);
  ClipboardUpdate update; ASSERT_TRUE(h.session.clipboard()->take(update)); EXPECT_EQ(update.kind,ClipboardUpdateKind::Offered);
  rdr::MemInStream request(h.output.data()+before,h.output.length()-before);
  EXPECT_EQ(request.readU8(),6); request.skip(3); EXPECT_EQ(request.readS32(),-4);
  EXPECT_EQ(request.readU32(),rfb::clipboardRequest|rfb::clipboardUTF8);
  through(h.session,4); ASSERT_TRUE(h.session.clipboard()->take(update));
  ASSERT_TRUE(update.text); EXPECT_EQ(update.text->text(),"remote\n");
}
TEST(SessionClipboard, FocusRoundTripInvalidatesPreparedAndDelayedReceivedText)
{
  rdr::MemOutStream wire; handshake(wire); caps(wire);
  action(wire,rfb::clipboardNotify|rfb::clipboardUTF8); provided(wire,"late");
  Harness h(wire); auto channel=h.session.clipboard();
  auto prepared=h.prepare("local"); ASSERT_EQ(prepared.result,ClipboardResult::Accepted);
  through(h.session,3); ClipboardUpdate update; channel->take(update);
  h.session.inputQueue()->setFocused(h.generation(),false);
  EXPECT_EQ(h.prepare("x").result,ClipboardResult::Unfocused);
  h.session.inputQueue()->setFocused(h.generation(),true);
  EXPECT_EQ(h.session.offerClipboard(prepared.text),0u);
  through(h.session,4); EXPECT_FALSE(channel->take(update));
}
TEST(SessionClipboard, SendReceivePolicyIsIndependentAndViewOnlyBlocksBoth)
{
  rdr::MemOutStream wire; handshake(wire); plain(wire,"receive"); plain(wire,"blocked");
  Harness h(wire); auto channel=h.session.clipboard(); channel->setPolicy({false,true});
  EXPECT_EQ(h.prepare("local").result,ClipboardResult::Disabled);
  through(h.session,2); ClipboardUpdate update; ASSERT_TRUE(channel->take(update)); ASSERT_TRUE(update.text);
  channel->setPolicy({true,false}); EXPECT_EQ(h.prepare("local").result,ClipboardResult::Accepted);
  through(h.session,3); ASSERT_TRUE(channel->take(update)); EXPECT_FALSE(update.text);
  channel->setPolicy({true,true}); h.session.inputQueue()->setViewOnly(true);
  EXPECT_EQ(h.prepare("local").result,ClipboardResult::ViewOnly);
  channel->receive("forbidden",channel->route()); ASSERT_TRUE(channel->take(update)); EXPECT_FALSE(update.text);
}
TEST(SessionClipboard, RetainedTextBudgetBackpressuresAndRecoversWithoutDisconnect)
{
  rdr::MemOutStream wire; handshake(wire); plain(wire,"12345678"); plain(wire,"abcd"); plain(wire,"again");
  SessionBufferLimits limits; limits.clipboardTextBytes=8; limits.clipboardRetainedBytes=8; Harness h(wire,limits);
  auto channel=h.session.clipboard(); through(h.session,2);
  ClipboardUpdate update; ASSERT_TRUE(channel->take(update)); auto held=update.text; update={};
  through(h.session,3); ASSERT_TRUE(channel->take(update)); EXPECT_EQ(update.kind,ClipboardUpdateKind::Rejected);
  EXPECT_EQ(update.result,ClipboardResult::Backpressure); EXPECT_EQ(channel->bytesInUse(),8u);
  held.reset(); through(h.session,4); ASSERT_TRUE(channel->take(update)); ASSERT_TRUE(update.text);
  EXPECT_EQ(update.text->text(),"again"); EXPECT_TRUE(h.session.desktop().ready);
}
TEST(SessionClipboard, FocusLossRevokesLocalOfferAndRemoteMailbox)
{
  rdr::MemOutStream wire; handshake(wire); caps(wire); plain(wire,"remote");
  Harness h(wire); through(h.session,2); auto channel=h.session.clipboard();
  auto prepared=h.prepare("local"); ASSERT_NE(h.session.offerClipboard(prepared.text),0u); prepared.text.reset();
  h.session.inputQueue()->setFocused(h.generation(),false); h.session.drainInput();
  EXPECT_EQ(channel->bytesInUse(),0u);
  h.session.inputQueue()->setFocused(h.generation(),true); through(h.session,3);
  h.session.inputQueue()->setFocused(h.generation(),false);
  ClipboardUpdate update; ASSERT_TRUE(channel->take(update)); EXPECT_FALSE(update.text);
}
TEST(SessionClipboard, ReconnectPreservesPolicyButRejectsOldAndForeignSessionLeases)
{
  rdr::MemOutStream wire; handshake(wire); Harness first(wire),second(wire);
  auto value=first.prepare("private"); ASSERT_EQ(value.result,ClipboardResult::Accepted);
  EXPECT_EQ(second.session.offerClipboard(value.text),0u);
  first.session.close(); rdr::MemInStream next(wire.data(),wire.length());
  first.session.clipboard()->setPolicy({false,true}); first.session.start("fixture",next,first.output); through(first.session,1);
  EXPECT_EQ(first.session.offerClipboard(value.text),0u);
  EXPECT_EQ(first.prepare("new").result,ClipboardResult::Disabled);
  EXPECT_EQ(value.text->text(),"private");
}

TEST(SessionClipboard, ConcurrentPreparationReceivePolicyAndConsumptionKeepBudgetBounded)
{
  rdr::MemOutStream wire; handshake(wire); Harness harness(wire);
  auto input = harness.session.inputQueue();
  ClipboardChannel channel(input,8,16);
  std::atomic<bool> failed{false};
  auto prepare = [&] {
    for (int i = 0; i < 1000; ++i) {
      auto text = channel.prepareLocal(1,"12345678");
      if (text.text && text.text->text() != "12345678") failed = true;
      if (channel.bytesInUse() > 16) failed = true;
    }
  };
  std::thread first(prepare), second(prepare), receive([&] {
    for (int i = 0; i < 1000; ++i) channel.receive("remote",channel.route());
  });
  for (int i = 0; i < 1000; ++i) {
    ClipboardUpdate update; channel.take(update);
    if (update.text && update.text->text() != "remote") failed = true;
    channel.setPolicy({true,bool(i%2)});
    input->setFocused(1,bool(i%3));
  }
  first.join(); second.join(); receive.join(); channel.invalidate();
  EXPECT_FALSE(failed); EXPECT_EQ(channel.bytesInUse(),0u);
}

TEST(SessionClipboard, WeakReadinessSignalsPublicationAndPolicyInvalidation)
{
  struct Counter : MailboxWakeup { unsigned calls = 0; void wake() noexcept override { ++calls; } };
  rdr::MemOutStream wire; handshake(wire); Harness h(wire);
  auto channel = h.session.clipboard(); auto counter = std::make_shared<Counter>();
  channel->setWakeup(counter); EXPECT_EQ(counter->calls,1u);
  channel->offerRemote(true); EXPECT_EQ(counter->calls,2u);
  channel->receive("text",channel->route()); EXPECT_EQ(counter->calls,3u);
  ClipboardUpdate update; ASSERT_TRUE(channel->take(update));
  EXPECT_EQ(update.kind,ClipboardUpdateKind::Text); EXPECT_EQ(counter->calls,3u);
  channel->setPolicy({false,true}); EXPECT_EQ(counter->calls,4u);
  channel->setPolicy({false,true}); EXPECT_EQ(counter->calls,4u);
  channel->invalidate(); EXPECT_EQ(counter->calls,5u);
  std::weak_ptr<Counter> weak = counter; counter.reset(); EXPECT_TRUE(weak.expired());
  channel->receive("later",channel->route()); ASSERT_TRUE(channel->take(update));
  EXPECT_EQ(update.kind,ClipboardUpdateKind::Text);
}
