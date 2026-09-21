/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "peer.h"
#include <rfb/PixelFormat.h>
#include <rdr/MemOutStream.h>
#include <atomic>
#include <chrono>
#include <stdexcept>
#include <thread>
#include <vector>
#include <arpa/inet.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
namespace {
// Independent wire fixture. Parses complete client messages, including requests
// split across recv calls, rather than searching arbitrary payload bytes.
class ResizePeer {
public:
  ResizePeer() {
    listener = ::socket(AF_INET,SOCK_STREAM,0); require(listener >= 0);
    try {
      sockaddr_in address{}; address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
      require(::bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address)) == 0);
      socklen_t length=sizeof(address); require(::getsockname(listener,reinterpret_cast<sockaddr*>(&address),&length)==0);
      port=ntohs(address.sin_port); require(::listen(listener,1)==0);
      thread=std::thread([this] { run(); });
    } catch (...) { ::close(listener); throw; }
  }
  ~ResizePeer() { stopping=true; if(thread.joinable()) thread.join(); ::close(listener); }
  uint16_t port=0;
  std::atomic<uint32_t> result{0}, count{0}; // UINT32_MAX holds a reply.
private:
  static void require(bool v) { if(!v) throw std::runtime_error("Resize fixture failed"); }
  bool ready(int fd) { pollfd event{fd,POLLIN,0}; return ::poll(&event,1,10)>0; }
  std::vector<uint8_t> read(int fd,size_t length) {
    std::vector<uint8_t> bytes(length); size_t offset=0;
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(15);
    while(offset<length) {
      require(!stopping && std::chrono::steady_clock::now()<deadline);
      if(!ready(fd)) continue;
      const auto n=::recv(fd,bytes.data()+offset,length-offset,0); require(n>0); offset+=n;
    }
    return bytes;
  }
  static unsigned u16(const std::vector<uint8_t>& b,size_t i) { return unsigned(b[i])*256+b[i+1]; }
  void send(int fd,const uint8_t* bytes,size_t length) { require(::send(fd,bytes,length,0)==static_cast<ssize_t>(length)); }
  void layout(int fd,unsigned reason,unsigned status,unsigned width,unsigned height,const std::vector<uint8_t>& screens) {
    rdr::MemOutStream wire;
    wire.writeU8(0); wire.pad(1); wire.writeU16(1);
    wire.writeU16(reason); wire.writeU16(status); wire.writeU16(width); wire.writeU16(height); wire.writeS32(-308);
    wire.writeU8(screens.size()/16); wire.pad(3); wire.writeBytes(screens.data(),screens.size());
    send(fd,wire.data(),wire.length());
  }
  void run() {
    int fd=-1;
    try {
      while(!stopping && !ready(listener)) {} if(stopping) return;
      fd=::accept(listener,nullptr,nullptr); require(fd>=0);
      int one=1; ::setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
      send(fd,reinterpret_cast<const uint8_t*>("RFB 003.008\n"),12); read(fd,12);
      const uint8_t security[]={1,1}; send(fd,security,2); read(fd,1);
      const uint8_t success[4]={}; send(fd,success,4); read(fd,1);
      rdr::MemOutStream init; init.writeU16(2); init.writeU16(2);
      rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0).write(&init);
      init.writeU32(6); init.writeBytes(reinterpret_cast<const uint8_t*>("resize"),6); send(fd,init.data(),init.length());
      const std::vector<uint8_t> initial={0,0,0,7,0,0,0,0,0,2,0,2,0,0,0,9};
      layout(fd,0,0,2,2,initial);
      while(!stopping) {
        const auto type=read(fd,1)[0];
        if(type==0) { read(fd,19); }
        else if(type==2) { const auto b=read(fd,3); read(fd,u16(b,1)*4); }
        else if(type==3) { read(fd,9); }
        else if(type==4) { read(fd,7); }
        else if(type==5) { read(fd,5); }
        else if(type==248) { const auto b=read(fd,8); read(fd,b[7]); }
        else if(type==150) { read(fd,9); }
        else if(type==251) {
          const auto b=read(fd,7); const auto screens=read(fd,b[5]*16); ++count;
          while(!stopping && result==UINT32_MAX) std::this_thread::sleep_for(std::chrono::milliseconds(2));
          if(stopping) break;
          layout(fd,1,result.load(),u16(b,1),u16(b,3),screens);
        } else throw std::runtime_error("Unexpected client message");
      }
    } catch (...) {} // Closing while a reply is held is intentional.
    if(fd>=0) ::close(fd);
  }
  int listener=-1; std::atomic<bool> stopping{false}; std::thread thread;
};
}
void* native_resize_peer_create(void) { try { return new ResizePeer(); } catch (...) { return nullptr; } }
void native_resize_peer_destroy(void* peer) { delete static_cast<ResizePeer*>(peer); }
uint16_t native_resize_peer_port(void* peer) { return static_cast<ResizePeer*>(peer)->port; }
void native_resize_peer_reply(void* peer,uint32_t result) { static_cast<ResizePeer*>(peer)->result=result; }
uint32_t native_resize_peer_count(void* peer) { return static_cast<ResizePeer*>(peer)->count; }
