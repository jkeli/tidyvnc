/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "peer.h"
#include <rfb/PixelFormat.h>
#include <rdr/MemOutStream.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>
#include <arpa/inet.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
namespace {
class Peer {
public:
  explicit Peer(bool authentication_, bool pattern_ = false, bool reusable_ = false,
                uint32_t family = 4, const std::string& path = {}, bool plain_ = false,
                const std::string& user = {}, const std::string& password = {}, uint16_t reversePort = 0)
    : authentication(authentication_), pattern(pattern_), reusable(reusable_), socketPath(path),
      plain(plain_), expectedUser(user), expectedPassword(password), reverse(reversePort != 0) {
    require(family == 0 || family == 4 || family == 6);
    listener = ::socket(family == 4 ? AF_INET : family == 6 ? AF_INET6 : AF_UNIX,SOCK_STREAM,0); require(listener >= 0);
    bool bound = false;
    try {
      if (reverse) {
        require(family == 4 && !reusable);
        sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(reversePort);
        require(::connect(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address)) == 0);
      } else if (family == 4) {
        sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        require(::bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address)) == 0);
        socklen_t length = sizeof(address); require(::getsockname(listener,reinterpret_cast<sockaddr*>(&address),&length) == 0);
        port = ntohs(address.sin_port);
      } else if (family == 6) {
        int one = 1; require(::setsockopt(listener,IPPROTO_IPV6,IPV6_V6ONLY,&one,sizeof(one)) == 0);
        sockaddr_in6 address{}; address.sin6_family = AF_INET6; address.sin6_addr = in6addr_loopback;
        require(::bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address)) == 0);
        socklen_t length = sizeof(address); require(::getsockname(listener,reinterpret_cast<sockaddr*>(&address),&length) == 0);
        port = ntohs(address.sin6_port);
      } else {
        sockaddr_un address{}; address.sun_family = AF_UNIX; address.sun_len = sizeof(address);
        require(!socketPath.empty() && socketPath.size() < sizeof(address.sun_path));
        std::memcpy(address.sun_path,socketPath.c_str(),socketPath.size()+1);
        require(::bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address)) == 0);
        bound = true;
      }
      if (!reverse) require(::listen(listener,1) == 0);
      thread = std::thread([this] { run(); });
    } catch (...) { ::close(listener); if (bound) ::unlink(socketPath.c_str()); throw; }
  }
  ~Peer() { stopping = true; if (thread.joinable()) thread.join(); ::close(listener); if (!socketPath.empty()) ::unlink(socketPath.c_str()); }
  bool hasKey() {
    const std::vector<uint8_t> bytes{4,1,0,0,0,0,0,65};
    std::lock_guard<std::mutex> lock(mutex);
    return std::search(received.begin(),received.end(),bytes.begin(),bytes.end()) != received.end();
  }
  uint16_t port = 0;
  std::atomic<uint32_t> clientShared{2};
  std::atomic<bool> verified{false};
  std::atomic<bool> holdAuthentication{false}, disconnectRequested{false};
  std::atomic<bool> resize{false};
  std::atomic<uint32_t> patch{0};
  std::atomic<uint32_t> cursor{0};
  std::atomic<bool> clipboardRequested{false};
  std::vector<uint8_t> clipboardWire; // protected by mutex, including marker
  uint8_t clipboardMarker = 0;
  bool queueClipboard(const uint8_t* text,uint32_t length) {
    if (length > 1024*1024 || (length && !text)) return false;
    std::vector<uint8_t> bytes{3,0,0,0,uint8_t(length>>24),uint8_t(length>>16),uint8_t(length>>8),uint8_t(length)};
    if (length) bytes.insert(bytes.end(),text,text+length);
    std::lock_guard<std::mutex> lock(mutex);
    if (!clipboardWire.empty()) return false;
    // Same stream, so the marker proves the preceding message was processed,
    // including when the reader discards it without publishing a clipboard value.
    bytes.insert(bytes.end(),{0,0,0,1,0,0,0,0,0,1,0,1,0,0,0,0,++clipboardMarker,0,0,0});
    clipboardWire.swap(bytes); return true;
  }
  bool hasClipboard() {
    const std::vector<uint8_t> bytes{6,0,0,0,0,0,0,5,'c','a','f',0xe9,'\n'};
    std::lock_guard<std::mutex> lock(mutex);
    return std::search(received.begin(),received.end(),bytes.begin(),bytes.end()) != received.end();
  }
  uint32_t clipboardCount(const uint8_t* text, uint32_t length) {
    std::vector<uint8_t> bytes{6,0,0,0,uint8_t(length>>24),uint8_t(length>>16),uint8_t(length>>8),uint8_t(length)};
    if (length) bytes.insert(bytes.end(),text,text+length);
    std::lock_guard<std::mutex> lock(mutex); uint32_t count = 0;
    auto position = received.begin();
    while ((position = std::search(position,received.end(),bytes.begin(),bytes.end())) != received.end()) { ++count; position += bytes.size(); }
    return count;
  }
  bool hasControlAltDelete() {
    std::vector<uint8_t> bytes;
    for (auto event : {std::pair<uint32_t,uint8_t>{0xffe3,1},{0xffe9,1},{0xffff,1},{0xffff,0},{0xffe9,0},{0xffe3,0}}) {
      bytes.insert(bytes.end(),{4,event.second,0,0,0,0,uint8_t(event.first>>8),uint8_t(event.first)});
    }
    std::lock_guard<std::mutex> lock(mutex);
    return std::search(received.begin(),received.end(),bytes.begin(),bytes.end()) != received.end();
  }
  uint32_t inputCount(uint32_t kind, uint32_t value, uint32_t x, uint32_t y) {
    std::vector<uint8_t> bytes;
    if (kind == 5) bytes = {5,uint8_t(value),uint8_t(x>>8),uint8_t(x),uint8_t(y>>8),uint8_t(y)};
    else bytes = {4,uint8_t(kind),0,0,uint8_t(value>>24),uint8_t(value>>16),uint8_t(value>>8),uint8_t(value)};
    std::lock_guard<std::mutex> lock(mutex); uint32_t count = 0;
    auto position = received.begin();
    while ((position = std::search(position,received.end(),bytes.begin(),bytes.end())) != received.end()) { ++count; position += bytes.size(); }
    return count;
  }
