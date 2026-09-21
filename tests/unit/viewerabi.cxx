/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <tidyvnc.h>
#include <rfb/obfuscate.h>
#include <viewer/core/Endpoint.h>
#include <viewer/core/DesktopTransform.h>
#include <viewer/core/CursorRenderer.h>
#include <rfb/PixelFormat.h>
#include <rdr/MemOutStream.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <climits>
#include <condition_variable>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>
#include <arpa/inet.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
using namespace std::chrono;
namespace {
template<class T> T init() { T value{}; value.size = sizeof(T); value.version = TIDYVNC_ABI_VERSION; return value; }
template<class F> bool until(F test) { auto deadline = steady_clock::now()+seconds(5);
  do { if (test()) return true; std::this_thread::sleep_for(milliseconds(1)); } while (steady_clock::now()<deadline); return test(); }
struct Handle {
  ~Handle() { if (id) tidyvnc_release(id,nullptr); }
  Handle() = default;
  explicit Handle(uint64_t id_) : id(id_) {}
  Handle(const Handle&) = delete;
  uint64_t id = 0;
};
struct Client {
  Client() { auto r = init<tidyvnc_runtime_options>(); tidyvnc_runtime_options_init(&r,nullptr);
    if (tidyvnc_runtime_create(&r,&runtime.id,nullptr) != TIDYVNC_OK) throw std::runtime_error("Runtime fixture failed");
    options = init<tidyvnc_session_options>(); tidyvnc_session_options_init(&options,nullptr);
    options.security_count = 1; options.security_types[0] = 1;
  }
  ~Client() { if (runtime.id) { tidyvnc_runtime_shutdown(runtime.id,nullptr); until([&] { return tidyvnc_runtime_poll_drained(runtime.id,nullptr) == TIDYVNC_OK; }); } }
  void create() { ASSERT_EQ(tidyvnc_session_create(runtime.id,&options,&session.id,nullptr),TIDYVNC_OK); }
  Handle runtime, session;
  tidyvnc_session_options options;
};
class Peer {
public:
  explicit Peer(bool authentication_ = false) : authentication(authentication_) {
    listener = ::socket(AF_INET,SOCK_STREAM,0); require(listener >= 0);
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    require(::bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address)) == 0);
    socklen_t length = sizeof(address); require(::getsockname(listener,reinterpret_cast<sockaddr*>(&address),&length) == 0);
    port = ntohs(address.sin_port); require(::listen(listener,1) == 0);
    thread = std::thread([&] { run(); });
  }
  ~Peer() { stopping = true; if (thread.joinable()) thread.join(); if (listener >= 0) ::close(listener); }
  std::string endpoint() const { return "127.0.0.1::" + std::to_string(port); }
  bool contains(const std::vector<uint8_t>& bytes) {
    std::lock_guard<std::mutex> lock(mutex); return std::search(received.begin(),received.end(),bytes.begin(),bytes.end()) != received.end();
  }
  std::atomic<bool> verified{false}, established{false}, failed{false}, clipboardRequested{false}, updateRequested{false};
  std::atomic<bool> cursorRequested{false};
private:
  static void require(bool okay) { if (!okay) throw std::runtime_error("Peer fixture failed"); }
  bool ready(int fd) { pollfd event{fd,POLLIN,0}; const auto count = ::poll(&event,1,20); return count > 0; }
  void read(int fd,uint8_t* bytes,size_t length) {
    const auto deadline = steady_clock::now()+seconds(5);
    for (size_t offset = 0; offset < length;) {
      require(!stopping && steady_clock::now()<deadline);
      if (!ready(fd)) continue;
      const auto count = ::recv(fd,bytes+offset,length-offset,0); require(count>0); offset += count;
    }
  }
  void send(int fd,const uint8_t* bytes,size_t length) { require(::send(fd,bytes,length,0) == static_cast<ssize_t>(length)); }
  void run() {
    int fd = -1;
    try {
      while (!stopping && !ready(listener)) {}
      if (stopping) return;
      fd = ::accept(listener,nullptr,nullptr); require(fd >= 0);
#ifdef SO_NOSIGPIPE
      int one = 1; ::setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
#endif
      send(fd,reinterpret_cast<const uint8_t*>("RFB 003.008\n"),12);
      uint8_t input[16]; read(fd,input,12);
      const uint8_t security[] = {1,static_cast<uint8_t>(authentication ? 2 : 1)}; send(fd,security,2); read(fd,input,1);
      if (authentication) {
        uint8_t challenge[16]; for (int i=0;i<16;++i) challenge[i]=i;
        send(fd,challenge,16); read(fd,input,16);
        const uint8_t expected[]={0xb8,0x66,0x92,0x41,0x25,0xc8,0xee,0xbb,0x9d,0xeb,0xc1,0xdb,0x61,0xc5,0x38,0xe2};
        verified = std::memcmp(input,expected,16) == 0; require(verified);
      }
      const uint8_t okay[4] = {}; send(fd,okay,4); read(fd,input,1);
      rdr::MemOutStream wire; wire.writeU16(2); wire.writeU16(2);
      rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0).write(&wire);
      wire.writeU32(4); wire.writeBytes(reinterpret_cast<const uint8_t*>("peer"),4);
      wire.writeU8(0); wire.pad(1); wire.writeU16(1); // Raw framebuffer update.
      wire.writeU16(0); wire.writeU16(0); wire.writeU16(2); wire.writeU16(2); wire.writeU32(0);
      for (int i=0;i<4;++i) { wire.writeU8(10); wire.writeU8(20); wire.writeU8(30); wire.writeU8(0); }
      send(fd,wire.data(),wire.length()); established = true;
      while (!stopping) {
        if (cursorRequested.exchange(false)) {
          // RichCursor: transparent red then opaque green, hotspot on green.
          const uint8_t cursor[] = {0,0,0,1, 0,1,0,0, 0,2,0,1, 255,255,255,17,
                                   0,0,255,0, 0,255,0,0, 0x40};
          send(fd,cursor,sizeof(cursor));
        }
        if (updateRequested.exchange(false)) { const uint8_t update[] = {0,0,0,0}; send(fd,update,sizeof(update)); }
        if (clipboardRequested.exchange(false)) {
          const uint8_t clipboard[] = {3,0,0,0,0,0,0,6,'c','a','f',0xe9,'\r','\n'};
          send(fd,clipboard,sizeof(clipboard));
        }
        if (!ready(fd)) continue;
        uint8_t bytes[4096]; const auto count = ::recv(fd,bytes,sizeof(bytes),0); if (count <= 0) break;
        std::lock_guard<std::mutex> lock(mutex); received.insert(received.end(),bytes,bytes+count);
      }
    } catch (...) { if (!stopping) failed = true; }
    if (fd >= 0) ::close(fd);
  }
  const bool authentication;
  int listener = -1; uint16_t port = 0;
  std::atomic<bool> stopping{false};
  std::thread thread;
  std::mutex mutex;
  std::vector<uint8_t> received;
};
tidyvnc_operation connect(uint64_t session,Peer& peer) {
  auto options = init<tidyvnc_connect_options>(); tidyvnc_connect_options_init(&options,nullptr);
  auto endpoint = peer.endpoint(); options.endpoint = {reinterpret_cast<const uint8_t*>(endpoint.data()),endpoint.size()};
  auto operation = init<tidyvnc_operation>();
  EXPECT_EQ(tidyvnc_session_connect(session,&options,&operation,nullptr),TIDYVNC_OK);
  endpoint.assign(endpoint.size(),'x'); // Bridge must own its asynchronous input.
  return operation;
}
bool completion(uint64_t session,uint64_t id,tidyvnc_event& found) {
  return until([&] { auto event = init<tidyvnc_event>();
    while (tidyvnc_session_take_event(session,&event,nullptr) == TIDYVNC_OK)
      if (event.kind == TIDYVNC_EVENT_COMPLETION && event.operation == id) { found = event; return true; }
    return false;
  });
}

