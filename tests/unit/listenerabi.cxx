/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <tidyvnc.h>
#include <rfb/PixelFormat.h>
#include <rdr/MemOutStream.h>
#include "test-sockets.h"
#include <atomic>
#include <chrono>
#include <cstring>
#include <stdexcept>
#include <thread>
#include <vector>
using namespace std::chrono;
extern "C" void abi_test_fail_after(unsigned);
extern "C" int abi_test_injection_enabled(void);
namespace {
template<class T> T init() { T value{}; value.size = sizeof(T); value.version = TIDYVNC_ABI_VERSION; return value; }
void require(bool value) { if (!value) throw std::runtime_error("Listener ABI fixture failed"); }
template<class F> bool until(F test) {
  const auto deadline = steady_clock::now()+seconds(5);
  do { if (test()) return true; std::this_thread::sleep_for(milliseconds(1)); } while (steady_clock::now()<deadline);
  return test();
}
struct Handle {
  uint64_t id = 0;
  ~Handle() { if (id) tidyvnc_release(id,nullptr); }
  Handle() = default; Handle(const Handle&) = delete;
};
struct FD {
  int value;
  explicit FD(int fd) : value(fd) {}
  ~FD() { if (value >= 0) testsock::closeSocket(value); }
  FD(const FD&) = delete;
};
struct Fixture {
  Handle runtime, session, listener;
  tidyvnc_listener_options options = init<tidyvnc_listener_options>();
  Fixture() {
    auto r = init<tidyvnc_runtime_options>(); require(tidyvnc_runtime_options_init(&r,nullptr) == TIDYVNC_OK);
    require(tidyvnc_runtime_create(&r,&runtime.id,nullptr) == TIDYVNC_OK);
    require(tidyvnc_listener_options_init(&options,nullptr) == TIDYVNC_OK);
    options.port = 0; options.ipv6 = 0; options.address = {reinterpret_cast<const uint8_t*>("127.0.0.1"),9};
  }
  ~Fixture() {
    tidyvnc_runtime_shutdown(runtime.id,nullptr);
    EXPECT_TRUE(until([&] { return tidyvnc_runtime_poll_drained(runtime.id,nullptr) == TIDYVNC_OK; }));
  }
  void makeSession(uint32_t security = 1) {
    auto s = init<tidyvnc_session_options>(); require(tidyvnc_session_options_init(&s,nullptr) == TIDYVNC_OK);
    s.security_count = 1; s.security_types[0] = security;
    require(tidyvnc_session_create(runtime.id,&s,&session.id,nullptr) == TIDYVNC_OK);
  }
  tidyvnc_listener_snapshot snapshot() {
    auto value = init<tidyvnc_listener_snapshot>(); require(tidyvnc_listener_get_snapshot(listener.id,&value,nullptr) == TIDYVNC_OK); return value;
  }
  uint16_t start() {
    require(tidyvnc_listener_create(runtime.id,&options,&listener.id,nullptr) == TIDYVNC_OK);
    require(until([&] { return snapshot().state != TIDYVNC_LISTENER_STARTING; }));
    auto value = snapshot(); require(value.state == TIDYVNC_LISTENER_LISTENING && value.address_count == 1);
    return value.addresses[0].port;
  }
  std::vector<tidyvnc_listener_event> events() {
    std::vector<tidyvnc_listener_event> result;
    auto event = init<tidyvnc_listener_event>();
    for (;;) { auto status = tidyvnc_listener_take_event(listener.id,&event,nullptr);
      if (status == TIDYVNC_NO_CHANGE) return result;
      require(status == TIDYVNC_OK); result.push_back(event);
    }
  }
  uint64_t incoming() {
    uint64_t id = 0;
    require(until([&] { for (auto event : events()) if (event.kind == TIDYVNC_LISTENER_INCOMING) id = event.incoming_id; return id != 0; }));
    return id;
  }
};
int connectTo(uint16_t port) {
  FD fd(testsock::open(AF_INET)); require(fd.value >= 0);
  sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(port);
  require(::connect(fd.value,reinterpret_cast<sockaddr*>(&address),sizeof(address)) == 0);
  testsock::noSigpipe(fd.value);
  int result = fd.value; fd.value = -1; return result;
}
void send(int fd,const void* value,size_t length) {
  require(testsock::sendBytes(fd,value,length) == static_cast<long long>(length));
}
void readBytes(int fd,void* value,size_t length) {
  for (size_t offset = 0; offset < length;) {
    require(testsock::readable(fd,3000) == 1);
    auto count = testsock::recvBytes(fd,static_cast<char*>(value)+offset,length-offset); require(count > 0); offset += static_cast<size_t>(count);
  }
}
bool closed(int fd) {
  if (testsock::readable(fd,0) <= 0) return false;
  // Orderly close reads as 0; Windows may report a reset for unread data.
  char value; return testsock::recvBytes(fd,&value,1,MSG_PEEK) <= 0;
}
void negotiate(int fd,uint8_t security = 1) {
  send(fd,"RFB 003.008\n",12); char version[12]; readBytes(fd,version,12); require(std::memcmp(version,"RFB 003.008\n",12) == 0);
  uint8_t methods[] = {1,security}; send(fd,methods,2); uint8_t selected; readBytes(fd,&selected,1); require(selected == security);
}
void initialize(int fd) {
  const uint8_t okay[4] = {}; send(fd,okay,4); uint8_t shared; readBytes(fd,&shared,1);
  rdr::MemOutStream wire; wire.writeU16(2); wire.writeU16(2);
  rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0).write(&wire);
  wire.writeU32(4); wire.writeBytes(reinterpret_cast<const uint8_t*>("peer"),4); send(fd,wire.data(),wire.length());
}
}
TEST(ListenerABI, DefaultsValidationAndTypedHandlesPreserveOutputs) {
  Fixture f; auto abi = init<tidyvnc_abi_info>(); ASSERT_EQ(tidyvnc_get_abi(&abi,nullptr),TIDYVNC_OK);
  EXPECT_NE(abi.features & TIDYVNC_FEATURE_LISTENER,0u);
  auto defaults = init<tidyvnc_listener_options>(); ASSERT_EQ(tidyvnc_listener_options_init(&defaults,nullptr),TIDYVNC_OK);
  EXPECT_EQ(defaults.port,5500u); EXPECT_EQ(defaults.pending_capacity,8u); EXPECT_EQ(defaults.event_capacity,32u); EXPECT_EQ(defaults.pending_timeout_ms,30000u);
  for (int variant = 0; variant < 12; ++variant) {
    auto bad = f.options; uint64_t output = 0x1234;
    switch (variant) {
    case 0: bad.port = 65536; break; case 1: bad.ipv4 = 2; break; case 2: bad.ipv4 = 0; break;
    case 3: bad.pending_capacity = 65; break; case 4: bad.event_capacity = 3; break;
    case 5: bad.pending_timeout_ms = 0; break; case 6: bad.backlog = 65; break;
    case 7: bad.address = {reinterpret_cast<const uint8_t*>("example.invalid"),15}; break;
    case 8: bad.address = {nullptr,1}; break; case 9: bad.reserved = 1; break;
    case 10: bad.size = 0; break; case 11: bad.pending_timeout_ms = 60001; break;
    }
    EXPECT_EQ(tidyvnc_listener_create(f.runtime.id,&bad,&output,nullptr),TIDYVNC_INVALID_ARGUMENT) << variant;
    EXPECT_EQ(output,0x1234u);
  }
  f.start(); auto out = init<tidyvnc_listener_snapshot>(); out.pending = 999;
  EXPECT_EQ(tidyvnc_listener_get_snapshot(f.runtime.id,&out,nullptr),TIDYVNC_WRONG_HANDLE_TYPE); EXPECT_EQ(out.pending,999u);
  auto event = init<tidyvnc_listener_event>(); event.version = 2;
  EXPECT_EQ(tidyvnc_listener_take_event(f.listener.id,&event,nullptr),TIDYVNC_ABI_MISMATCH);
  auto events = f.events(); ASSERT_GE(events.size(),2u); EXPECT_EQ(events.front().snapshot.state,TIDYVNC_LISTENER_STARTING);
  for (size_t i = 1; i < events.size(); ++i) EXPECT_GT(events[i].sequence,events[i-1].sequence);
  event = init<tidyvnc_listener_event>(); event.sequence = 999;
  EXPECT_EQ(tidyvnc_listener_take_event(f.listener.id,&event,nullptr),TIDYVNC_NO_CHANGE); EXPECT_EQ(event.sequence,999u);
}
TEST(ListenerABI, RejectExpiryAndInvalidAdmissionNeverReadProtocol) {
  Fixture f; f.options.pending_timeout_ms = 150; auto port = f.start();
  FD peer(connectTo(port)); auto id = f.incoming(); send(peer.value,"RFB 003.008\n",12);
  EXPECT_EQ(testsock::readable(peer.value,15),0);
  auto operation = init<tidyvnc_operation>(); operation.operation = 99;
  EXPECT_EQ(tidyvnc_listener_accept(f.listener.id,id,0,&operation,nullptr),TIDYVNC_INVALID_HANDLE);
  EXPECT_EQ(operation.operation,99u); EXPECT_EQ(f.snapshot().pending,1u);
  EXPECT_EQ(tidyvnc_listener_reject(f.listener.id,id,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_listener_reject(f.listener.id,id,nullptr),TIDYVNC_NOT_PENDING);
  FD expiring(connectTo(port)); auto next = f.incoming(); EXPECT_GT(next,id);
  ASSERT_TRUE(until([&] { return f.snapshot().pending == 0; }));
  bool expired = false; for (auto event : f.events()) if (event.kind == TIDYVNC_LISTENER_EXPIRED && event.incoming_id == next) expired = true;
  EXPECT_TRUE(expired); EXPECT_TRUE(until([&] { return closed(expiring.value); }));
}
TEST(ListenerABI, ExplicitAcceptanceUsesReusableSessionAndSurvivesListenerStop) {
  Fixture f; f.makeSession(); auto port = f.start(); FD peer(connectTo(port)); auto id = f.incoming();
  auto operation = init<tidyvnc_operation>();
  ASSERT_EQ(tidyvnc_listener_accept(f.listener.id,id,f.session.id,&operation,nullptr),TIDYVNC_OK);
  EXPECT_NE(operation.operation,0u); EXPECT_GT(operation.generation,1u);
  EXPECT_EQ(tidyvnc_listener_accept(f.listener.id,id,f.session.id,&operation,nullptr),TIDYVNC_NOT_PENDING);
  ASSERT_EQ(tidyvnc_listener_stop(f.listener.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_listener_poll_drained(f.listener.id,nullptr) == TIDYVNC_OK; }));
  negotiate(peer.value); initialize(peer.value);
  auto snapshot = init<tidyvnc_snapshot>();
  ASSERT_TRUE(until([&] { tidyvnc_session_snapshot(f.session.id,&snapshot,nullptr); return snapshot.state == TIDYVNC_STATE_CONNECTED; }));
  EXPECT_EQ(snapshot.generation,operation.generation);
  bool completion = false; auto event = init<tidyvnc_event>();
  ASSERT_TRUE(until([&] { while (tidyvnc_session_take_event(f.session.id,&event,nullptr) == TIDYVNC_OK) {
    if (event.operation == operation.operation && event.result == TIDYVNC_OPERATION_SUCCEEDED) completion = true;
  } return completion; }));
  auto disconnect = init<tidyvnc_operation>(); ASSERT_EQ(tidyvnc_session_disconnect(f.session.id,snapshot.generation,&disconnect,nullptr),TIDYVNC_OK);
}
TEST(ListenerABI, AuthenticationUsesExistingPromptAndNumericPeerIdentity) {
  Fixture f; f.makeSession(2); FD peer(connectTo(f.start())); auto id = f.incoming(); auto operation = init<tidyvnc_operation>();
  ASSERT_EQ(tidyvnc_listener_accept(f.listener.id,id,f.session.id,&operation,nullptr),TIDYVNC_OK);
  negotiate(peer.value,2); uint8_t challenge[16]{}; send(peer.value,challenge,sizeof(challenge));
  Handle prompt;
  ASSERT_TRUE(until([&] { return tidyvnc_session_take_prompt(f.session.id,&prompt.id,nullptr) == TIDYVNC_OK; }));
  auto info = init<tidyvnc_prompt_info>(); ASSERT_EQ(tidyvnc_prompt_get(prompt.id,&info,nullptr),TIDYVNC_OK);
  EXPECT_EQ(std::string(reinterpret_cast<const char*>(info.server_name.data),info.server_name.length),"127.0.0.1");
  EXPECT_EQ(info.generation,operation.generation); EXPECT_EQ(info.kind,TIDYVNC_PROMPT_CREDENTIALS);
  uint8_t password[] = {'p'};
  ASSERT_EQ(tidyvnc_session_reply_credential_bytes(f.session.id,info.id,info.generation,{nullptr,0},{password,1},nullptr),TIDYVNC_OK);
  EXPECT_EQ(password[0],0); uint8_t response[16]; readBytes(peer.value,response,16); initialize(peer.value);
  auto snapshot = init<tidyvnc_snapshot>(); ASSERT_TRUE(until([&] { tidyvnc_session_snapshot(f.session.id,&snapshot,nullptr); return snapshot.state == TIDYVNC_STATE_CONNECTED; }));
}
TEST(ListenerABI, BusyAndAllocationFailureConsumeClaimedPeerWithoutReplacingSession) {
  Fixture f; f.makeSession(); auto port = f.start(); FD first(connectTo(port)); auto one = f.incoming(); auto operation = init<tidyvnc_operation>();
  ASSERT_EQ(tidyvnc_listener_accept(f.listener.id,one,f.session.id,&operation,nullptr),TIDYVNC_OK);
  FD second(connectTo(port)); auto two = f.incoming(); const auto original = operation;
  EXPECT_EQ(tidyvnc_listener_accept(f.listener.id,two,f.session.id,&operation,nullptr),TIDYVNC_BUSY);
  EXPECT_EQ(std::memcmp(&operation,&original,sizeof(operation)),0); EXPECT_EQ(f.snapshot().pending,0u);
  EXPECT_TRUE(until([&] { return closed(second.value); }));
  if (abi_test_injection_enabled()) {
    FD third(connectTo(port)); auto three = f.incoming(); abi_test_fail_after(1);
    auto status = tidyvnc_listener_accept(f.listener.id,three,f.session.id,&operation,nullptr); abi_test_fail_after(0);
    EXPECT_EQ(status,TIDYVNC_OUT_OF_MEMORY); EXPECT_EQ(f.snapshot().pending,0u);
    EXPECT_TRUE(until([&] { return closed(third.value); }));
  }
  negotiate(first.value); initialize(first.value);
}
TEST(ListenerABI, RuntimeShutdownAndFinalReleaseDrainUnclaimedSockets) {
  Fixture f; auto port = f.start(); FD peer(connectTo(port)); f.incoming();
  ASSERT_EQ(tidyvnc_runtime_shutdown(f.runtime.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_runtime_poll_drained(f.runtime.id,nullptr) == TIDYVNC_OK; }));
  EXPECT_EQ(tidyvnc_listener_poll_drained(f.listener.id,nullptr),TIDYVNC_OK); EXPECT_TRUE(closed(peer.value));
  uint64_t output = 99; EXPECT_EQ(tidyvnc_listener_create(f.runtime.id,&f.options,&output,nullptr),TIDYVNC_CLOSING); EXPECT_EQ(output,99u);
  Fixture released; FD other(connectTo(released.start())); released.incoming();
  auto id = released.listener.id; released.listener.id = 0; ASSERT_EQ(tidyvnc_release(id,nullptr),TIDYVNC_OK);
  EXPECT_TRUE(until([&] { return closed(other.value); })); EXPECT_EQ(tidyvnc_listener_stop(id,nullptr),TIDYVNC_INVALID_HANDLE);
}
TEST(ListenerABI, CapacityAndBindFailureRemainIndependentOfSessions) {
  Fixture f; auto port = f.start(); Handle a,b,c; for (auto out : {&a.id,&b.id,&c.id}) ASSERT_EQ(tidyvnc_listener_create(f.runtime.id,&f.options,out,nullptr),TIDYVNC_OK);
  uint64_t unchanged = 99; EXPECT_EQ(tidyvnc_listener_create(f.runtime.id,&f.options,&unchanged,nullptr),TIDYVNC_RESOURCE_LIMIT); EXPECT_EQ(unchanged,99u);
  f.makeSession(); Fixture conflict; conflict.options.port = port;
  ASSERT_EQ(tidyvnc_listener_create(conflict.runtime.id,&conflict.options,&conflict.listener.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return conflict.snapshot().state == TIDYVNC_LISTENER_FAILED; }));
  EXPECT_EQ(conflict.snapshot().error,TIDYVNC_LISTENER_ERROR_BIND); EXPECT_NE(conflict.snapshot().native_error,0);
}
TEST(ListenerABI, ConcurrentDecisionsClaimExactlyOnceAndOverflowDrains) {
  Fixture f; FD peer(connectTo(f.start())); auto id = f.incoming();
  std::atomic<unsigned> accepted{0}, missing{0}; std::vector<std::thread> threads;
  for (unsigned i = 0; i < 8; ++i) threads.emplace_back([&] { auto status = tidyvnc_listener_reject(f.listener.id,id,nullptr);
    if (status == TIDYVNC_OK) ++accepted;
    if (status == TIDYVNC_NOT_PENDING) ++missing; });
  for (auto& thread : threads) thread.join();
  EXPECT_EQ(accepted,1u); EXPECT_EQ(missing,7u);
  Fixture overflow; overflow.options.event_capacity = 4; auto port = overflow.start();
  FD first(connectTo(port)), second(connectTo(port)), third(connectTo(port));
  ASSERT_TRUE(until([&] { return overflow.snapshot().state == TIDYVNC_LISTENER_FAILED; }));
  EXPECT_EQ(overflow.snapshot().error,TIDYVNC_LISTENER_ERROR_EVENT_OVERFLOW);
  auto events = overflow.events(); ASSERT_EQ(events.size(),6u); EXPECT_EQ(events.back().snapshot.state,TIDYVNC_LISTENER_FAILED);
  for (size_t i = 1; i < events.size(); ++i) EXPECT_GT(events[i].sequence,events[i-1].sequence);
  EXPECT_TRUE(until([&] { return closed(first.value) && closed(second.value) && closed(third.value); }));
}
TEST(ListenerABI, ReadinessCallbacksReenterAndDrainBeforeContextRelease) {
  struct Probe {
    uint64_t listener = 0;
    std::atomic<unsigned> retained{0}, released{0}, incoming{0}, terminal{0}, failures{0};
    static void retain(void* p) { ++static_cast<Probe*>(p)->retained; }
    static void release(void* p) { ++static_cast<Probe*>(p)->released; }
    static void ready(void* p,uint64_t subscription,uint64_t generation) {
      auto& self = *static_cast<Probe*>(p);
      if (generation != 1 || tidyvnc_subscription_validate(subscription,generation,nullptr) != TIDYVNC_OK) ++self.failures;
      auto snapshot = init<tidyvnc_listener_snapshot>();
      if (tidyvnc_listener_get_snapshot(self.listener,&snapshot,nullptr) != TIDYVNC_OK) ++self.failures;
      auto event = init<tidyvnc_listener_event>();
      while (tidyvnc_listener_take_event(self.listener,&event,nullptr) == TIDYVNC_OK) {
        if (event.kind == TIDYVNC_LISTENER_INCOMING) ++self.incoming;
        if (event.snapshot.state == TIDYVNC_LISTENER_CLOSED) ++self.terminal;
      }
    }
  } probe;
  Fixture f; auto port = f.start(); probe.listener = f.listener.id;
  auto callbacks = init<tidyvnc_callbacks>(); callbacks.context = &probe;
  callbacks.retain_context = Probe::retain; callbacks.release_context = Probe::release; callbacks.ready = Probe::ready;
  Handle subscription;
  ASSERT_EQ(tidyvnc_listener_subscribe(f.listener.id,&callbacks,&subscription.id,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_subscription_validate(subscription.id,2,nullptr),TIDYVNC_STALE);
  uint64_t unchanged = 99; EXPECT_EQ(tidyvnc_listener_subscribe(f.listener.id,&callbacks,&unchanged,nullptr),TIDYVNC_BUSY); EXPECT_EQ(unchanged,99u);
  FD peer(connectTo(port)); ASSERT_TRUE(until([&] { return probe.incoming == 1; }));
  ASSERT_EQ(tidyvnc_listener_stop(f.listener.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return probe.terminal == 1; }));
  ASSERT_EQ(tidyvnc_subscription_unsubscribe(subscription.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_subscription_poll_drained(subscription.id,nullptr) == TIDYVNC_OK; }));
  EXPECT_EQ(probe.retained,2u); EXPECT_EQ(probe.released,2u); EXPECT_EQ(probe.failures,0u);
  EXPECT_EQ(tidyvnc_subscription_validate(subscription.id,1,nullptr),TIDYVNC_CANCELLED);
}
