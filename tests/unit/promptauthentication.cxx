/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/PromptAuthentication.h>
#include <rdr/MemInStream.h>
#include <rdr/MemOutStream.h>
#include <rfb/PixelFormat.h>
#include <future>
#include <stdexcept>
#include <thread>

using namespace viewer;
using namespace std::chrono;
namespace {
// A deadline also bounds failed tests; the UI never waits on the protocol worker.
struct Harness {
  std::promise<AuthenticationPrompt> ready;
  std::shared_ptr<PromptAuthentication> auth;
  Harness() : auth(std::make_shared<PromptAuthentication>([this] {
    AuthenticationPrompt prompt;
    if (!auth->takeRequest(prompt)) throw std::runtime_error("Missing prompt");
    ready.set_value(prompt);
  }, seconds(2))) { auth->beginAttempt(1,"fixture"); }
};
PromptCancelReason interrupted(PromptAuthentication& auth) {
  std::string password;
  try { auth.credentials(false,nullptr,&password); }
  catch (const PromptInterrupted& error) { return error.reason; }
  throw std::runtime_error("Expected interrupted prompt");
}
}
TEST(PromptAuthentication, RepliesAreTypedBoundedAndSingleUse)
{
  Harness h;
  auto worker = std::async(std::launch::async,[&] {
    std::string user,password;
    h.auth->credentials(true,&user,&password);
    return std::make_pair(user,password);
  });
  auto prompt=h.ready.get_future().get();
  EXPECT_EQ(prompt.serverName,"fixture"); EXPECT_TRUE(prompt.secure);
  EXPECT_TRUE(prompt.usernameRequired); EXPECT_EQ(prompt.generation,1u);
  AuthenticationPrompt duplicate;
  EXPECT_FALSE(h.auth->takeRequest(duplicate));
  EXPECT_EQ(h.auth->replyCredentials(prompt.id+1,1,"a","b"),PromptReply::StaleRequest);
  EXPECT_EQ(h.auth->replyCredentials(prompt.id,2,"a","b"),PromptReply::StaleRequest);
  EXPECT_EQ(h.auth->replyTrust(prompt.id,1,true),PromptReply::WrongKind);
  EXPECT_EQ(h.auth->replyCredentials(prompt.id,1,"a",std::string(4097,'x')),PromptReply::TooLarge);
  EXPECT_EQ(h.auth->replyCredentials(prompt.id,1,"alice","secret"),PromptReply::Accepted);
  EXPECT_EQ(h.auth->replyCredentials(prompt.id,1,"other","other"),PromptReply::NoPendingRequest);
  EXPECT_EQ(worker.get(),std::make_pair(std::string("alice"),std::string("secret")));
}
TEST(PromptAuthentication, CancellationDirectlyWakesParkedWorker)
{
  Harness h;
  auto worker=std::async(std::launch::async,[&] { return interrupted(*h.auth); });
  auto prompt=h.ready.get_future().get();
  EXPECT_THROW(h.auth->beginAttempt(2,"other"),std::logic_error);
  h.auth->cancel();
  EXPECT_EQ(worker.wait_for(seconds(1)),std::future_status::ready);
  EXPECT_EQ(worker.get(),PromptCancelReason::Cancelled);
  EXPECT_EQ(h.auth->replyCredentials(prompt.id,1,"","late"),PromptReply::NoPendingRequest);
}
TEST(PromptAuthentication, PeerClosureAndCancellationBeforeRequestAreRemembered)
{
  Harness h;
  h.auth->cancel(PromptCancelReason::PeerClosed);
  EXPECT_EQ(interrupted(*h.auth),PromptCancelReason::PeerClosed);
  h.auth->beginAttempt(2,"new-peer");
  h.auth->cancelPending();
  EXPECT_EQ(interrupted(*h.auth),PromptCancelReason::Cancelled);
}
TEST(PromptAuthentication, MonotonicDeadlineInterruptsUnansweredRequest)
{
  PromptAuthentication auth({},milliseconds(20));
  auth.beginAttempt(1,"fixture");
  const auto start=steady_clock::now();
  EXPECT_EQ(interrupted(auth),PromptCancelReason::TimedOut);
  EXPECT_GE(steady_clock::now()-start,milliseconds(20));
  EXPECT_LT(steady_clock::now()-start,seconds(2));
  AuthenticationPrompt prompt;
  EXPECT_FALSE(auth.takeRequest(prompt));
  EXPECT_EQ(interrupted(auth),PromptCancelReason::TimedOut);
}
TEST(PromptAuthentication, NotificationMayReplyImmediatelyWithoutLockReentry)
{
  PromptAuthentication* bridge=nullptr;
  PromptAuthentication auth([&] {
    AuthenticationPrompt prompt;
    ASSERT_TRUE(bridge->takeRequest(prompt));
    EXPECT_EQ(bridge->replyCredentials(prompt.id,prompt.generation,"",""),PromptReply::Accepted);
  });
  bridge=&auth; auth.beginAttempt(1,"fixture");
  std::string password="old";
  auth.credentials(false,nullptr,&password);
  EXPECT_TRUE(password.empty());
}
TEST(PromptAuthentication, ReplyAfterDeadlineFailsEvenBeforeWorkerStartsWaiting)
{
  PromptAuthentication* bridge=nullptr;
  PromptAuthentication auth([&] {
    AuthenticationPrompt prompt;
    ASSERT_TRUE(bridge->takeRequest(prompt));
    std::this_thread::sleep_for(milliseconds(30));
    EXPECT_EQ(bridge->replyTrust(prompt.id,prompt.generation,true),PromptReply::Expired);
  },milliseconds(10));
  bridge=&auth; auth.beginAttempt(1,"fixture");
  uint8_t key=1;
  try { auth.hostKey(&key,1,"fingerprint"); FAIL() << "Expected timeout"; }
  catch (const PromptInterrupted& e) { EXPECT_EQ(e.reason,PromptCancelReason::TimedOut); }
}
TEST(PromptAuthentication, CancelWinsBeforeAcceptedReplyIsConsumed)
{
  PromptAuthentication* bridge=nullptr;
  PromptAuthentication auth([&] {
    AuthenticationPrompt prompt;
    ASSERT_TRUE(bridge->takeRequest(prompt));
    EXPECT_EQ(bridge->replyCredentials(prompt.id,prompt.generation,"","secret"),PromptReply::Accepted);
    bridge->cancel();
  });
  bridge=&auth; auth.beginAttempt(1,"fixture");
  EXPECT_EQ(interrupted(auth),PromptCancelReason::Cancelled);
}
TEST(PromptAuthentication, ReconnectRejectsOldGenerationAndUsesNewIds)
{
  PromptAuthentication* bridge=nullptr;
  AuthenticationPrompt previous;
  PromptAuthentication auth([&] {
    AuthenticationPrompt prompt;
    ASSERT_TRUE(bridge->takeRequest(prompt));
    if (previous.id) {
      EXPECT_GT(prompt.id,previous.id);
      EXPECT_EQ(bridge->replyTrust(previous.id,previous.generation,true),PromptReply::StaleRequest);
    }
    previous=prompt;
    EXPECT_EQ(bridge->replyTrust(prompt.id,prompt.generation,false),PromptReply::Accepted);
  });
  bridge=&auth;
  uint8_t key[]={1,2,3};
  auth.beginAttempt(1,"first"); EXPECT_FALSE(auth.hostKey(key,3,"fingerprint"));
  auth.cancel(); auth.beginAttempt(2,"second");
  EXPECT_FALSE(auth.hostKey(key,3,"new-fingerprint"));
  EXPECT_EQ(previous.serverName,"second");
  EXPECT_THROW(auth.beginAttempt(2,"second"),std::invalid_argument);
}
TEST(PromptAuthentication, TrustRequestsOwnIdentityAndPreserveMetadata)
{
  Harness h;
  uint8_t bytes[]={7,8,9};
  auto worker=std::async(std::launch::async,[&] { return h.auth->certificate(42,bytes,3); });
  auto prompt=h.ready.get_future().get();
  bytes[0]=0; // Copy completed before the notification.
  EXPECT_EQ(prompt.identity,(std::vector<uint8_t>{7,8,9}));
  EXPECT_EQ(prompt.certificateStatus,42u); EXPECT_EQ(prompt.kind,PromptKind::Certificate);
  EXPECT_EQ(h.auth->replyCredentials(prompt.id,1,"","secret"),PromptReply::WrongKind);
  EXPECT_EQ(h.auth->replyTrust(prompt.id,1,true),PromptReply::Accepted);
  EXPECT_TRUE(worker.get());
}
TEST(PromptAuthentication, RejectsInvalidPayloadsAndTimeouts)
{
  EXPECT_THROW(PromptAuthentication({},milliseconds(0)),std::invalid_argument);
  EXPECT_THROW(PromptAuthentication({},hours(25)),std::invalid_argument);
  PromptAuthentication auth;
  EXPECT_THROW(auth.beginAttempt(0,"fixture"),std::invalid_argument);
  EXPECT_THROW(auth.beginAttempt(1,std::string(4097,'x')),std::invalid_argument);
  auth.beginAttempt(1,"fixture");
  uint8_t byte=0;
  EXPECT_THROW(auth.certificate(0,nullptr,1),std::invalid_argument);
  EXPECT_THROW(auth.certificate(0,&byte,65537),std::invalid_argument);
  EXPECT_THROW(auth.hostKey(&byte,1,nullptr),std::invalid_argument);
  EXPECT_THROW(auth.hostKey(&byte,1,std::string(4097,'x').c_str()),std::invalid_argument);
  EXPECT_THROW(auth.credentials(false,nullptr,nullptr),std::invalid_argument);
}
TEST(PromptAuthentication, ThrowingNotificationDoesNotStrandAttempt)
{
  PromptAuthentication auth([] { throw std::runtime_error("notification failed"); });
  auth.beginAttempt(1,"fixture");
  std::string password;
  EXPECT_THROW(auth.credentials(false,nullptr,&password),std::runtime_error);
  EXPECT_EQ(interrupted(auth),PromptCancelReason::Cancelled);
  EXPECT_NO_THROW(auth.beginAttempt(2,"retry"));
}
TEST(PromptAuthentication, IndependentSessionCanReplyWhileAnotherIsParked)
{
  Harness first,second;
  auto a=std::async(std::launch::async,[&] { return interrupted(*first.auth); });
  EXPECT_EQ(first.ready.get_future().get().kind,PromptKind::Credentials);
  auto b=std::async(std::launch::async,[&] {
    std::string password; second.auth->credentials(false,nullptr,&password); return password;
  });
  auto prompt=second.ready.get_future().get();
  EXPECT_EQ(second.auth->replyCredentials(prompt.id,1,"","second"),PromptReply::Accepted);
  EXPECT_EQ(b.get(),"second");
  first.auth->cancel(); EXPECT_EQ(a.get(),PromptCancelReason::Cancelled);
}
TEST(PromptAuthentication, CancelsRfbVncCallbackAndReconnectsWithFreshGeneration)
{
  std::promise<AuthenticationPrompt> notification;
  std::shared_ptr<PromptAuthentication> auth;
  auth=std::make_shared<PromptAuthentication>([&] {
    AuthenticationPrompt prompt;
    if (auth->takeRequest(prompt)) notification.set_value(prompt);
  },seconds(2));
  rdr::MemOutStream wire,output;
  wire.writeBytes(reinterpret_cast<const uint8_t*>("RFB 003.008\n"),12);
  wire.writeU8(1); wire.writeU8(rfb::secTypeVncAuth); wire.pad(16);
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeVncAuth}),{},{},auth);
  auto view=session.attachView();
  uint64_t oldId=0;
  for (uint64_t generation=1;generation<=2;++generation) {
    rdr::MemInStream input(wire.data(),wire.length());
    notification=std::promise<AuthenticationPrompt>();
    auto ready=notification.get_future();
    auto worker=std::async(std::launch::async,[&] {
      session.start("fixture",input,output);
      try { for (int i=0;i<16;++i) session.processMessage(); }
      catch (const PromptInterrupted& e) { return e.reason; }
      throw std::runtime_error("Expected cancelled VNC callback");
    });
    auto prompt=ready.get();
    EXPECT_EQ(prompt.generation,generation); EXPECT_GT(prompt.id,oldId);
    if (oldId) EXPECT_EQ(auth->replyCredentials(oldId,generation-1,"","stale"),PromptReply::StaleRequest);
    oldId=prompt.id;
    // The presentation mailbox remains usable while the protocol worker waits.
    ViewUpdate snapshot; view->take(snapshot);
    auth->cancel(PromptCancelReason::PeerClosed);
    EXPECT_EQ(worker.wait_for(seconds(1)),std::future_status::ready);
    EXPECT_EQ(worker.get(),PromptCancelReason::PeerClosed);
    EXPECT_FALSE(session.desktop().active);
    ASSERT_TRUE(view->take(snapshot)); EXPECT_EQ(snapshot.generation,generation+1);
  }
}
TEST(PromptAuthentication, CredentialReplyResumesRfbClientHandshake)
{
  std::shared_ptr<PromptAuthentication> auth;
  auth=std::make_shared<PromptAuthentication>([&] {
    AuthenticationPrompt prompt;
    ASSERT_TRUE(auth->takeRequest(prompt));
    EXPECT_FALSE(prompt.usernameRequired); EXPECT_FALSE(prompt.secure);
    EXPECT_EQ(auth->replyCredentials(prompt.id,prompt.generation,"","fixture-password"),PromptReply::Accepted);
  },seconds(2));
  rdr::MemOutStream wire,output;
  wire.writeBytes(reinterpret_cast<const uint8_t*>("RFB 003.008\n"),12);
  wire.writeU8(1); wire.writeU8(rfb::secTypeVncAuth); wire.pad(16);
  // Fixture SecurityResult, not a server-side password verifier (N1.11).
  wire.writeU32(0); wire.writeU16(1); wire.writeU16(1);
  rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0).write(&wire);
  wire.writeU32(0);
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient({rfb::secTypeVncAuth}),{},{},auth);
  session.start("fixture",input,output);
  for (int i=0; i<16 && !session.desktop().ready; ++i) ASSERT_TRUE(session.processMessage());
  EXPECT_TRUE(session.desktop().ready);
  EXPECT_GE(output.length(),30u);
}