struct CallbackProbe {
  ~CallbackProbe() { if (image) tidyvnc_release(image,nullptr); if (clipboard.text) tidyvnc_release(clipboard.text,nullptr); }
  tidyvnc_clipboard_update clipboard{};
  std::mutex mutex;
  std::condition_variable changed;
  unsigned calls = 0, finished = 0;
  bool blocked = false, timedOut = false, sessionDrained = false;
  uint64_t generation = 0, image = 0;
  std::thread::id callbackThread, releaseThread;
  std::atomic<unsigned> retains{0}, releases{0};
  std::vector<tidyvnc_event> events;
  unsigned prompts = 0;
  std::function<void(uint64_t,uint64_t)> action;
  template<class F> bool wait(F predicate) {
    std::unique_lock<std::mutex> lock(mutex);
    return changed.wait_for(lock,seconds(5),predicate);
  }
  void unblock() { { std::lock_guard<std::mutex> lock(mutex); blocked = false; } changed.notify_all(); }
};
struct CallbackContext {
  explicit CallbackContext(std::shared_ptr<CallbackProbe> probe_) : probe(std::move(probe_)) {}
  std::shared_ptr<CallbackProbe> probe;
  std::atomic<unsigned> references{1};
  void drop() { if (references.fetch_sub(1) == 1) delete this; }
  static void retain(void* opaque) {
    auto self = static_cast<CallbackContext*>(opaque); ++self->references; ++self->probe->retains;
  }
  static void release(void* opaque) {
    auto self = static_cast<CallbackContext*>(opaque); auto probe = self->probe;
    { std::lock_guard<std::mutex> lock(probe->mutex); probe->releaseThread = std::this_thread::get_id(); }
    ++probe->releases; self->drop(); probe->changed.notify_all();
  }
  static void ready(void* opaque,uint64_t subscription,uint64_t generation) {
    auto probe = static_cast<CallbackContext*>(opaque)->probe;
    { std::unique_lock<std::mutex> lock(probe->mutex);
      ++probe->calls; probe->generation = generation; probe->callbackThread = std::this_thread::get_id();
      probe->changed.notify_all();
      if (!probe->changed.wait_for(lock,seconds(5),[&] { return !probe->blocked; })) probe->timedOut = true;
    }
    if (probe->action) probe->action(subscription,generation);
    { std::lock_guard<std::mutex> lock(probe->mutex); ++probe->finished; }
    probe->changed.notify_all();
  }
};
struct Watch {
  explicit Watch(std::shared_ptr<CallbackProbe> probe_ = std::make_shared<CallbackProbe>()) : probe(std::move(probe_)) {}
  ~Watch() {
    probe->unblock();
    if (subscription.id) {
      EXPECT_EQ(tidyvnc_subscription_unsubscribe(subscription.id,nullptr),TIDYVNC_OK);
      EXPECT_TRUE(until([&] { return tidyvnc_subscription_poll_drained(subscription.id,nullptr) == TIDYVNC_OK; }));
    }
  }
  uint32_t subscribe(uint64_t session) {
    auto context = new CallbackContext(probe); auto callbacks = init<tidyvnc_callbacks>();
    callbacks.context = context; callbacks.retain_context = CallbackContext::retain;
    callbacks.release_context = CallbackContext::release; callbacks.ready = CallbackContext::ready;
    const auto result = tidyvnc_session_subscribe(session,&callbacks,&subscription.id,nullptr);
    context->drop(); return result;
  }
  std::shared_ptr<CallbackProbe> probe;
  Handle subscription;
};
}
TEST(ViewerABI, ConnectionInformationCopiesNegotiatedValuesAndChecksGeneration)
{
  Client client; client.create(); auto info = init<tidyvnc_connection_info>();
  const auto empty = info;
  EXPECT_EQ(tidyvnc_session_information(0,1,&info,nullptr),TIDYVNC_INVALID_HANDLE);
  EXPECT_EQ(tidyvnc_session_information(client.runtime.id,1,&info,nullptr),TIDYVNC_WRONG_HANDLE_TYPE);
  EXPECT_EQ(tidyvnc_session_information(client.session.id,1,&info,nullptr),TIDYVNC_NOT_CONNECTED);
  EXPECT_EQ(std::memcmp(&empty,&info,sizeof(info)),0);
  Peer peer; auto operation = connect(client.session.id,peer); tidyvnc_event event{};
  ASSERT_TRUE(completion(client.session.id,operation.operation,event));
  ASSERT_TRUE(until([&] { return tidyvnc_session_information(client.session.id,operation.generation,&info,nullptr) == TIDYVNC_OK && info.snapshot.frames > 0; }));
  EXPECT_EQ(info.protocol_major,3u); EXPECT_EQ(info.protocol_minor,8u);
  EXPECT_STREQ(info.desktop_name,"peer"); EXPECT_STREQ(info.security_name,"None"); EXPECT_EQ(info.credentials_secure,0u);
  EXPECT_EQ(info.last_encoding,0); EXPECT_STREQ(info.last_encoding_name,"raw");
  EXPECT_EQ(info.snapshot.width,2u); EXPECT_EQ(info.snapshot.height,2u); EXPECT_GT(info.bits_per_second,0u);
  EXPECT_NE(std::string(info.pixel_format).find("24"),std::string::npos);
  const auto copied = info;
  EXPECT_EQ(tidyvnc_session_information(client.session.id,operation.generation+1,&info,nullptr),TIDYVNC_STALE);
  EXPECT_EQ(std::memcmp(&copied,&info,sizeof(info)),0);
  std::atomic<bool> failed{false};
  auto read = [&] { for (int i=0;i<200;++i) { auto value=init<tidyvnc_connection_info>();
    if (tidyvnc_session_information(client.session.id,operation.generation,&value,nullptr) != TIDYVNC_OK ||
        std::strcmp(value.desktop_name,"peer") != 0 || value.snapshot.generation != operation.generation) failed=true;
  } };
  std::thread one(read), two(read), three(read); one.join(); two.join(); three.join(); EXPECT_FALSE(failed);
  auto disconnect=init<tidyvnc_operation>();
  ASSERT_EQ(tidyvnc_session_disconnect(client.session.id,operation.generation,&disconnect,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(completion(client.session.id,disconnect.operation,event));
  EXPECT_EQ(tidyvnc_session_information(client.session.id,event.snapshot.generation,&info,nullptr),TIDYVNC_NOT_CONNECTED);
  EXPECT_EQ(std::memcmp(&copied,&info,sizeof(info)),0);
  Peer next; auto reconnect=connect(client.session.id,next); ASSERT_TRUE(completion(client.session.id,reconnect.operation,event));
  EXPECT_EQ(tidyvnc_session_information(client.session.id,operation.generation,&info,nullptr),TIDYVNC_STALE);
  EXPECT_STREQ(copied.desktop_name,"peer");
}

TEST(ViewerABI, ConnectFramesInputDisconnectAndReconnectThroughCOnlyHandles)
{
  Client client; client.create(); Peer first; auto operation = connect(client.session.id,first);
  tidyvnc_event event{}; ASSERT_TRUE(completion(client.session.id,operation.operation,event));
  EXPECT_EQ(event.result,TIDYVNC_OPERATION_SUCCEEDED); EXPECT_EQ(event.snapshot.state,TIDYVNC_STATE_CONNECTED);
  auto update = init<tidyvnc_view_update>(); Handle retained;
  ASSERT_TRUE(until([&] {
    if (tidyvnc_session_take_view(client.session.id,&update,nullptr) != TIDYVNC_OK) return false;
    if (update.cursor) tidyvnc_release(update.cursor,nullptr);
    if (!update.frame) return false;
    auto info = init<tidyvnc_image_info>(); tidyvnc_image_get(update.frame,&info,nullptr);
    if (info.pixels.data[0] != 10) { tidyvnc_release(update.frame,nullptr); return false; }
    retained.id = update.frame; return true;
  }));
  auto info = init<tidyvnc_image_info>(); ASSERT_EQ(tidyvnc_image_get(retained.id,&info,nullptr),TIDYVNC_OK);
  EXPECT_EQ(info.width,2u); EXPECT_EQ(info.height,2u); EXPECT_EQ(info.stride,8u); EXPECT_EQ(info.pixels.length,16u);
  EXPECT_EQ(info.format,TIDYVNC_PIXEL_BGRA8); EXPECT_EQ(info.origin,TIDYVNC_ORIGIN_TOP_LEFT);
  ASSERT_EQ(tidyvnc_session_key(client.session.id,operation.generation,1,'A',0,1,nullptr),TIDYVNC_OK);
  ASSERT_EQ(tidyvnc_session_pointer(client.session.id,operation.generation,1,1,1,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return first.contains({4,1,0,0,0,0,0,'A'}) && first.contains({5,1,0,1,0,1}); }));
  EXPECT_EQ(tidyvnc_session_focus(client.session.id,operation.generation,0,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_session_key(client.session.id,operation.generation,2,'B',0,1,nullptr),TIDYVNC_UNFOCUSED);
  ASSERT_TRUE(until([&] { return first.contains({4,0,0,0,0,0,0,'A'}) && first.contains({5,0,0,1,0,1}); }));
  auto disconnect = init<tidyvnc_operation>();
  ASSERT_EQ(tidyvnc_session_disconnect(client.session.id,operation.generation,&disconnect,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(completion(client.session.id,disconnect.operation,event)); EXPECT_EQ(event.result,TIDYVNC_OPERATION_SUCCEEDED);
  Peer second; auto next = connect(client.session.id,second); ASSERT_GT(next.generation,operation.generation);
  ASSERT_TRUE(completion(client.session.id,next.operation,event)); EXPECT_EQ(event.result,TIDYVNC_OPERATION_SUCCEEDED);
  EXPECT_EQ(tidyvnc_session_key(client.session.id,operation.generation,1,'A',0,1,nullptr),TIDYVNC_STALE);
  EXPECT_EQ(info.pixels.data[0],10); // Borrow stays valid across resize/reconnect/close.
  ASSERT_EQ(tidyvnc_session_close(client.session.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_session_poll_drained(client.session.id,nullptr) == TIDYVNC_OK; }));
  ASSERT_EQ(tidyvnc_runtime_shutdown(client.runtime.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_runtime_poll_drained(client.runtime.id,nullptr) == TIDYVNC_OK; }));
  auto oldSession = client.session.id;
  ASSERT_EQ(tidyvnc_release(client.session.id,nullptr),TIDYVNC_OK); client.session.id = 0;
  ASSERT_EQ(tidyvnc_release(client.runtime.id,nullptr),TIDYVNC_OK); client.runtime.id = 0;
  EXPECT_EQ(tidyvnc_session_close(oldSession,nullptr),TIDYVNC_INVALID_HANDLE);
  EXPECT_EQ(info.pixels.data[0],10);
  EXPECT_EQ(tidyvnc_image_get(retained.id,&info,nullptr),TIDYVNC_OK);
  EXPECT_FALSE(first.failed); EXPECT_FALSE(second.failed);
}
TEST(ViewerABI, CredentialsPromptUsesOwnedMetadataAndWipesSubmittedSecrets)
{
  Client client; client.options.security_types[0] = 2; client.create(); Peer peer(true);
  auto operation = connect(client.session.id,peer); Handle prompt;
  ASSERT_TRUE(until([&] { return tidyvnc_session_take_prompt(client.session.id,&prompt.id,nullptr) == TIDYVNC_OK; }));
  auto info = init<tidyvnc_prompt_info>(); ASSERT_EQ(tidyvnc_prompt_get(prompt.id,&info,nullptr),TIDYVNC_OK);
  uint32_t securityType = 99;
  ASSERT_EQ(tidyvnc_prompt_security_type(prompt.id,&securityType,nullptr),TIDYVNC_OK);
  EXPECT_EQ(securityType,2u);
  EXPECT_EQ(tidyvnc_prompt_security_type(prompt.id,nullptr,nullptr),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(tidyvnc_prompt_security_type(client.session.id,&securityType,nullptr),TIDYVNC_WRONG_HANDLE_TYPE);
  EXPECT_EQ(securityType,2u);
  EXPECT_EQ(info.kind,TIDYVNC_PROMPT_CREDENTIALS); EXPECT_EQ(info.generation,operation.generation); EXPECT_FALSE(info.secure);
  EXPECT_EQ(std::string(reinterpret_cast<const char*>(info.server_name.data),info.server_name.length),"127.0.0.1");
  uint8_t secret[] = {'p','a','s','s','w','o','r','d'};
  EXPECT_EQ(tidyvnc_session_reply_credentials(client.session.id,info.id,info.generation+1,{nullptr,0},{secret,sizeof(secret)},nullptr),TIDYVNC_STALE);
  for (auto byte : secret) EXPECT_EQ(byte,0);
  std::memcpy(secret,"password",8);
  ASSERT_EQ(tidyvnc_session_reply_credentials(client.session.id,info.id,info.generation,{nullptr,0},{secret,sizeof(secret)},nullptr),TIDYVNC_OK);
  for (auto byte : secret) EXPECT_EQ(byte,0);
  tidyvnc_event event{}; ASSERT_TRUE(completion(client.session.id,operation.operation,event));
  EXPECT_EQ(event.result,TIDYVNC_OPERATION_SUCCEEDED); EXPECT_TRUE(peer.verified);
  EXPECT_EQ(tidyvnc_session_reply_trust(client.session.id,info.id,info.generation,1,nullptr),TIDYVNC_NOT_PENDING);
  ASSERT_EQ(tidyvnc_session_close(client.session.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_session_poll_drained(client.session.id,nullptr) == TIDYVNC_OK; }));
  EXPECT_EQ(std::string(reinterpret_cast<const char*>(info.server_name.data),info.server_name.length),"127.0.0.1");
}
TEST(ViewerABI, FinalRuntimeReleaseCancelsParkedAuthenticationWithoutJoiningCaller)
{
  Client client; client.options.security_types[0] = 2; client.create(); Peer peer(true);
  connect(client.session.id,peer); Handle prompt;
  ASSERT_TRUE(until([&] { return tidyvnc_session_take_prompt(client.session.id,&prompt.id,nullptr) == TIDYVNC_OK; }));
  const auto before = steady_clock::now(); auto runtime = client.runtime.id; client.runtime.id = 0;
  ASSERT_EQ(tidyvnc_release(runtime,nullptr),TIDYVNC_OK);
  EXPECT_LT(steady_clock::now()-before,seconds(1));
  EXPECT_EQ(tidyvnc_runtime_poll_drained(runtime,nullptr),TIDYVNC_INVALID_HANDLE);
  ASSERT_TRUE(until([&] { return tidyvnc_session_poll_drained(client.session.id,nullptr) == TIDYVNC_OK; }));
  auto snapshot = init<tidyvnc_snapshot>(); ASSERT_EQ(tidyvnc_session_snapshot(client.session.id,&snapshot,nullptr),TIDYVNC_OK);
  EXPECT_EQ(snapshot.state,TIDYVNC_STATE_CLOSED); EXPECT_EQ(snapshot.end_reason,TIDYVNC_END_CANCELLED);
}
TEST(ViewerABI, ConcurrentRetainReleaseAndTypedQueriesPreserveLiveHandles)
{
  Client client; client.create(); std::atomic<bool> failed{false};
  auto exercise = [&] {
    for (unsigned i=0;i<500;++i) {
      if (tidyvnc_retain(client.session.id,nullptr) != TIDYVNC_OK) failed = true;
      auto snapshot = init<tidyvnc_snapshot>();
      if (tidyvnc_session_snapshot(client.session.id,&snapshot,nullptr) != TIDYVNC_OK) failed = true;
      if (tidyvnc_release(client.session.id,nullptr) != TIDYVNC_OK) failed = true;
    }
  };
  std::thread one(exercise), two(exercise), three(exercise); one.join(); two.join(); three.join(); EXPECT_FALSE(failed);
}
TEST(ViewerABI, RuntimeAndSessionCapacityRejectWithoutPublishingHandles)
{
  auto settings = init<tidyvnc_runtime_options>(); tidyvnc_runtime_options_init(&settings,nullptr); settings.session_capacity = 1;
  Handle runtime; ASSERT_EQ(tidyvnc_runtime_create(&settings,&runtime.id,nullptr),TIDYVNC_OK);
  auto options = init<tidyvnc_session_options>(); tidyvnc_session_options_init(&options,nullptr);
  Handle first, rejected; ASSERT_EQ(tidyvnc_session_create(runtime.id,&options,&first.id,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_session_create(runtime.id,&options,&rejected.id,nullptr),TIDYVNC_RESOURCE_LIMIT); EXPECT_EQ(rejected.id,0u);
  options.security_count = 33; EXPECT_EQ(tidyvnc_session_create(runtime.id,&options,&rejected.id,nullptr),TIDYVNC_INVALID_ARGUMENT);
  options.security_count = 1; options.security_types[0] = UINT32_MAX;
  EXPECT_EQ(tidyvnc_session_create(runtime.id,&options,&rejected.id,nullptr),TIDYVNC_UNSUPPORTED);
  EXPECT_EQ(tidyvnc_runtime_shutdown(runtime.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_runtime_poll_drained(runtime.id,nullptr) == TIDYVNC_OK; }));
}

TEST(ViewerABI, AnotherSessionProgressesWhileCredentialsAreParked)
{
  Client client; client.options.security_types[0] = 2; client.create(); Peer waiting(true);
  auto pending = connect(client.session.id,waiting); Handle prompt;
  ASSERT_TRUE(until([&] { return tidyvnc_session_take_prompt(client.session.id,&prompt.id,nullptr) == TIDYVNC_OK; }));
  Handle second; auto options = client.options; options.security_types[0] = 1;
  ASSERT_EQ(tidyvnc_session_create(client.runtime.id,&options,&second.id,nullptr),TIDYVNC_OK);
  Peer serving; auto active = connect(second.id,serving); tidyvnc_event event{};
  ASSERT_TRUE(completion(second.id,active.operation,event)); EXPECT_EQ(event.result,TIDYVNC_OPERATION_SUCCEEDED);
  auto refresh = init<tidyvnc_operation>();
  ASSERT_EQ(tidyvnc_session_refresh(second.id,active.generation,&refresh,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(completion(second.id,refresh.operation,event)); EXPECT_EQ(event.result,TIDYVNC_OPERATION_SUCCEEDED);
  ASSERT_EQ(tidyvnc_session_cancel_operation(client.session.id,pending.generation,pending.operation,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(completion(client.session.id,pending.operation,event)); EXPECT_EQ(event.result,TIDYVNC_OPERATION_CANCELLED);
  auto snapshot = init<tidyvnc_snapshot>();
  ASSERT_EQ(tidyvnc_session_snapshot(second.id,&snapshot,nullptr),TIDYVNC_OK);
  EXPECT_EQ(snapshot.state,TIDYVNC_STATE_CONNECTED); EXPECT_FALSE(serving.failed);
}

TEST(ViewerABI, ApplicationRuntimeCapacityRecoversAfterJoinedShutdown)
{
  auto abi = init<tidyvnc_abi_info>(); ASSERT_EQ(tidyvnc_get_abi(&abi,nullptr),TIDYVNC_OK);
  auto options = init<tidyvnc_runtime_options>(); tidyvnc_runtime_options_init(&options,nullptr);
  std::vector<uint64_t> runtimes(abi.runtime_capacity,0);
  for (auto& id : runtimes) ASSERT_EQ(tidyvnc_runtime_create(&options,&id,nullptr),TIDYVNC_OK);
  Handle rejected;
  EXPECT_EQ(tidyvnc_runtime_create(&options,&rejected.id,nullptr),TIDYVNC_RESOURCE_LIMIT); EXPECT_EQ(rejected.id,0u);
  auto old = runtimes.back(); ASSERT_EQ(tidyvnc_runtime_shutdown(old,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_runtime_poll_drained(old,nullptr) == TIDYVNC_OK; }));
  ASSERT_EQ(tidyvnc_release(old,nullptr),TIDYVNC_OK);
  ASSERT_EQ(tidyvnc_runtime_create(&options,&runtimes.back(),nullptr),TIDYVNC_OK); EXPECT_NE(runtimes.back(),old);
  for (auto id : runtimes) ASSERT_EQ(tidyvnc_runtime_shutdown(id,nullptr),TIDYVNC_OK);
  for (auto id : runtimes) {
    ASSERT_TRUE(until([&] { return tidyvnc_runtime_poll_drained(id,nullptr) == TIDYVNC_OK; }));
    EXPECT_EQ(tidyvnc_release(id,nullptr),TIDYVNC_OK);
  }
}

TEST(ViewerABI, CallbackOwnsContextAndCanUnsubscribeAndReadMailboxesItself)
{
  Client client; client.create(); Watch watch;
  watch.probe->action = [&](uint64_t subscription,uint64_t generation) {
    EXPECT_EQ(generation,1u);
    EXPECT_EQ(tidyvnc_retain(subscription,nullptr),TIDYVNC_OK);
    EXPECT_EQ(tidyvnc_subscription_validate(subscription,generation,nullptr),TIDYVNC_OK);
    auto event = init<tidyvnc_event>();
    EXPECT_EQ(tidyvnc_session_take_event(client.session.id,&event,nullptr),TIDYVNC_OK);
    EXPECT_EQ(event.kind,TIDYVNC_EVENT_SNAPSHOT);
    auto view = init<tidyvnc_view_update>();
    EXPECT_EQ(tidyvnc_session_take_view(client.session.id,&view,nullptr),TIDYVNC_OK);
    EXPECT_EQ(view.frame,0u);
    EXPECT_EQ(tidyvnc_subscription_unsubscribe(subscription,nullptr),TIDYVNC_OK);
    EXPECT_EQ(tidyvnc_subscription_poll_drained(subscription,nullptr),TIDYVNC_PENDING);
    EXPECT_EQ(tidyvnc_release(subscription,nullptr),TIDYVNC_OK);
  };
  ASSERT_EQ(watch.subscribe(client.session.id),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_subscription_poll_drained(watch.subscription.id,nullptr) == TIDYVNC_OK; }));
  EXPECT_EQ(watch.probe->retains,1u); EXPECT_EQ(watch.probe->releases,1u);
  EXPECT_EQ(watch.probe->calls,1u); EXPECT_EQ(watch.probe->finished,1u);
  EXPECT_NE(watch.probe->callbackThread,std::this_thread::get_id());
  EXPECT_EQ(watch.probe->callbackThread,watch.probe->releaseThread);
  EXPECT_EQ(tidyvnc_subscription_validate(watch.subscription.id,1,nullptr),TIDYVNC_CANCELLED);
  EXPECT_EQ(tidyvnc_subscription_unsubscribe(client.session.id,nullptr),TIDYVNC_WRONG_HANDLE_TYPE);
}

TEST(ViewerABI, UnsubscribeCancelsQueuedReadinessAndDrainWaitsForRunningCallback)
{
  Client client; client.create(); Watch watch; watch.probe->blocked = true;
  ASSERT_EQ(watch.subscribe(client.session.id),TIDYVNC_OK);
  ASSERT_TRUE(watch.probe->wait([&] { return watch.probe->calls == 1; }));
  Peer peer; auto operation = connect(client.session.id,peer); tidyvnc_event completed{};
  EXPECT_EQ(tidyvnc_subscription_validate(watch.subscription.id,1,nullptr),TIDYVNC_STALE);
  EXPECT_EQ(tidyvnc_subscription_validate(watch.subscription.id,operation.generation,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(completion(client.session.id,operation.operation,completed)); // Worker runs despite blocked host callback.
  EXPECT_EQ(completed.result,TIDYVNC_OPERATION_SUCCEEDED);
  auto start = steady_clock::now();
  EXPECT_EQ(tidyvnc_subscription_unsubscribe(watch.subscription.id,nullptr),TIDYVNC_OK);
  EXPECT_LT(steady_clock::now()-start,seconds(1));
  EXPECT_EQ(tidyvnc_subscription_poll_drained(watch.subscription.id,nullptr),TIDYVNC_PENDING);
  EXPECT_EQ(watch.probe->releases,0u);
  Watch rejected; EXPECT_EQ(rejected.subscribe(client.session.id),TIDYVNC_BUSY);
  EXPECT_EQ(rejected.subscription.id,0u); EXPECT_EQ(rejected.probe->retains,1u); EXPECT_EQ(rejected.probe->releases,1u);
  watch.probe->unblock();
  ASSERT_TRUE(until([&] { return tidyvnc_subscription_poll_drained(watch.subscription.id,nullptr) == TIDYVNC_OK; }));
  EXPECT_EQ(watch.probe->calls,1u); EXPECT_FALSE(watch.probe->timedOut);
  Watch replacement; ASSERT_EQ(replacement.subscribe(client.session.id),TIDYVNC_OK);
  ASSERT_TRUE(replacement.probe->wait([&] { return replacement.probe->finished > 0; }));
  EXPECT_EQ(tidyvnc_subscription_validate(replacement.subscription.id,operation.generation,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_subscription_validate(replacement.subscription.id,1,nullptr),TIDYVNC_STALE);
  EXPECT_NE(replacement.subscription.id,watch.subscription.id);
}

TEST(ViewerABI, FinalSessionReleaseCancelsCallbackBeforeDispatcherStartsIt)
{
  Client client; client.create(); Watch blocker; blocker.probe->blocked = true;
  ASSERT_EQ(blocker.subscribe(client.session.id),TIDYVNC_OK);
  ASSERT_TRUE(blocker.probe->wait([&] { return blocker.probe->calls == 1; }));
  Handle second; ASSERT_EQ(tidyvnc_session_create(client.runtime.id,&client.options,&second.id,nullptr),TIDYVNC_OK);
  Watch queued; ASSERT_EQ(queued.subscribe(second.id),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_release(second.id,nullptr),TIDYVNC_OK); second.id = 0;
  EXPECT_EQ(tidyvnc_subscription_validate(queued.subscription.id,1,nullptr),TIDYVNC_CANCELLED);
  EXPECT_EQ(tidyvnc_subscription_poll_drained(queued.subscription.id,nullptr),TIDYVNC_PENDING);
  blocker.probe->unblock();
  ASSERT_TRUE(until([&] { return tidyvnc_subscription_poll_drained(queued.subscription.id,nullptr) == TIDYVNC_OK; }));
  EXPECT_EQ(queued.probe->calls,0u); EXPECT_EQ(queued.probe->releases,1u);
}

TEST(ViewerABI, CallbacksDriveAuthenticationFramesCompletionsAndJoinedDrainWithoutPolling)
{
  Client client; client.options.security_types[0] = 2; client.create(); Watch watch;
  auto* probe = watch.probe.get(); const auto session = client.session.id;
  probe->action = [probe,session](uint64_t,uint64_t) {
    std::lock_guard<std::mutex> lock(probe->mutex);
    auto event = init<tidyvnc_event>();
    while (tidyvnc_session_take_event(session,&event,nullptr) == TIDYVNC_OK) probe->events.push_back(event);
    Handle prompt;
    if (tidyvnc_session_take_prompt(session,&prompt.id,nullptr) == TIDYVNC_OK) {
      auto info = init<tidyvnc_prompt_info>(); EXPECT_EQ(tidyvnc_prompt_get(prompt.id,&info,nullptr),TIDYVNC_OK);
      uint8_t password[] = {'p','a','s','s','w','o','r','d'};
      EXPECT_EQ(tidyvnc_session_reply_credentials(session,info.id,info.generation,{nullptr,0},{password,sizeof(password)},nullptr),TIDYVNC_OK);
      for (auto byte : password) EXPECT_EQ(byte,0u);
      ++probe->prompts;
    }
    auto view = init<tidyvnc_view_update>();
    if (tidyvnc_session_take_view(session,&view,nullptr) == TIDYVNC_OK) {
      if (view.frame) {
        auto image = init<tidyvnc_image_info>();
        EXPECT_EQ(tidyvnc_image_get(view.frame,&image,nullptr),TIDYVNC_OK);
        // Initial allocation also publishes a cleared frame; retain the real
        // server update before asking the session to close.
        if (!probe->image && image.pixels.length && image.pixels.data[0] == 10) probe->image = view.frame;
        else tidyvnc_release(view.frame,nullptr);
      }
      if (view.cursor) tidyvnc_release(view.cursor,nullptr);
    }
    if (tidyvnc_session_poll_drained(session,nullptr) == TIDYVNC_OK) probe->sessionDrained = true;
  };
  ASSERT_EQ(watch.subscribe(session),TIDYVNC_OK); Peer peer(true); auto operation = connect(session,peer);
  ASSERT_TRUE(probe->wait([&] {
    return probe->prompts == 1 && probe->image && std::any_of(probe->events.begin(),probe->events.end(),[&](const tidyvnc_event& event) {
      return event.kind == TIDYVNC_EVENT_COMPLETION && event.operation == operation.operation && event.result == TIDYVNC_OPERATION_SUCCEEDED;
    });
  }));
  ASSERT_EQ(tidyvnc_session_close(session,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(probe->wait([&] { return probe->sessionDrained; }));
  ASSERT_EQ(tidyvnc_subscription_unsubscribe(watch.subscription.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_subscription_poll_drained(watch.subscription.id,nullptr) == TIDYVNC_OK; }));
  EXPECT_EQ(std::count_if(probe->events.begin(),probe->events.end(),[&](const tidyvnc_event& event) {
    return event.kind == TIDYVNC_EVENT_COMPLETION && event.operation == operation.operation;
  }),1);
  EXPECT_EQ(tidyvnc_release(session,nullptr),TIDYVNC_OK); client.session.id = 0;
  EXPECT_EQ(tidyvnc_runtime_shutdown(client.runtime.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_runtime_poll_drained(client.runtime.id,nullptr) == TIDYVNC_OK; }));
  EXPECT_EQ(tidyvnc_release(client.runtime.id,nullptr),TIDYVNC_OK); client.runtime.id = 0;
  auto image = init<tidyvnc_image_info>(); EXPECT_EQ(tidyvnc_image_get(probe->image,&image,nullptr),TIDYVNC_OK);
  EXPECT_EQ(image.pixels.length,16u); EXPECT_EQ(image.pixels.data[0],10u); EXPECT_TRUE(peer.verified); EXPECT_FALSE(peer.failed);
}

TEST(ViewerABI, FinalSubscriptionReleaseDoesNotWaitForRunningCallback)
{
  Client client; client.create(); Watch watch; watch.probe->blocked = true;
  ASSERT_EQ(watch.subscribe(client.session.id),TIDYVNC_OK);
  ASSERT_TRUE(watch.probe->wait([&] { return watch.probe->calls == 1; }));
  const auto old = watch.subscription.id;
  EXPECT_EQ(tidyvnc_release(old,nullptr),TIDYVNC_OK); watch.subscription.id = 0;
  EXPECT_EQ(tidyvnc_subscription_poll_drained(old,nullptr),TIDYVNC_INVALID_HANDLE);
  EXPECT_EQ(watch.probe->releases,0u); watch.probe->unblock();
  ASSERT_TRUE(watch.probe->wait([&] { return watch.probe->releases == 1; }));
  EXPECT_EQ(watch.probe->finished,1u);
}

TEST(ViewerABI, ThrowingForeignCallbackIsCancelledAndDispatcherRemainsUsable)
{
  Client client; client.create(); Watch throwing;
  throwing.probe->action = [](uint64_t,uint64_t) { throw std::runtime_error("foreign callback contract violation"); };
  ASSERT_EQ(throwing.subscribe(client.session.id),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_subscription_poll_drained(throwing.subscription.id,nullptr) == TIDYVNC_OK; }));
  EXPECT_EQ(throwing.probe->calls,1u); EXPECT_EQ(throwing.probe->releases,1u);
  Watch replacement; ASSERT_EQ(replacement.subscribe(client.session.id),TIDYVNC_OK);
  ASSERT_TRUE(replacement.probe->wait([&] { return replacement.probe->finished == 1; }));
}

TEST(ViewerABI, ClipboardCallbacksRetainTextAndEnforceRoutesDirectionsAndEcho)
{
  Client client; client.create(); Peer peer; auto operation = connect(client.session.id,peer);
  tidyvnc_event event{}; ASSERT_TRUE(completion(client.session.id,operation.operation,event));
  const auto id = client.session.id, generation = operation.generation;
  ASSERT_EQ(tidyvnc_session_focus(id,generation,1,nullptr),TIDYVNC_OK);
  ASSERT_EQ(tidyvnc_session_clipboard_policy(id,generation,0,1,nullptr),TIDYVNC_OK);
  auto sent = init<tidyvnc_operation>(); const std::string local = u8"café\r\n";
  const tidyvnc_bytes bytes{reinterpret_cast<const uint8_t*>(local.data()),local.size()};
  EXPECT_EQ(tidyvnc_session_clipboard_offer(id,generation,bytes,0,42,&sent,nullptr),TIDYVNC_DISABLED);
  EXPECT_EQ(sent.operation,0u);
  Watch watch; auto* probe = watch.probe.get();
  probe->action = [probe,id](uint64_t,uint64_t) {
    auto update = init<tidyvnc_clipboard_update>();
    if (tidyvnc_session_take_clipboard(id,&update,nullptr) == TIDYVNC_OK) {
      std::lock_guard<std::mutex> lock(probe->mutex);
      if (update.text) {
        if (probe->clipboard.text) tidyvnc_release(probe->clipboard.text,nullptr);
        probe->clipboard = update;
      }
    }
  };
  ASSERT_EQ(watch.subscribe(id),TIDYVNC_OK);
  peer.clipboardRequested = true;
  ASSERT_TRUE(probe->wait([&] { return probe->clipboard.text != 0; }));
  ASSERT_EQ(tidyvnc_subscription_unsubscribe(watch.subscription.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_subscription_poll_drained(watch.subscription.id,nullptr) == TIDYVNC_OK; }));
  const auto received = probe->clipboard;
  EXPECT_EQ(received.kind,TIDYVNC_CLIPBOARD_TEXT); EXPECT_EQ(received.result,TIDYVNC_OK);
  auto text = init<tidyvnc_clipboard_info>();
  ASSERT_EQ(tidyvnc_clipboard_get(received.text,&text,nullptr),TIDYVNC_OK);
  EXPECT_EQ(text.from_remote,1u);
  EXPECT_EQ(std::string(reinterpret_cast<const char*>(text.text.data),text.text.length),u8"café\n");
  EXPECT_EQ(tidyvnc_session_clipboard_check(id,&received.route,0,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_session_clipboard_check(id,&received.route,1,nullptr),TIDYVNC_DISABLED);
  ASSERT_EQ(tidyvnc_session_clipboard_policy(id,generation,1,0,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_session_clipboard_check(id,&received.route,0,nullptr),TIDYVNC_STALE);
  EXPECT_EQ(tidyvnc_session_clipboard_offer(id,generation,bytes,received.text,0,&sent,nullptr),TIDYVNC_ECHO);
  ASSERT_EQ(tidyvnc_session_clipboard_offer(id,generation,bytes,0,42,&sent,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(completion(id,sent.operation,event)); EXPECT_EQ(event.origin,42u);
  EXPECT_EQ(event.result,TIDYVNC_OPERATION_SUCCEEDED);
  ASSERT_TRUE(until([&] { return peer.contains({6,0,0,0,0,0,0,5,'c','a','f',0xe9,'\n'}); }));
  ASSERT_EQ(tidyvnc_session_focus(id,generation,0,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_session_clipboard_offer(id,generation,bytes,0,0,&sent,nullptr),TIDYVNC_UNFOCUSED);
  ASSERT_EQ(tidyvnc_session_focus(id,generation,1,nullptr),TIDYVNC_OK);
  ASSERT_EQ(tidyvnc_session_view_only(id,1,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_session_clipboard_offer(id,generation,bytes,0,0,&sent,nullptr),TIDYVNC_VIEW_ONLY);
  ASSERT_EQ(tidyvnc_session_view_only(id,0,nullptr),TIDYVNC_OK);
  const uint8_t invalid[] = {0xff};
  EXPECT_EQ(tidyvnc_session_clipboard_offer(id,generation,{invalid,1},0,0,&sent,nullptr),TIDYVNC_INVALID_ARGUMENT);
  ASSERT_EQ(tidyvnc_session_clipboard_clear(id,generation,&sent,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(completion(id,sent.operation,event));
  ASSERT_EQ(tidyvnc_session_close(id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_session_poll_drained(id,nullptr) == TIDYVNC_OK; }));
  ASSERT_EQ(tidyvnc_release(id,nullptr),TIDYVNC_OK); client.session.id = 0;
  ASSERT_EQ(tidyvnc_runtime_shutdown(client.runtime.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_runtime_poll_drained(client.runtime.id,nullptr) == TIDYVNC_OK; }));
  EXPECT_EQ(tidyvnc_clipboard_get(received.text,&text,nullptr),TIDYVNC_OK);
  EXPECT_EQ(std::string(reinterpret_cast<const char*>(text.text.data),text.text.length),u8"café\n");
}

TEST(ViewerABI, EndpointValidationSharesCoreSyntaxWithoutRuntime)
{
  const std::vector<std::string> inputs = {
    "", " \t\r\n", ":1", "::99", "host", "host:1", "host:100", "host::65535",
    "host: +005 ", "  Host \t:1\n", "[]:1", "2001::1", "[::1]", "[::1]:2",
    "[FE80::1%en0]::5901", "2001:db8::20:1", "/tmp/VNC socket", " ./socket:1 ",
    "host:", "host::0", "host::-1", "host::65536", "host::18446744073709551617",
    "[::1", "host]", "ho st", "[fe80::1%]", "[gggg::1]", "[::1] :1", "host%en0"
  };
  for (bool allowUnix : {false,true}) for (const auto& input : inputs) {
    auto error = init<tidyvnc_error>();
    const auto result = tidyvnc_endpoint_validate({reinterpret_cast<const uint8_t*>(input.data()),input.size()},allowUnix,&error);
    try {
      (void)viewer::Endpoint::parse(input,allowUnix);
      EXPECT_EQ(result,TIDYVNC_OK); EXPECT_EQ(error.code,TIDYVNC_OK);
    } catch (const viewer::EndpointError& expected) {
      EXPECT_EQ(result,TIDYVNC_INVALID_ARGUMENT);
      EXPECT_EQ(error.domain,TIDYVNC_DOMAIN_ENDPOINT);
      // Explicit core-to-ABI reason mapping, independent of enum ordinal values.
      uint32_t detail = 0;
      switch (expected.code) {
      case viewer::EndpointErrorCode::TooLong: detail=TIDYVNC_ENDPOINT_TOO_LONG; break;
      case viewer::EndpointErrorCode::InvalidHost: detail=TIDYVNC_ENDPOINT_INVALID_HOST; break;
      case viewer::EndpointErrorCode::UnmatchedBracket: detail=TIDYVNC_ENDPOINT_UNMATCHED_BRACKET; break;
      case viewer::EndpointErrorCode::InvalidPort: detail=TIDYVNC_ENDPOINT_INVALID_PORT; break;
      case viewer::EndpointErrorCode::InvalidPath: detail=TIDYVNC_ENDPOINT_INVALID_PATH; break;
      case viewer::EndpointErrorCode::InvalidRoute: detail=TIDYVNC_ENDPOINT_INVALID_ROUTE; break;
      case viewer::EndpointErrorCode::UnsupportedTransport: detail=TIDYVNC_ENDPOINT_UNSUPPORTED_TRANSPORT; break;
      }
      EXPECT_EQ(error.detail,detail); EXPECT_STREQ(error.message,"Invalid argument");
    }
  }
}

TEST(ViewerABI, EndpointPreflightAndConnectRejectBeforeSessionMutation)
{
  Client client; client.create();
  auto options = init<tidyvnc_connect_options>(); tidyvnc_connect_options_init(&options,nullptr);
  auto operation = init<tidyvnc_operation>(); operation.operation=123; operation.generation=456;
  const auto saved = operation;
  for (const std::string& input : {std::string("host::99999"),std::string("[::1"),std::string(4097,'x'),std::string("bad\0host",8)}) {
    auto preflight = init<tidyvnc_error>(), connected = init<tidyvnc_error>();
    options.endpoint={reinterpret_cast<const uint8_t*>(input.data()),input.size()};
    const auto status=tidyvnc_endpoint_validate(options.endpoint,1,&preflight);
    EXPECT_EQ(status,TIDYVNC_INVALID_ARGUMENT);
    EXPECT_EQ(tidyvnc_session_connect(client.session.id,&options,&operation,&connected),status);
    EXPECT_EQ(preflight.domain,connected.domain); EXPECT_EQ(preflight.detail,connected.detail);
    EXPECT_EQ(std::memcmp(&operation,&saved,sizeof(saved)),0);
    auto snapshot=init<tidyvnc_snapshot>(); ASSERT_EQ(tidyvnc_session_snapshot(client.session.id,&snapshot,nullptr),TIDYVNC_OK);
    EXPECT_EQ(snapshot.state,TIDYVNC_STATE_IDLE); EXPECT_EQ(snapshot.generation,1u);
  }
}

TEST(ViewerABI, EndpointValidationIsConcurrentAndBounded)
{
  std::vector<std::thread> workers;
  for (unsigned i=0;i<4;++i) workers.emplace_back([i] {
    const auto input="[fe80::1%en"+std::to_string(i)+"]::5901";
    for (unsigned n=0;n<1000;++n) {
      auto error=init<tidyvnc_error>();
      EXPECT_EQ(tidyvnc_endpoint_validate({reinterpret_cast<const uint8_t*>(input.data()),input.size()},1,&error),TIDYVNC_OK);
    }
  });
  for (auto& worker : workers) worker.join();
  std::string input(4096,'x'); auto error=init<tidyvnc_error>();
  EXPECT_EQ(tidyvnc_endpoint_validate({reinterpret_cast<const uint8_t*>(input.data()),input.size()},1,&error),TIDYVNC_OK);
  input.push_back('x');
  EXPECT_EQ(tidyvnc_endpoint_validate({reinterpret_cast<const uint8_t*>(input.data()),input.size()},1,&error),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(error.detail,TIDYVNC_ENDPOINT_TOO_LONG);
}

TEST(ViewerABI, EncodingSchemaSnapshotsAndStructuredValidation)
{
  auto schema = init<tidyvnc_encoding_schema>(); unsigned count = 0;
  while (tidyvnc_encoding_schema_at(count,&schema,nullptr) == TIDYVNC_OK) {
    EXPECT_EQ(schema.id,count); EXPECT_EQ(schema.persistent,1u); EXPECT_EQ(schema.live,1u); ++count;
  }
  EXPECT_EQ(count,8u);
  auto unchanged = schema;
  EXPECT_EQ(tidyvnc_encoding_schema_at(UINT32_MAX,&schema,nullptr),TIDYVNC_NO_CHANGE);
  EXPECT_EQ(std::memcmp(&schema,&unchanged,sizeof(schema)),0);
  ASSERT_EQ(tidyvnc_encoding_schema_at(TIDYVNC_ENCODING_FULL_COLOR,&schema,nullptr),TIDYVNC_OK);
  EXPECT_STREQ(schema.alias,"FullColour"); EXPECT_STREQ(schema.default_value,"on");
  auto choice = init<tidyvnc_encoding_choice>(); unsigned choices = 0, available = 0;
  while (tidyvnc_encoding_choice_at(choices,&choice,nullptr) == TIDYVNC_OK) { ++choices; available += choice.available; }
  EXPECT_EQ(choices,6u); EXPECT_GT(available,0u);
  Handle original, patched; auto value = init<tidyvnc_encoding_value>();
  ASSERT_EQ(tidyvnc_encoding_create(0,nullptr,0,TIDYVNC_SOURCE_COMPILED,&original.id,nullptr),TIDYVNC_OK);
  char name[] = "fullcolour", text[] = "off";
  tidyvnc_encoding_assignment patch{{reinterpret_cast<uint8_t*>(name),std::strlen(name)}, {reinterpret_cast<uint8_t*>(text),std::strlen(text)}};
  ASSERT_EQ(tidyvnc_encoding_create(original.id,&patch,1,TIDYVNC_SOURCE_APP_DEFAULTS,&patched.id,nullptr),TIDYVNC_OK);
  std::memset(name,'x',sizeof(name)); std::memset(text,'x',sizeof(text));
  ASSERT_EQ(tidyvnc_encoding_get(patched.id,TIDYVNC_ENCODING_FULL_COLOR,&value,nullptr),TIDYVNC_OK);
  EXPECT_STREQ(value.value,"off"); EXPECT_EQ(value.source,TIDYVNC_SOURCE_APP_DEFAULTS);
  ASSERT_EQ(tidyvnc_encoding_get(original.id,TIDYVNC_ENCODING_FULL_COLOR,&value,nullptr),TIDYVNC_OK);
  EXPECT_STREQ(value.value,"on"); EXPECT_EQ(value.source,TIDYVNC_SOURCE_COMPILED);
  auto error = init<tidyvnc_error>(); uint64_t out = UINT64_MAX;
  patch = {{reinterpret_cast<const uint8_t*>("QualityLevel"),12}, {reinterpret_cast<const uint8_t*>("10"),2}};
  EXPECT_EQ(tidyvnc_encoding_create(patched.id,&patch,1,TIDYVNC_SOURCE_SESSION,&out,&error),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(out,UINT64_MAX); EXPECT_EQ(error.domain,TIDYVNC_DOMAIN_ENCODING);
  EXPECT_EQ(error.detail & 0xffff,TIDYVNC_ENCODING_INVALID_VALUE); EXPECT_EQ(error.detail >> 16,TIDYVNC_ENCODING_QUALITY+1u);
  const auto previous = value;
  EXPECT_EQ(tidyvnc_encoding_get(patched.id,UINT32_MAX,&value,&error),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(std::memcmp(&previous,&value,sizeof(value)),0);
  EXPECT_EQ(error.detail,TIDYVNC_ENCODING_UNKNOWN_OPTION);
  Client client;
  EXPECT_EQ(tidyvnc_encoding_get(client.runtime.id,0,&value,nullptr),TIDYVNC_WRONG_HANDLE_TYPE);
  ASSERT_EQ(tidyvnc_release(original.id,nullptr),TIDYVNC_OK); original.id = 0;
  ASSERT_EQ(tidyvnc_encoding_get(patched.id,TIDYVNC_ENCODING_FULL_COLOR,&value,nullptr),TIDYVNC_OK);
  EXPECT_STREQ(value.value,"off");
}
TEST(ViewerABI, EncodingInitialWireLiveApplyAndReconnectPreserveIndependentSnapshots)
{
  Client client; Handle initial, changed, retained;
  const tidyvnc_encoding_assignment first[] = {
    {{reinterpret_cast<const uint8_t*>("AutoSelect"),10},{reinterpret_cast<const uint8_t*>("off"),3}},
    {{reinterpret_cast<const uint8_t*>("QualityLevel"),12},{reinterpret_cast<const uint8_t*>("3"),1}}
  };
  ASSERT_EQ(tidyvnc_encoding_create(0,first,2,TIDYVNC_SOURCE_APP_DEFAULTS,&initial.id,nullptr),TIDYVNC_OK);
  ASSERT_EQ(tidyvnc_session_create_with_encoding(client.runtime.id,&client.options,initial.id,&client.session.id,nullptr),TIDYVNC_OK);
  auto operation = init<tidyvnc_operation>();
  EXPECT_EQ(tidyvnc_session_apply_encoding(client.session.id,1,initial.id,&operation,nullptr),TIDYVNC_NOT_CONNECTED);
  Peer peer; auto connected = connect(client.session.id,peer); tidyvnc_event event{};
  ASSERT_TRUE(completion(client.session.id,connected.operation,event)); ASSERT_EQ(event.result,TIDYVNC_OPERATION_SUCCEEDED);
  ASSERT_TRUE(until([&] { return peer.contains({255,255,255,227}); })); // Quality level 3.
  const tidyvnc_encoding_assignment patch{{reinterpret_cast<const uint8_t*>("QualityLevel"),12},{reinterpret_cast<const uint8_t*>("5"),1}};
  ASSERT_EQ(tidyvnc_encoding_create(initial.id,&patch,1,TIDYVNC_SOURCE_SESSION,&changed.id,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_session_apply_encoding(client.session.id,connected.generation+1,changed.id,&operation,nullptr),TIDYVNC_STALE);
  ASSERT_EQ(tidyvnc_session_apply_encoding(client.session.id,connected.generation,changed.id,&operation,nullptr),TIDYVNC_OK);
  ASSERT_EQ(tidyvnc_release(changed.id,nullptr),TIDYVNC_OK); changed.id = 0; // Command owns its copy.
  ASSERT_TRUE(completion(client.session.id,operation.operation,event)); EXPECT_EQ(event.result,TIDYVNC_OPERATION_SUCCEEDED);
  peer.updateRequested = true;
  ASSERT_TRUE(until([&] { return peer.contains({255,255,255,229}); })); // Quality level 5.
  ASSERT_EQ(tidyvnc_session_encoding(client.session.id,&retained.id,nullptr),TIDYVNC_OK);
  auto value = init<tidyvnc_encoding_value>();
  ASSERT_EQ(tidyvnc_encoding_get(initial.id,TIDYVNC_ENCODING_QUALITY,&value,nullptr),TIDYVNC_OK);
  EXPECT_STREQ(value.value,"3");
  ASSERT_EQ(tidyvnc_session_disconnect(client.session.id,connected.generation,&operation,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(completion(client.session.id,operation.operation,event));
  Peer next; auto reconnected = connect(client.session.id,next);
  ASSERT_TRUE(completion(client.session.id,reconnected.operation,event));
  ASSERT_TRUE(until([&] { return next.contains({255,255,255,229}); }));
  EXPECT_EQ(tidyvnc_session_apply_encoding(client.session.id,connected.generation,initial.id,&operation,nullptr),TIDYVNC_STALE);
  ASSERT_EQ(tidyvnc_runtime_shutdown(client.runtime.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_runtime_poll_drained(client.runtime.id,nullptr) == TIDYVNC_OK; }));
  ASSERT_EQ(tidyvnc_encoding_get(retained.id,TIDYVNC_ENCODING_QUALITY,&value,nullptr),TIDYVNC_OK);
  EXPECT_STREQ(value.value,"5"); EXPECT_EQ(value.source,TIDYVNC_SOURCE_SESSION);
  EXPECT_FALSE(peer.failed); EXPECT_FALSE(next.failed);
}

TEST(ViewerABI, ScalingParserMatchesCoreAndCopiesCanonicalValues) {
  for (const auto& input : std::vector<std::string>{"none", "100%", " Auto ", "fixedratio", "FitWidth", "FitHeight",
      "1920X1080", "137.50%", "125.25%x80%", "0.01", "10000", "65535x1", "100%x100%"}) {
    const auto expected = ScalingSettings::parse(input); auto result = init<tidyvnc_scaling>();
    ASSERT_EQ(tidyvnc_scaling_parse({reinterpret_cast<const uint8_t*>(input.data()),input.size()},&result,nullptr),TIDYVNC_OK);
    EXPECT_EQ(result.mode,static_cast<uint32_t>(expected.mode)); EXPECT_EQ(result.x,expected.x); EXPECT_EQ(result.y,expected.y);
    EXPECT_EQ(result.fits,expected.fits()); EXPECT_EQ(result.canonical,expected.serialize());
  }
  for (const auto& input : std::vector<std::string>{"", "0", "-1", ".1", "1.", "10000.01", "1.001", "65536x1",
      "1x0", "125%x80", "125x80%", "NaN", "secret-invalid-value", std::string(65,'1')}) {
    auto result = init<tidyvnc_scaling>(); result.x = 777; auto error = init<tidyvnc_error>();
    EXPECT_EQ(tidyvnc_scaling_parse({reinterpret_cast<const uint8_t*>(input.data()),input.size()},&result,&error),TIDYVNC_INVALID_ARGUMENT);
    EXPECT_EQ(result.x,777U); EXPECT_STREQ(error.message,"Invalid argument");
  }
}
TEST(ViewerABI, ScalingParserIsConcurrentAndStateless) {
  std::atomic<bool> valid{true}; std::vector<std::thread> threads;
  for (int i=0;i<4;++i) threads.emplace_back([&] {
    for (int n=0;n<1000;++n) {
      auto value = init<tidyvnc_scaling>();
      if (tidyvnc_scaling_parse({reinterpret_cast<const uint8_t*>("125%x80%"),8},&value,nullptr) != TIDYVNC_OK ||
          value.x != 12500 || value.y != 8000 || value.mode != TIDYVNC_SCALING_INDEPENDENT) valid = false;
    }
  });
  for (auto& thread : threads) thread.join(); EXPECT_TRUE(valid);
}

TEST(ViewerABI, TileRendererUsesRetainedFramesCachesAndSerializesCalls) {
  Client client; client.create(); Peer peer; auto operation=connect(client.session.id,peer);
  tidyvnc_event event{}; ASSERT_TRUE(completion(client.session.id,operation.operation,event));
  Handle image,renderer; auto view=init<tidyvnc_view_update>();
  ASSERT_TRUE(until([&] {
    if (tidyvnc_session_take_view(client.session.id,&view,nullptr) != TIDYVNC_OK) return false;
    if (view.cursor) tidyvnc_release(view.cursor,nullptr);
    if (!view.frame) return false;
    auto info=init<tidyvnc_image_info>(); tidyvnc_image_get(view.frame,&info,nullptr);
    if (info.pixels.data[0] != 10) { tidyvnc_release(view.frame,nullptr); return false; }
    image.id=view.frame; return true;
  }));
  ASSERT_EQ(tidyvnc_renderer_create(1024,&renderer.id,nullptr),TIDYVNC_OK);
  auto options=init<tidyvnc_tile_options>(); options.width=options.tile_width=4; options.height=options.tile_height=4;
  options.quality=TIDYVNC_FILTER_AREA; options.damage_width=options.damage_height=2;
  std::array<uint8_t,64> pixels{}; auto result=init<tidyvnc_tile_result>();
  ASSERT_EQ(tidyvnc_renderer_render(renderer.id,image.id,&options,{pixels.data(),pixels.size()},&result,nullptr),TIDYVNC_OK);
  EXPECT_EQ(result.cache_hit,0U); EXPECT_EQ(result.cache_bytes,64U);
  for (size_t i=0;i<pixels.size();i+=4) {
    EXPECT_EQ(pixels[i],10); EXPECT_EQ(pixels[i+1],20); EXPECT_EQ(pixels[i+2],30); EXPECT_EQ(pixels[i+3],255);
  }
  std::atomic<bool> correct{true}; std::vector<std::thread> threads;
  for (int t=0;t<4;++t) threads.emplace_back([&] {
    for (int i=0;i<100;++i) {
      auto output=init<tidyvnc_tile_result>(); std::array<uint8_t,64> tile{};
      if (tidyvnc_renderer_render(renderer.id,image.id,&options,{tile.data(),tile.size()},&output,nullptr) != TIDYVNC_OK ||
          !output.cache_hit || tile != pixels) correct=false;
    }
  });
  for (auto& thread:threads) thread.join(); EXPECT_TRUE(correct);
  auto before=pixels; const auto resultBefore=result;
  options.damage_width=3;
  EXPECT_EQ(tidyvnc_renderer_render(renderer.id,image.id,&options,{pixels.data(),pixels.size()},&result,nullptr),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(pixels,before); EXPECT_EQ(std::memcmp(&result,&resultBefore,sizeof(result)),0); options.damage_width=2;
  EXPECT_EQ(tidyvnc_renderer_render(client.session.id,image.id,&options,{pixels.data(),pixels.size()},&result,nullptr),TIDYVNC_WRONG_HANDLE_TYPE);
  ASSERT_EQ(tidyvnc_session_close(client.session.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] {return tidyvnc_session_poll_drained(client.session.id,nullptr)==TIDYVNC_OK;}));
  ASSERT_EQ(tidyvnc_renderer_clear(renderer.id,nullptr),TIDYVNC_OK);
  ASSERT_EQ(tidyvnc_renderer_render(renderer.id,image.id,&options,{pixels.data(),pixels.size()},&result,nullptr),TIDYVNC_OK);
  EXPECT_EQ(result.cache_hit,0U); EXPECT_EQ(pixels,before); // No session needed once the image is retained.
}

TEST(ViewerABI, DamageGeometryUsesSharedHaloRoundingAndPlacement) {
  const std::string scaling="125%x80%";
  auto options=init<tidyvnc_geometry_options>(); options.remote_width=1920; options.remote_height=1080;
  options.viewport_width=1000; options.viewport_height=800; options.backing_scale=1.25;
  options.units=1; options.pan_x=7.5; options.pan_y=3.25;
  options.scaling={reinterpret_cast<const uint8_t*>(scaling.data()),scaling.size()};
  DisplayMetrics metrics; metrics.pixelsPerUnitX=metrics.pixelsPerUnitY=1.25;
  DesktopTransform transform(1920,1080,1000,800,metrics,ScalingSettings::parse(scaling),ScalingSettings::Device);
  transform.placeOnCanvas(1250,1000,{0,0,1250,1000},ScalingSettings::Device,7.5,3.25);
  for (auto quality : {ScalingSettings::Nearest,ScalingSettings::Bilinear,ScalingSettings::Area}) {
    for (const auto& rect : {core::Rect(100,50,105,59),core::Rect(0,0,1,1),core::Rect(1919,1079,1920,1080),core::Rect()}) {
      auto damage=init<tidyvnc_damage>(); damage.x=rect.tl.x; damage.y=rect.tl.y;
      damage.width=rect.width(); damage.height=rect.height(); damage.quality=quality;
      auto output=init<tidyvnc_rectangle>();
      ASSERT_EQ(tidyvnc_desktop_damage(&options,&damage,&output,nullptr),TIDYVNC_OK);
      const auto expected=transform.logicalDamage(rect,quality);
      EXPECT_EQ(output.x,expected.tl.x); EXPECT_EQ(output.y,expected.tl.y);
      EXPECT_EQ(output.width,expected.width()); EXPECT_EQ(output.height,expected.height());
    }
  }
}

extern "C" void abi_test_fail_after(unsigned);
TEST(ViewerABI, CursorSamplerAlphaTilesConcurrencyAndRetainedOwnership) {
  Client client; client.create(); Peer peer; auto operation=connect(client.session.id,peer);
  tidyvnc_event event{}; ASSERT_TRUE(completion(client.session.id,operation.operation,event));
  peer.cursorRequested=true;
  Handle image,frame;
  ASSERT_TRUE(until([&] {
    auto view=init<tidyvnc_view_update>();
    if (tidyvnc_session_take_view(client.session.id,&view,nullptr) != TIDYVNC_OK) return false;
    if (view.frame) { if (!frame.id) frame.id=view.frame; else tidyvnc_release(view.frame,nullptr); }
    if (view.cursor) image.id=view.cursor;
    return image.id != 0;
  }));
  auto source=init<tidyvnc_image_info>(); ASSERT_EQ(tidyvnc_image_get(image.id,&source,nullptr),TIDYVNC_OK);
  ASSERT_EQ(source.width,2u); ASSERT_EQ(source.height,1u);
  auto options=init<tidyvnc_cursor_options>(); options.scale_x=2; options.scale_y=1; options.quality=TIDYVNC_FILTER_BILINEAR;
  auto geometry=init<tidyvnc_cursor_geometry>(); Handle sampler;
  ASSERT_EQ(tidyvnc_cursor_renderer_create(image.id,&options,&sampler.id,&geometry,nullptr),TIDYVNC_OK);
  EXPECT_EQ(geometry.width,4u); EXPECT_EQ(geometry.height,1u); EXPECT_EQ(geometry.hotspot_x,2u); EXPECT_EQ(geometry.source_bytes,8u);
  EXPECT_EQ(geometry.blank,0u); EXPECT_EQ(geometry.reserved,0u);
  auto tile=init<tidyvnc_cursor_tile>(); tile.width=4; tile.height=1;
  std::array<uint8_t,16> pixels{}, expected{0,0,0,0, 0,255,0,64, 0,255,0,191, 0,255,0,255};
  ASSERT_EQ(tidyvnc_cursor_renderer_render(sampler.id,&tile,{pixels.data(),pixels.size()},nullptr),TIDYVNC_OK);
  EXPECT_EQ(pixels,expected);
  for (auto quality : {ScalingSettings::Nearest,ScalingSettings::Bilinear,ScalingSettings::Area}) {
    for (auto scale : {0.25,1.,1.25,2.,65535.}) {
      options.scale_x=scale; options.scale_y=1.5; options.quality=quality;
      Handle current; auto shape=init<tidyvnc_cursor_geometry>();
      ASSERT_EQ(tidyvnc_cursor_renderer_create(image.id,&options,&current.id,&shape,nullptr),TIDYVNC_OK);
      CursorRenderer reference(source.pixels.data,2,1,{1,0},scale,1.5,quality);
      EXPECT_EQ(shape.width,uint32_t(reference.width())); EXPECT_EQ(shape.height,uint32_t(reference.height()));
      EXPECT_EQ(shape.hotspot_x,uint32_t(reference.hotspot().x)); EXPECT_EQ(shape.hotspot_y,uint32_t(reference.hotspot().y));
      auto region=init<tidyvnc_cursor_tile>(); region.width=std::min(256u,shape.width); region.height=shape.height;
      region.x=shape.width-region.width;
      std::vector<uint8_t> actual(region.width*region.height*4), golden(actual.size());
      reference.render(golden.data(),region.width*4,{int(region.x),0,int(shape.width),int(shape.height)});
      ASSERT_EQ(tidyvnc_cursor_renderer_render(current.id,&region,{actual.data(),actual.size()},nullptr),TIDYVNC_OK);
      EXPECT_EQ(actual,golden); EXPECT_EQ(shape.source_bytes,8u);
    }
  }
  auto invalid=tile; invalid.x=UINT32_MAX; auto unchanged=pixels;
  EXPECT_EQ(tidyvnc_cursor_renderer_render(sampler.id,&invalid,{pixels.data(),pixels.size()},nullptr),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(pixels,unchanged);
  uint64_t untouched=777; auto before=geometry;
  options.scale_x=options.scale_y=1;
  EXPECT_EQ(tidyvnc_cursor_renderer_create(frame.id,&options,&untouched,&geometry,nullptr),TIDYVNC_UNSUPPORTED);
  EXPECT_EQ(untouched,777u); EXPECT_EQ(std::memcmp(&before,&geometry,sizeof(before)),0);
  EXPECT_EQ(tidyvnc_cursor_renderer_render(image.id,&tile,{pixels.data(),pixels.size()},nullptr),TIDYVNC_WRONG_HANDLE_TYPE);
  unsigned allocationFailures=0, allocationSuccesses=0;
  for (unsigned allocation=1;allocation<=8;++allocation) {
    auto shape=init<tidyvnc_cursor_geometry>(); const auto original=shape; uint64_t handle=777;
    abi_test_fail_after(allocation);
    const auto status=tidyvnc_cursor_renderer_create(image.id,&options,&handle,&shape,nullptr);
    abi_test_fail_after(0);
    if (status == TIDYVNC_OK) { ++allocationSuccesses; tidyvnc_release(handle,nullptr); }
    else {
      ++allocationFailures; EXPECT_EQ(status,TIDYVNC_OUT_OF_MEMORY); EXPECT_EQ(handle,777u);
      EXPECT_EQ(std::memcmp(&shape,&original,sizeof(shape)),0);
    }
  }
  EXPECT_GE(allocationFailures,3u); EXPECT_GT(allocationSuccesses,0u);
  tidyvnc_release(image.id,nullptr); image.id=0; tidyvnc_release(frame.id,nullptr); frame.id=0;
  ASSERT_EQ(tidyvnc_runtime_shutdown(client.runtime.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_runtime_poll_drained(client.runtime.id,nullptr) == TIDYVNC_OK; }));
  std::atomic<unsigned> failures{0}; std::vector<std::thread> readers;
  for (int thread=0;thread<4;++thread) readers.emplace_back([&] {
    for (int i=0;i<40;++i) {
      std::array<uint8_t,16> result{};
      if (tidyvnc_cursor_renderer_render(sampler.id,&tile,{result.data(),result.size()},nullptr) != TIDYVNC_OK || result != expected) ++failures;
    }
  });
  for (auto& reader : readers) reader.join(); EXPECT_EQ(failures,0u);
  const auto stale=sampler.id; tidyvnc_release(sampler.id,nullptr); sampler.id=0;
  EXPECT_EQ(tidyvnc_cursor_renderer_render(stale,&tile,{pixels.data(),pixels.size()},nullptr),TIDYVNC_INVALID_HANDLE);
}

TEST(ViewerABI, InputPolicyValidationIsAtomicAndLegacyViewOnlyPreservesEmulation)
{
  Client client; client.create(); Peer peer; const auto operation = connect(client.session.id,peer);
  tidyvnc_event event{}; ASSERT_TRUE(completion(client.session.id,operation.operation,event));
  const auto id = client.session.id, generation = operation.generation;
  EXPECT_EQ(tidyvnc_session_input_policy(id,1,2,nullptr),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(tidyvnc_session_key(id,generation,1,'A',0,1,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_session_input_policy(id,1,1,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_session_key(id,generation,2,'B',0,1,nullptr),TIDYVNC_VIEW_ONLY);
  EXPECT_EQ(tidyvnc_session_view_only(id,0,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_session_pointer(id,generation,0,0,5,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return peer.contains({5,2,0,0,0,0}); }));
  EXPECT_EQ(tidyvnc_session_input_policy(id,0,0,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return peer.contains({5,0,0,0,0,0}); }));
  EXPECT_EQ(tidyvnc_session_pointer(id,generation,1,1,5,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return peer.contains({5,5,0,1,0,1}); }));
}

TEST(ViewerABI, ShortcutBoundedStateFailureAtomicityAndAllocationFreeSteps)
{
  Handle handle; ASSERT_EQ(tidyvnc_shortcut_create(1,&handle.id,nullptr),TIDYVNC_OK);
  uint32_t action = 99;
  ASSERT_EQ(tidyvnc_shortcut_key(handle.id,-1,0xffe3,1,&action,nullptr),TIDYVNC_OK);
  for (int i = 0; i < 1023; ++i) {
    ASSERT_EQ(tidyvnc_shortcut_key(handle.id,i,0x61,1,&action,nullptr),TIDYVNC_OK);
    ASSERT_EQ(action,TIDYVNC_SHORTCUT_ACTION);
  }
  action = 99;
  EXPECT_EQ(tidyvnc_shortcut_key(handle.id,1024,0x62,1,&action,nullptr),TIDYVNC_RESOURCE_LIMIT);
  EXPECT_EQ(action,99u);
  ASSERT_EQ(tidyvnc_shortcut_key(handle.id,0,0,0,&action,nullptr),TIDYVNC_OK);
  EXPECT_EQ(action,TIDYVNC_SHORTCUT_ACTION);
  ASSERT_EQ(tidyvnc_shortcut_key(handle.id,1024,0x62,1,&action,nullptr),TIDYVNC_OK);
  EXPECT_EQ(action,TIDYVNC_SHORTCUT_ACTION);
  abi_test_fail_after(1);
  const auto reset = tidyvnc_shortcut_reset(handle.id,nullptr);
  const auto modifiers = tidyvnc_shortcut_modifiers(handle.id,8,nullptr);
  const auto press = tidyvnc_shortcut_key(handle.id,0,0xffeb,1,&action,nullptr);
  const auto release = tidyvnc_shortcut_key(handle.id,0,0,0,&action,nullptr);
  abi_test_fail_after(0);
  EXPECT_EQ(reset,TIDYVNC_OK); EXPECT_EQ(modifiers,TIDYVNC_OK);
  EXPECT_EQ(press,TIDYVNC_OK); EXPECT_EQ(release,TIDYVNC_OK); EXPECT_EQ(action,TIDYVNC_SHORTCUT_UNARM);
}
TEST(ViewerABI, ShortcutCreateFailureRecoveryAndSerializedConcurrentOwners)
{
  unsigned failures = 0, successes = 0;
  for (unsigned position = 1; position <= 6; ++position) {
    tidyvnc_handle id = 777;
    abi_test_fail_after(position);
    const auto status = tidyvnc_shortcut_create(5,&id,nullptr);
    abi_test_fail_after(0);
    if (status == TIDYVNC_OK) { ++successes; tidyvnc_release(id,nullptr); }
    else { ++failures; EXPECT_EQ(status,TIDYVNC_OUT_OF_MEMORY); EXPECT_EQ(id,777u); }
  }
  EXPECT_GE(failures,2u); EXPECT_GT(successes,0u);
  Handle shared; ASSERT_EQ(tidyvnc_shortcut_create(5,&shared.id,nullptr),TIDYVNC_OK);
  std::atomic<unsigned> errors{0}; std::vector<std::thread> threads;
  for (int worker = 0; worker < 4; ++worker) {
    ASSERT_EQ(tidyvnc_retain(shared.id,nullptr),TIDYVNC_OK);
    threads.emplace_back([&,worker] {
      for (unsigned i = 0; i < 200; ++i) {
        uint32_t action = 99;
        if (tidyvnc_shortcut_modifiers(shared.id,i%16,nullptr) != TIDYVNC_OK) ++errors;
        if (tidyvnc_shortcut_key(shared.id,worker,0xffe3,1,&action,nullptr) != TIDYVNC_OK || action > 3) ++errors;
        if (tidyvnc_shortcut_key(shared.id,worker,0,0,&action,nullptr) != TIDYVNC_OK || action > 3) ++errors;
        if (tidyvnc_shortcut_reset(shared.id,nullptr) != TIDYVNC_OK) ++errors;
      }
      if (tidyvnc_release(shared.id,nullptr) != TIDYVNC_OK) ++errors;
    });
  }
  for (auto& thread : threads) thread.join();
  EXPECT_EQ(errors.load(),0u);
}

TEST(ViewerABI, ExplicitInputReleasePreservesFocusAndGuardsGeneration)
{
  Client client; client.create(); Peer peer; const auto operation = connect(client.session.id,peer);
  tidyvnc_event event{}; ASSERT_TRUE(completion(client.session.id,operation.operation,event));
  const auto id = client.session.id, generation = operation.generation;
  ASSERT_EQ(tidyvnc_session_key(id,generation,1,'A',0,1,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return peer.contains({4,1,0,0,0,0,0,'A'}); }));
  EXPECT_EQ(tidyvnc_session_release_input(id,generation+1,nullptr),TIDYVNC_STALE);
  EXPECT_EQ(tidyvnc_session_release_input(id,generation,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return peer.contains({4,0,0,0,0,0,0,'A'}); }));
  EXPECT_EQ(tidyvnc_session_key(id,generation,2,'B',0,1,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return peer.contains({4,1,0,0,0,0,0,'B'}); }));
  EXPECT_EQ(tidyvnc_session_view_only(id,1,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_session_release_input(id,generation,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_session_key(id,generation,3,'C',0,1,nullptr),TIDYVNC_VIEW_ONLY);
}

TEST(ViewerABI, CanonicalEndpointIdentityIsOwnedBoundedAndConcurrent)
{
  auto span = [](const std::string& text) { return tidyvnc_bytes{reinterpret_cast<const uint8_t*>(text.data()), text.size()}; };
  auto text = [](tidyvnc_bytes bytes) { return std::string(reinterpret_cast<const char*>(bytes.data),bytes.length); };
  auto value = init<tidyvnc_endpoint_info>(); Handle identity;
  std::string endpoint = "[FE80:0:0:0:0:0:0:1%En0]:1", route = "ssh:lab";
  ASSERT_EQ(tidyvnc_endpoint_create(span(endpoint),span(route),1,&identity.id,nullptr),TIDYVNC_OK);
  ASSERT_EQ(tidyvnc_endpoint_get(identity.id,&value,nullptr),TIDYVNC_OK);
  EXPECT_EQ(value.transport,TIDYVNC_ENDPOINT_TCP); EXPECT_EQ(value.port,5901u);
  EXPECT_EQ(text(value.host),"fe80::1"); EXPECT_EQ(text(value.scope),"En0"); EXPECT_EQ(text(value.path),""); EXPECT_EQ(text(value.route),"ssh:lab");
  endpoint.assign(4096,'x'); route.assign(4096,'r');
  EXPECT_EQ(text(value.host),"fe80::1"); EXPECT_EQ(text(value.route),"ssh:lab");
  ASSERT_EQ(tidyvnc_retain(identity.id,nullptr),TIDYVNC_OK);
  Handle retained(identity.id); ASSERT_EQ(tidyvnc_release(identity.id,nullptr),TIDYVNC_OK); identity.id=0;
  ASSERT_EQ(tidyvnc_endpoint_get(retained.id,&value,nullptr),TIDYVNC_OK); EXPECT_EQ(text(value.host),"fe80::1");
  Handle large;
  ASSERT_EQ(tidyvnc_endpoint_create(span(endpoint),span(route),1,&large.id,nullptr),TIDYVNC_OK);
  ASSERT_EQ(tidyvnc_endpoint_get(large.id,&value,nullptr),TIDYVNC_OK);
  EXPECT_EQ(value.host.length,4096u); EXPECT_EQ(value.route.length,4096u);
  route += "r"; uint64_t unchanged=999;
  EXPECT_EQ(tidyvnc_endpoint_create(span(endpoint),span(route),1,&unchanged,nullptr),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(unchanged,999u);
  endpoint = " ./Desktop socket "; route = ""; Handle local;
  ASSERT_EQ(tidyvnc_endpoint_create(span(endpoint),span(route),1,&local.id,nullptr),TIDYVNC_OK);
  ASSERT_EQ(tidyvnc_endpoint_get(local.id,&value,nullptr),TIDYVNC_OK);
  EXPECT_EQ(value.transport,TIDYVNC_ENDPOINT_UNIX); EXPECT_EQ(value.port,0u);
  EXPECT_EQ(text(value.path),endpoint); EXPECT_EQ(text(value.host),""); EXPECT_EQ(text(value.scope),""); EXPECT_EQ(text(value.route),"");
  std::atomic<bool> valid{true}; std::vector<std::thread> readers;
  for (unsigned i=0;i<4;++i) readers.emplace_back([&] {
    for (unsigned j=0;j<100;++j) {
      auto out = init<tidyvnc_endpoint_info>();
      if (tidyvnc_endpoint_get(retained.id,&out,nullptr) != TIDYVNC_OK ||
          text(out.host) != "fe80::1" || text(out.route) != "ssh:lab" || out.port != 5901)
        valid = false;
    }
  });
  for (auto& reader : readers) reader.join(); EXPECT_TRUE(valid);
  const auto before=value; const auto released=local.id;
  ASSERT_EQ(tidyvnc_release(local.id,nullptr),TIDYVNC_OK); local.id=0;
  EXPECT_EQ(tidyvnc_endpoint_get(released,&value,nullptr),TIDYVNC_INVALID_HANDLE);
  EXPECT_EQ(std::memcmp(&value,&before,sizeof(value)),0);
  Handle encoding; ASSERT_EQ(tidyvnc_encoding_create(0,nullptr,0,TIDYVNC_SOURCE_COMPILED,&encoding.id,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_endpoint_get(encoding.id,&value,nullptr),TIDYVNC_WRONG_HANDLE_TYPE);
  EXPECT_EQ(std::memcmp(&value,&before,sizeof(value)),0);
}

TEST(ViewerABI, InputTimingDefaultsValidationAndCreationAreTransactional)
{
  auto timing = init<tidyvnc_input_timing>();
  ASSERT_EQ(tidyvnc_input_timing_init(&timing,nullptr),TIDYVNC_OK);
  EXPECT_EQ(timing.pointer_interval_ms,17u); EXPECT_EQ(timing.reserved,0u);
  auto saved = timing; timing.version = 2; auto invalid = timing;
  EXPECT_EQ(tidyvnc_input_timing_init(&timing,nullptr),TIDYVNC_ABI_MISMATCH);
  EXPECT_EQ(std::memcmp(&timing,&invalid,sizeof(timing)),0);
  EXPECT_EQ(tidyvnc_input_timing_init(nullptr,nullptr),TIDYVNC_INVALID_ARGUMENT);
  Client client; tidyvnc_handle unchanged = UINT64_MAX;
  timing = saved;
  EXPECT_EQ(tidyvnc_session_create_with_input_timing(client.runtime.id,&client.options,0,nullptr,&unchanged,nullptr),TIDYVNC_INVALID_ARGUMENT);
  for (auto interval : {0u,17u,uint32_t(INT_MAX)}) {
    Handle session; timing.pointer_interval_ms = interval;
    ASSERT_EQ(tidyvnc_session_create_with_input_timing(client.runtime.id,&client.options,0,&timing,&session.id,nullptr),TIDYVNC_OK);
    ASSERT_EQ(tidyvnc_session_close(session.id,nullptr),TIDYVNC_OK);
    ASSERT_TRUE(until([&] { return tidyvnc_session_poll_drained(session.id,nullptr) == TIDYVNC_OK; }));
  }
  timing.pointer_interval_ms = uint32_t(INT_MAX)+1;
  EXPECT_EQ(tidyvnc_session_create_with_input_timing(client.runtime.id,&client.options,0,&timing,&unchanged,nullptr),TIDYVNC_INVALID_ARGUMENT);
  timing = saved; timing.reserved = 1;
  EXPECT_EQ(tidyvnc_session_create_with_input_timing(client.runtime.id,&client.options,0,&timing,&unchanged,nullptr),TIDYVNC_INVALID_ARGUMENT);
  timing = saved; timing.size = 4;
  EXPECT_EQ(tidyvnc_session_create_with_input_timing(client.runtime.id,&client.options,0,&timing,&unchanged,nullptr),TIDYVNC_INVALID_ARGUMENT);
  timing = saved; timing.version = 2;
  EXPECT_EQ(tidyvnc_session_create_with_input_timing(client.runtime.id,&client.options,0,&timing,&unchanged,nullptr),TIDYVNC_ABI_MISMATCH);
  timing = saved;
  EXPECT_EQ(tidyvnc_session_create_with_input_timing(client.runtime.id,&client.options,client.runtime.id,&timing,&unchanged,nullptr),TIDYVNC_WRONG_HANDLE_TYPE);
  EXPECT_EQ(unchanged,UINT64_MAX);
}

TEST(ViewerABI, MessageLimitsDefaultsValidationAndCreationAreTransactional)
{
  auto limits = init<tidyvnc_message_limits>();
  ASSERT_EQ(tidyvnc_message_limits_init(&limits,nullptr),TIDYVNC_OK);
  EXPECT_EQ(limits.max_cut_text,256u*1024); EXPECT_EQ(limits.reserved,0u);
  auto saved = limits; limits.version = 2; auto invalid = limits;
  EXPECT_EQ(tidyvnc_message_limits_init(&limits,nullptr),TIDYVNC_ABI_MISMATCH);
  EXPECT_EQ(std::memcmp(&limits,&invalid,sizeof(limits)),0);
  EXPECT_EQ(tidyvnc_message_limits_init(nullptr,nullptr),TIDYVNC_INVALID_ARGUMENT);
  auto timing = init<tidyvnc_input_timing>();
  ASSERT_EQ(tidyvnc_input_timing_init(&timing,nullptr),TIDYVNC_OK);
  Client client; tidyvnc_handle unchanged = UINT64_MAX;
  EXPECT_EQ(tidyvnc_session_create_with_message_limits(client.runtime.id,&client.options,0,&timing,nullptr,&unchanged,nullptr),TIDYVNC_INVALID_ARGUMENT);
  limits = saved;
  for (auto limit : {0u,256u*1024,uint32_t(INT_MAX)}) {
    Handle session; limits.max_cut_text = limit;
    ASSERT_EQ(tidyvnc_session_create_with_message_limits(client.runtime.id,&client.options,0,&timing,&limits,&session.id,nullptr),TIDYVNC_OK);
    ASSERT_EQ(tidyvnc_session_close(session.id,nullptr),TIDYVNC_OK);
    ASSERT_TRUE(until([&] { return tidyvnc_session_poll_drained(session.id,nullptr) == TIDYVNC_OK; }));
  }
  limits.max_cut_text = uint32_t(INT_MAX)+1;
  EXPECT_EQ(tidyvnc_session_create_with_message_limits(client.runtime.id,&client.options,0,&timing,&limits,&unchanged,nullptr),TIDYVNC_INVALID_ARGUMENT);
  limits = saved; limits.reserved = 1;
  EXPECT_EQ(tidyvnc_session_create_with_message_limits(client.runtime.id,&client.options,0,&timing,&limits,&unchanged,nullptr),TIDYVNC_INVALID_ARGUMENT);
  limits = saved; limits.size = 4;
  EXPECT_EQ(tidyvnc_session_create_with_message_limits(client.runtime.id,&client.options,0,&timing,&limits,&unchanged,nullptr),TIDYVNC_INVALID_ARGUMENT);
  limits = saved; limits.version = 2;
  EXPECT_EQ(tidyvnc_session_create_with_message_limits(client.runtime.id,&client.options,0,&timing,&limits,&unchanged,nullptr),TIDYVNC_ABI_MISMATCH);
  limits = saved;
  EXPECT_EQ(tidyvnc_session_create_with_message_limits(client.runtime.id,&client.options,0,nullptr,&limits,&unchanged,nullptr),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(tidyvnc_session_create_with_message_limits(client.runtime.id,&client.options,client.runtime.id,&timing,&limits,&unchanged,nullptr),TIDYVNC_WRONG_HANDLE_TYPE);
  EXPECT_EQ(unchanged,UINT64_MAX);
}

TEST(ViewerABI, WindowGeometryIsStatelessCheckedAndTransactional)
{
  auto bytes = [](const char* value) { return tidyvnc_bytes{reinterpret_cast<const uint8_t*>(value),std::strlen(value)}; };
  auto value = init<tidyvnc_window_geometry>();
  ASSERT_EQ(tidyvnc_window_geometry_parse(bytes("800x600+-10+20"),&value,nullptr),TIDYVNC_OK);
  EXPECT_EQ(value.flags,3u); EXPECT_EQ(value.width,800); EXPECT_EQ(value.height,600);
  EXPECT_EQ(value.x,-10); EXPECT_EQ(value.y,20); EXPECT_EQ(value.reserved,0u);
  const auto saved = value;
  for (const auto* input : {"invalid","0x20","+2147483648+0","800x600+10"}) {
    EXPECT_EQ(tidyvnc_window_geometry_parse(bytes(input),&value,nullptr),TIDYVNC_INVALID_ARGUMENT);
    EXPECT_EQ(std::memcmp(&saved,&value,sizeof(value)),0);
  }
  value.version = 2; const auto invalid = value;
  EXPECT_EQ(tidyvnc_window_geometry_parse(bytes(""),&value,nullptr),TIDYVNC_ABI_MISMATCH);
  EXPECT_EQ(std::memcmp(&invalid,&value,sizeof(value)),0);
  EXPECT_EQ(tidyvnc_window_geometry_parse(bytes(""),nullptr,nullptr),TIDYVNC_INVALID_ARGUMENT);
  value = saved;
  EXPECT_EQ(tidyvnc_window_geometry_parse({nullptr,1},&value,nullptr),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(std::memcmp(&saved,&value,sizeof(value)),0);
  ASSERT_EQ(tidyvnc_window_geometry_parse(bytes(""),&value,nullptr),TIDYVNC_OK);
  EXPECT_EQ(value.flags,0u); EXPECT_EQ(value.width,0); EXPECT_EQ(value.x,0);
}

TEST(ViewerABI, PasswordFileRepliesPreserveRawBytesAndWipeEverySubmission)
{
  for (const std::string& password : {std::string("password"),std::string("\xf0\xe1\xf3\xf3\xf7\xef\xf2\xe4",8)}) {
    Client client; client.options.security_types[0]=2; client.create(); Peer peer(true);
    auto operation=connect(client.session.id,peer); Handle prompt;
    ASSERT_TRUE(until([&] { return tidyvnc_session_take_prompt(client.session.id,&prompt.id,nullptr)==TIDYVNC_OK; }));
    auto info=init<tidyvnc_prompt_info>(); ASSERT_EQ(tidyvnc_prompt_get(prompt.id,&info,nullptr),TIDYVNC_OK);
    auto block=rfb::obfuscate(password.c_str());
    EXPECT_EQ(tidyvnc_session_reply_password_file(client.session.id,info.id,info.generation+1,{block.data(),8},nullptr),TIDYVNC_STALE);
    EXPECT_TRUE(std::all_of(block.begin(),block.end(),[](uint8_t byte) { return byte==0; }));
    block=rfb::obfuscate(password.c_str()); auto error=init<tidyvnc_error>(); error.version=99;
    EXPECT_EQ(tidyvnc_session_reply_password_file(client.session.id,info.id,info.generation,{block.data(),8},&error),TIDYVNC_ABI_MISMATCH);
    EXPECT_TRUE(std::all_of(block.begin(),block.end(),[](uint8_t byte) { return byte==0; }));
    block.assign(9,0x55);
    EXPECT_EQ(tidyvnc_session_reply_password_file(client.session.id,info.id,info.generation,{block.data(),9},nullptr),TIDYVNC_INVALID_ARGUMENT);
    EXPECT_TRUE(std::all_of(block.begin(),block.end(),[](uint8_t byte) { return byte==0; }));
    block=rfb::obfuscate(password.c_str());
    abi_test_fail_after(1);
    const auto failed=tidyvnc_session_reply_password_file(client.session.id,info.id,info.generation,{block.data(),8},nullptr);
    abi_test_fail_after(0);
    EXPECT_EQ(failed,TIDYVNC_OUT_OF_MEMORY);
    EXPECT_TRUE(std::all_of(block.begin(),block.end(),[](uint8_t byte) { return byte==0; }));
    block=rfb::obfuscate(password.c_str());
    ASSERT_EQ(tidyvnc_session_reply_password_file(client.session.id,info.id,info.generation,{block.data(),8},nullptr),TIDYVNC_OK);
    EXPECT_TRUE(std::all_of(block.begin(),block.end(),[](uint8_t byte) { return byte==0; }));
    // VNC DES discards the top bit of each password byte. This fixed challenge
    // response therefore verifies both ordinary and non-UTF-8 legacy input.
    tidyvnc_event event{}; ASSERT_TRUE(completion(client.session.id,operation.operation,event));
    EXPECT_EQ(event.result,TIDYVNC_OPERATION_SUCCEEDED); EXPECT_TRUE(peer.verified);
    block=rfb::obfuscate("password");
    EXPECT_EQ(tidyvnc_session_reply_password_file(client.session.id,info.id,info.generation,{block.data(),8},nullptr),TIDYVNC_NOT_PENDING);
    EXPECT_TRUE(std::all_of(block.begin(),block.end(),[](uint8_t byte) { return byte==0; }));
    ASSERT_EQ(tidyvnc_session_close(client.session.id,nullptr),TIDYVNC_OK);
    ASSERT_TRUE(until([&] { return tidyvnc_session_poll_drained(client.session.id,nullptr)==TIDYVNC_OK; }));
  }
}

TEST(ViewerABI, LegacyCredentialBytesStayOpaqueBoundedAndConsumed)
{
  Client client; client.options.security_types[0]=2; client.create(); Peer peer(true);
  auto operation=connect(client.session.id,peer); Handle prompt;
  ASSERT_TRUE(until([&] { return tidyvnc_session_take_prompt(client.session.id,&prompt.id,nullptr)==TIDYVNC_OK; }));
  auto info=init<tidyvnc_prompt_info>(); ASSERT_EQ(tidyvnc_prompt_get(prompt.id,&info,nullptr),TIDYVNC_OK);
  uint8_t user[]={0xff}, invalid[]={1,0,2};
  EXPECT_EQ(tidyvnc_session_reply_credential_bytes(client.session.id,info.id,info.generation,{user,1},{invalid,3},nullptr),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(user[0],0); EXPECT_EQ(invalid[0],0); EXPECT_EQ(invalid[2],0);
  uint8_t raw[]={0xf0,0xe1,0xf3,0xf3,0xf7,0xef,0xf2,0xe4};
  // The existing text API must continue rejecting invalid UTF-8 without consuming
  // the pending prompt; the explicit byte API then preserves the same raw bytes.
  EXPECT_EQ(tidyvnc_session_reply_credentials(client.session.id,info.id,info.generation,{nullptr,0},{raw,8},nullptr),TIDYVNC_INVALID_ARGUMENT);
  for (auto byte:raw) EXPECT_EQ(byte,0);
  const uint8_t expected[]={0xf0,0xe1,0xf3,0xf3,0xf7,0xef,0xf2,0xe4};
  std::copy(expected,expected+8,raw); user[0]=0xff;
  EXPECT_EQ(tidyvnc_session_reply_credential_bytes(client.session.id,info.id,info.generation+1,{user,1},{raw,8},nullptr),TIDYVNC_STALE);
  EXPECT_EQ(user[0],0); for (auto byte:raw) EXPECT_EQ(byte,0);
  std::copy(expected,expected+8,raw);
  ASSERT_EQ(tidyvnc_session_reply_credential_bytes(client.session.id,info.id,info.generation,{nullptr,0},{raw,8},nullptr),TIDYVNC_OK);
  for (auto byte:raw) EXPECT_EQ(byte,0);
  tidyvnc_event event{}; ASSERT_TRUE(completion(client.session.id,operation.operation,event));
  EXPECT_EQ(event.result,TIDYVNC_OPERATION_SUCCEEDED); EXPECT_TRUE(peer.verified);
  ASSERT_EQ(tidyvnc_session_close(client.session.id,nullptr),TIDYVNC_OK);
  ASSERT_TRUE(until([&] { return tidyvnc_session_poll_drained(client.session.id,nullptr)==TIDYVNC_OK; }));
}