private:
  static void require(bool value) { if (!value) throw std::runtime_error("Native peer fixture failed"); }
  bool ready(int fd) { pollfd event{fd,POLLIN,0}; return ::poll(&event,1,20) > 0; }
  void read(int fd,uint8_t* bytes,size_t length) {
    const auto deadline = std::chrono::steady_clock::now()+std::chrono::seconds(pattern ? 120 : 10);
    for (size_t offset = 0; offset < length;) {
      require(!stopping && std::chrono::steady_clock::now() < deadline);
      if (!ready(fd)) continue;
      const auto count = ::recv(fd,bytes+offset,length-offset,0); require(count > 0); offset += count;
    }
  }
  void send(int fd,const uint8_t* bytes,size_t length) { require(::send(fd,bytes,length,0) == static_cast<ssize_t>(length)); }
  void run() noexcept { do { runConnection(); } while (reusable && !stopping); }
  void runConnection() noexcept {
    int fd = -1;
    try {
      while (!stopping && !reverse && !ready(listener)) {}
      if (stopping) return;
      if (reverse) { fd = listener; listener = -1; }
      else fd = ::accept(listener,nullptr,nullptr);
      require(fd >= 0);
      int one = 1; ::setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
      send(fd,reinterpret_cast<const uint8_t*>("RFB 003.008\n"),12);
      uint8_t input[16]; read(fd,input,12);
      const uint8_t security[] = {1,static_cast<uint8_t>(plain ? 19 : authentication ? 2 : 1)};
      send(fd,security,2); read(fd,input,1);
      if (plain) {
        require(input[0] == 19);
        const uint8_t version[]={0,2}; send(fd,version,sizeof(version)); read(fd,input,2);
        require(input[0] == 0 && input[1] == 2);
        const uint8_t subtype[]={0,1,0,0,1,0}; send(fd,subtype,sizeof(subtype)); read(fd,input,4);
        require(input[0] == 0 && input[1] == 0 && input[2] == 1 && input[3] == 0);
        read(fd,input,8);
        const auto length = [](const uint8_t* p) { return (uint32_t(p[0])<<24)|(uint32_t(p[1])<<16)|(uint32_t(p[2])<<8)|uint32_t(p[3]); };
        const auto users = length(input), passwords = length(input+4);
        require(users <= 64 && passwords <= 64);
        std::vector<uint8_t> user(users), password(passwords);
        read(fd,user.data(),user.size()); read(fd,password.data(),password.size());
        verified = users == expectedUser.size() && passwords == expectedPassword.size() &&
          (users == 0 || std::memcmp(user.data(),expectedUser.data(),users) == 0) &&
          (passwords == 0 || std::memcmp(password.data(),expectedPassword.data(),passwords) == 0);
        require(verified);
      } else if (authentication) {
        uint8_t challenge[16]; for (int i=0;i<16;++i) challenge[i]=i;
        send(fd,challenge,16); read(fd,input,16);
        const uint8_t expected[]={0xb8,0x66,0x92,0x41,0x25,0xc8,0xee,0xbb,0x9d,0xeb,0xc1,0xdb,0x61,0xc5,0x38,0xe2};
        verified = std::memcmp(input,expected,16) == 0;
        while (holdAuthentication && !stopping) std::this_thread::sleep_for(std::chrono::milliseconds(2));
        require(!stopping);
        if (!verified) {
          const uint8_t rejected[] = {0,0,0,1, 0,0,0,8, 'r','e','j','e','c','t','e','d'};
          send(fd,rejected,sizeof(rejected)); require(false);
        }
      }
      const uint8_t okay[4] = {}; send(fd,okay,4); read(fd,input,1);
      clientShared = input[0];
      rdr::MemOutStream wire; wire.writeU16(2); wire.writeU16(2);
      rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0).write(&wire);
      wire.writeU32(4); wire.writeBytes(reinterpret_cast<const uint8_t*>("peer"),4);
      wire.writeU8(0); wire.pad(1); wire.writeU16(1);
      wire.writeU16(0); wire.writeU16(0); wire.writeU16(2); wire.writeU16(2); wire.writeU32(0);
      // Top row red/green, bottom row blue/white: catches channel and row inversion.
      const uint8_t colors[16] = {0,0,255,0,0,255,0,0,255,0,0,0,255,255,255,0};
      if (pattern) wire.writeBytes(colors,16);
      else for (int i=0;i<4;++i) { wire.writeU8(10); wire.writeU8(20); wire.writeU8(30); wire.writeU8(0); }
      send(fd,wire.data(),wire.length());
      while (!stopping) {
        if (disconnectRequested.exchange(false)) break;
        std::vector<uint8_t> clipboardMessage;
        { std::lock_guard<std::mutex> lock(mutex); clipboardMessage.swap(clipboardWire); }
        if (!clipboardMessage.empty()) send(fd,clipboardMessage.data(),clipboardMessage.size());
        if (clipboardRequested.exchange(false)) {
          const uint8_t cutText[] = {3,0,0,0,0,0,0,6,'c','a','f',0xe9,'\r','\n'};
          send(fd,cutText,sizeof(cutText));
        }
        if (const auto which = patch.exchange(0)) {
          uint8_t update[] = {0,0,0,1, 0,0,0,0, 0,1,0,1, 0,0,0,0, 255,0,255,0};
          if (which == 2) { update[5] = update[7] = 1; update[16] = update[18] = 0; }
          send(fd,update,sizeof(update)); // Magenta at (0,0), or black at (1,1).
        }
        if (const auto shape = cursor.exchange(0)) {
          rdr::MemOutStream update;
          update.writeU8(0); update.pad(1); update.writeU16(1);
          update.writeU16(shape != 2 ? 1 : 0); update.writeU16(0);
          update.writeU16(shape != 2 ? 2 : 0); update.writeU16(shape != 2 ? 1 : 0);
          update.writeS32(-239); // RichCursor: red/green with an opaque mask.
          if (shape != 2) { update.writeBytes(colors,8); update.writeU8(shape == 4 ? 0 : shape == 3 ? 0x40 : 0xc0); }
          send(fd,update.data(),update.length());
        }
        if (resize.exchange(false)) {
          rdr::MemOutStream update;
          update.writeU8(0); update.pad(1); update.writeU16(2);
          update.writeU16(0); update.writeU16(0); update.writeU16(3); update.writeU16(1); update.writeS32(-223);
          update.writeU16(0); update.writeU16(0); update.writeU16(3); update.writeU16(1); update.writeU32(0);
          update.writeBytes(colors,12); send(fd,update.data(),update.length());
        }
        if (!ready(fd)) continue;
        uint8_t bytes[4096]; const auto count = ::recv(fd,bytes,sizeof(bytes),0); if (count <= 0) break;
        std::lock_guard<std::mutex> lock(mutex); received.insert(received.end(),bytes,bytes+count);
      }
    } catch (...) {} // Disconnect during a parked prompt is an expected scenario.
    if (fd >= 0) ::close(fd);
  }
  const bool authentication;
  const bool pattern;
  const bool reusable;
  const std::string socketPath;
  const bool plain;
  const std::string expectedUser, expectedPassword;
  const bool reverse;
  int listener = -1;
  std::atomic<bool> stopping{false};
  std::thread thread;
  std::mutex mutex;
  std::vector<uint8_t> received;
};
}
void* native_test_peer_create_reconnecting(uint32_t authentication) { try { return new Peer(authentication != 0,true,true); } catch (...) { return nullptr; } }
void* native_test_peer_create_reverse(uint16_t port,uint32_t authentication) {
  try { if (!port) return nullptr; return new Peer(authentication != 0,true,false,4,{},false,{},{},port); } catch (...) { return nullptr; }
}
void native_test_peer_hold_authentication(void* peer, uint32_t hold) { static_cast<Peer*>(peer)->holdAuthentication = hold != 0; }
void native_test_peer_disconnect(void* peer) { static_cast<Peer*>(peer)->disconnectRequested = true; }
void* native_test_peer_create(uint32_t authentication) { try { return new Peer(authentication != 0); } catch (...) { return nullptr; } }
void* native_test_peer_create_pattern(uint32_t authentication) { try { return new Peer(authentication != 0,true); } catch (...) { return nullptr; } }
void* native_test_peer_create_network(uint32_t family, const char* path) {
  try {
    if ((family == 0 && !path) || (family != 0 && path)) return nullptr;
    return new Peer(false,true,true,family,path ? path : "");
  } catch (...) { return nullptr; }
}
void native_test_peer_patch_other(void* peer) { static_cast<Peer*>(peer)->patch = 2; }
void native_test_peer_patch(void* peer) { static_cast<Peer*>(peer)->patch = 1; }
void native_test_peer_cursor(void* peer, uint32_t visible) { static_cast<Peer*>(peer)->cursor = visible ? 1 : 2; }
void native_test_peer_cursor_alpha(void* peer) { static_cast<Peer*>(peer)->cursor = 3; }
void native_test_peer_cursor_blank(void* peer) { static_cast<Peer*>(peer)->cursor = 4; }
void native_test_peer_resize(void* peer) { static_cast<Peer*>(peer)->resize = true; }
uint32_t native_test_peer_clipboard_bytes(void* peer,const uint8_t* text,uint32_t length) {
  try { return static_cast<Peer*>(peer)->queueClipboard(text,length); } catch (...) { return 0; }
}
void native_test_peer_clipboard(void* peer) { static_cast<Peer*>(peer)->clipboardRequested = true; }
uint32_t native_test_peer_has_clipboard(void* peer) { return static_cast<Peer*>(peer)->hasClipboard(); }
uint32_t native_test_peer_count_clipboard(void* peer,const uint8_t* text,uint32_t length) { return static_cast<Peer*>(peer)->clipboardCount(text,length); }
uint32_t native_test_peer_has_input(void* peer,uint32_t kind,uint32_t value,uint32_t x,uint32_t y) { return static_cast<Peer*>(peer)->inputCount(kind,value,x,y) != 0; }
uint32_t native_test_peer_count_input(void* peer,uint32_t kind,uint32_t value,uint32_t x,uint32_t y) { return static_cast<Peer*>(peer)->inputCount(kind,value,x,y); }
uint32_t native_test_peer_has_control_alt_delete(void* peer) { return static_cast<Peer*>(peer)->hasControlAltDelete(); }
void native_test_peer_destroy(void* peer) { delete static_cast<Peer*>(peer); }
uint16_t native_test_peer_port(void* peer) { return static_cast<Peer*>(peer)->port; }
uint32_t native_test_peer_verified(void* peer) { return static_cast<Peer*>(peer)->verified.load(); }
uint32_t native_test_peer_has_key(void* peer) { return static_cast<Peer*>(peer)->hasKey(); }

uint32_t native_test_peer_shared(void* peer) { return static_cast<Peer*>(peer)->clientShared.load(); }

void* native_test_peer_create_plain(const uint8_t* user,uint32_t user_length,const uint8_t* password,uint32_t password_length) {
  if (user_length > 64 || password_length > 64 || (!user && user_length) || (!password && password_length)) return nullptr;
  try {
    return new Peer(false,false,false,4,{},true,
      user_length ? std::string(reinterpret_cast<const char*>(user),user_length) : std::string(),
      password_length ? std::string(reinterpret_cast<const char*>(password),password_length) : std::string());
  } catch (...) { return nullptr; }
}
