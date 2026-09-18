/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include <gtest/gtest.h>
#include <viewer/core/PromptAuthentication.h>
#include <rfb/PixelFormat.h>
#include <rdr/FdInStream.h>
#include <rdr/FdOutStream.h>
#include <rdr/TLSSocket.h>
#include <gnutls/x509.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#ifdef __APPLE__
#include <sys/event.h>
#endif
#include <unistd.h>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <ctime>
#include <future>
#include <mutex>
#include <thread>

using namespace viewer;
using namespace std::chrono;
namespace {
struct IgnoreBrokenPipe {
  IgnoreBrokenPipe() {
    struct sigaction action{};
    action.sa_handler=SIG_IGN;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGPIPE,&action,&previous)) throw std::runtime_error("sigaction");
  }
  ~IgnoreBrokenPipe() { sigaction(SIGPIPE,&previous,nullptr); }
  struct sigaction previous;
};
void require(bool okay, const char* message) {
  if (!okay) throw std::runtime_error(message);
}
void tlsCheck(int result) {
  if (result < 0) throw std::runtime_error(gnutls_strerror(result));
}
struct Descriptor {
  explicit Descriptor(int value_=-1) : value(value_) {}
  ~Descriptor() { if (value>=0) ::close(value); }
  Descriptor(const Descriptor&)=delete;
  Descriptor& operator=(const Descriptor&)=delete;
  int value;
};
struct Loopback {
  Loopback() {
    Descriptor listener(::socket(AF_INET,SOCK_STREAM,0));
    require(listener.value>=0,"socket listener");
    sockaddr_in address{};
    address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    require(::bind(listener.value,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0,"bind loopback");
    require(::listen(listener.value,1)==0,"listen loopback");
    socklen_t length=sizeof(address);
    require(::getsockname(listener.value,reinterpret_cast<sockaddr*>(&address),&length)==0,"getsockname");
    client.value=::socket(AF_INET,SOCK_STREAM,0); require(client.value>=0,"socket client");
    require(::connect(client.value,reinterpret_cast<sockaddr*>(&address),length)==0,"connect loopback");
    server.value=::accept(listener.value,nullptr,nullptr); require(server.value>=0,"accept loopback");
    for (int fd : {client.value,server.value}) {
      int one=1;
      require(::setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one))==0,"TCP_NODELAY");
#ifdef SO_NOSIGPIPE
      require(::setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one))==0,"SO_NOSIGPIPE");
#endif
    }
  }
  void stop() { ::shutdown(client.value,SHUT_RDWR); ::shutdown(server.value,SHUT_RDWR); }
  Descriptor client,server;
};
void waitReadable(int fd) {
  pollfd event{fd,POLLIN,0};
  if (::poll(&event,1,5)<0 && errno!=EINTR) throw std::runtime_error("poll failed");
}
// A test host observes FIN without another consumer of protocol bytes. The
// production readiness adapter remains N1.6; this proves its cancellation seam.
bool peerClosed(int fd) {
#ifdef __APPLE__
  Descriptor queue(::kqueue()); require(queue.value>=0,"kqueue");
  struct kevent change,event;
  EV_SET(&change,fd,EVFILT_READ,EV_ADD,0,0,nullptr);
  timespec timeout{0,0};
  int count=::kevent(queue.value,&change,1,&event,1,&timeout);
  require(count>=0,"kevent");
  return count && (event.flags & EV_EOF);
#else
  pollfd event{fd,POLLIN|POLLRDHUP,0};
  require(::poll(&event,1,0)>=0,"poll peer close");
  return event.revents & (POLLRDHUP|POLLHUP|POLLERR);
#endif
}
struct Certificate {
  Certificate() {
    tlsCheck(gnutls_global_init());
    tlsCheck(gnutls_x509_privkey_init(&key));
    tlsCheck(gnutls_x509_privkey_generate(key,GNUTLS_PK_RSA,2048,0));
    tlsCheck(gnutls_x509_crt_init(&certificate));
    tlsCheck(gnutls_x509_crt_set_version(certificate,3));
    const uint8_t serial=1;
    tlsCheck(gnutls_x509_crt_set_serial(certificate,&serial,1));
    tlsCheck(gnutls_x509_crt_set_activation_time(certificate,time(nullptr)-3600));
    tlsCheck(gnutls_x509_crt_set_expiration_time(certificate,time(nullptr)+86400));
    tlsCheck(gnutls_x509_crt_set_dn(certificate,"CN=localhost",nullptr));
    tlsCheck(gnutls_x509_crt_set_key(certificate,key));
    tlsCheck(gnutls_x509_crt_set_subject_alt_name(certificate,GNUTLS_SAN_DNSNAME,"localhost",9,GNUTLS_FSAN_SET));
    tlsCheck(gnutls_x509_crt_sign2(certificate,certificate,key,GNUTLS_DIG_SHA256,0));
    tlsCheck(gnutls_certificate_allocate_credentials(&credentials));
    tlsCheck(gnutls_certificate_set_x509_key(credentials,&certificate,1,key));
  }
  ~Certificate() {
    gnutls_certificate_free_credentials(credentials);
    gnutls_x509_crt_deinit(certificate); gnutls_x509_privkey_deinit(key);
    gnutls_global_deinit();
  }
  gnutls_x509_privkey_t key=nullptr;
  gnutls_x509_crt_t certificate=nullptr;
  gnutls_certificate_credentials_t credentials=nullptr;
};
struct PromptInbox {
  void notify() {
    AuthenticationPrompt prompt;
    require(auth->takeRequest(prompt),"Missing authentication request");
    std::lock_guard<std::mutex> lock(mutex);
    require(!pending,"Overlapping prompts");
    request=std::move(prompt); pending=true; changed.notify_all();
  }
  AuthenticationPrompt take() {
    std::unique_lock<std::mutex> lock(mutex);
    require(changed.wait_for(lock,seconds(5),[&] { return pending; }),"Prompt never arrived");
    pending=false; return request;
  }
  std::shared_ptr<PromptAuthentication> auth;
  std::mutex mutex;
  std::condition_variable changed;
  AuthenticationPrompt request;
  bool pending=false;
};
// Minimal independent RFB server: verifies the received DES response before
// sending SecurityResult. Known answer is the pre-extraction password vector
// also recorded in d3des.cxx; no client crypto helper computes the expectation.
class Peer {
public:
  Peer(Loopback& wires_, bool encrypted_, Certificate& certificate_)
    : wires(wires_), encrypted(encrypted_), certificate(certificate_),
      rawInput(wires.server.value),rawOutput(wires.server.value), input(&rawInput),output(&rawOutput) {}
  ~Peer() { if (tls) tls->shutdown(); tls.reset(); if (tlsSession) gnutls_deinit(tlsSession); }
  void run() {
    deadline=steady_clock::now()+seconds(10);
    const uint8_t version[]="RFB 003.008\n";
    output->writeBytes(version,12); flush();
    uint8_t received[16]; read(received,12); require(!memcmp(version,received,12),"RFB version");
    const uint8_t type=encrypted ? rfb::secTypeVeNCrypt : rfb::secTypeVncAuth;
    output->writeU8(1); output->writeU8(type); flush();
    read(received,1); require(received[0]==type,"RFB security type");
    if (encrypted) {
      output->writeU8(0); output->writeU8(2); flush(); read(received,2);
      require(received[0]==0 && received[1]==2,"VeNCrypt version");
      output->writeU8(0); output->writeU8(1); output->writeU32(rfb::secTypeX509Vnc); flush();
      wait([&] { return input->hasData(4); });
      require(input->readU32()==rfb::secTypeX509Vnc,"VeNCrypt subtype");
      tlsCheck(gnutls_init(&tlsSession,GNUTLS_SERVER));
      // TLS 1.2 avoids post-handshake ticket traffic during FIN observation.
      tlsCheck(gnutls_priority_set_direct(tlsSession,"NORMAL:-VERS-ALL:+VERS-TLS1.2",nullptr));
      tlsCheck(gnutls_credentials_set(tlsSession,GNUTLS_CRD_CERTIFICATE,certificate.credentials));
      tls.reset(new rdr::TLSSocket(input,output,tlsSession));
      output->writeU8(1); flush();
      wait([&] { return tls->handshake(); });
      input=&tls->inStream(); output=&tls->outStream();
    }
    const uint8_t challenge[]={0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15};
    const uint8_t expected[]={0xb8,0x66,0x92,0x41,0x25,0xc8,0xee,0xbb,0x9d,0xeb,0xc1,0xdb,0x61,0xc5,0x38,0xe2};
    output->writeBytes(challenge,16); flush(); read(received,16);
    verified=!memcmp(received,expected,16);
    output->writeU32(verified ? 0 : 1);
    if (!verified) {
      const uint8_t reason[]="Wrong password";
      output->writeU32(sizeof(reason)-1); output->writeBytes(reason,sizeof(reason)-1); flush(); return;
    }
    flush(); read(received,1); // ClientInit
    output->writeU16(2); output->writeU16(2);
    rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0).write(output);
    output->writeU32(4); output->writeBytes(reinterpret_cast<const uint8_t*>("peer"),4); flush();
  }
  bool verified=false;
private:
  template<class F> void wait(F done) {
    while (!done()) {
      require(steady_clock::now()<deadline,"Peer deadline exceeded");
      waitReadable(wires.server.value);
    }
  }
  void read(uint8_t* bytes,size_t size) { wait([&] { return input->hasData(size); }); input->readBytes(bytes,size); }
  void flush() { output->flush(); }
  Loopback& wires;
  bool encrypted;
  Certificate& certificate;
  rdr::FdInStream rawInput;
  rdr::FdOutStream rawOutput;
  rdr::InStream* input;
  rdr::OutStream* output;
  gnutls_session_t tlsSession=nullptr;
  std::unique_ptr<rdr::TLSSocket> tls;
  steady_clock::time_point deadline;
};
struct Outcome {
  enum Kind { Ready, Interrupted, Rejected, Failed } kind=Failed;
  PromptCancelReason reason=PromptCancelReason::Cancelled;
  std::string error;
};
// The test host is deliberately separate from the protocol owner. Teardown
// cancels directly, interrupts IO and joins off the simulated UI call path.
class Attempt {
public:
  Attempt(ProtocolSession& session_,PromptInbox& inbox_,bool encrypted,Certificate& certificate)
    : session(session_),inbox(inbox_),peer(wires,encrypted,certificate) {
    server=std::async(std::launch::async,[&] {
      try { peer.run(); return std::string(); }
      catch (const std::exception& e) { return std::string(e.what()); }
    });
    client=std::async(std::launch::async,[&] {
      rdr::FdInStream input(wires.client.value);
      rdr::FdOutStream output(wires.client.value);
      Outcome outcome;
      try {
        session.start("localhost",input,output);
        const auto deadline=steady_clock::now()+seconds(10);
        while (!session.desktop().ready) {
          require(steady_clock::now()<deadline,"Client deadline exceeded");
          if (!session.processMessage()) waitReadable(wires.client.value);
        }
        outcome.kind=Outcome::Ready;
      } catch (const PromptInterrupted& e) {
        outcome.kind=Outcome::Interrupted; outcome.reason=e.reason;
      } catch (const rfb::auth_cancelled&) { outcome.kind=Outcome::Rejected; }
      catch (const rfb::auth_error&) { outcome.kind=Outcome::Rejected; }
      catch (const std::exception& e) { outcome.error=e.what(); }
      session.close(); // Borrowed streams outlive protocol shutdown.
      return outcome;
    });
  }
  ~Attempt() {
    inbox.auth->cancel(); wires.stop();
    if (client.valid()) client.wait();
    if (server.valid()) server.wait();
  }
  Outcome finish() {
    require(client.wait_for(seconds(5))==std::future_status::ready,"Client did not drain");
    return client.get();
  }
  void stopFromUI() { inbox.auth->cancel(); wires.stop(); }
  void peerDisappears() {
    ::shutdown(wires.server.value,SHUT_RDWR);
    const auto deadline=steady_clock::now()+seconds(2);
    while (!peerClosed(wires.client.value)) {
      require(steady_clock::now()<deadline,"FIN not observed"); waitReadable(wires.client.value);
    }
    inbox.auth->cancel(PromptCancelReason::PeerClosed);
  }
  ProtocolSession& session;
  PromptInbox& inbox;
  Loopback wires;
  Peer peer;
  std::future<std::string> server;
  std::future<Outcome> client;
};
}

class AuthenticationSocket : public ::testing::TestWithParam<bool> {
protected:
  void SetUp() override {
    inbox.auth=std::make_shared<PromptAuthentication>([this] { inbox.notify(); },seconds(2));
    makeSession();
  }
  void makeSession() {
    rfb::ClientTLSOptions options;
    options.priority="NORMAL:-VERS-ALL:+VERS-TLS1.2";
    session.reset(new ProtocolSession(rfb::SecurityClient(
      {static_cast<uint32_t>(GetParam() ? rfb::secTypeX509Vnc : rfb::secTypeVncAuth)},options),{},{},inbox.auth));
  }
  AuthenticationPrompt credentials() {
    auto prompt=inbox.take();
    if (GetParam()) {
      EXPECT_EQ(prompt.kind,PromptKind::Certificate);
      EXPECT_NE(prompt.certificateStatus & GNUTLS_CERT_SIGNER_NOT_FOUND,0u);
      EXPECT_FALSE(prompt.identity.empty());
      EXPECT_EQ(inbox.auth->replyTrust(prompt.id,prompt.generation,true),PromptReply::Accepted);
      prompt=inbox.take();
    }
    EXPECT_EQ(prompt.kind,PromptKind::Credentials);
    EXPECT_EQ(prompt.secure,GetParam());
    return prompt;
  }
  IgnoreBrokenPipe ignoreBrokenPipe;
  Certificate certificate;
  PromptInbox inbox;
  std::unique_ptr<ProtocolSession> session;
};
TEST_P(AuthenticationSocket, ServerVerifiesPasswordBeforeSessionBecomesReady)
{
  Attempt attempt(*session,inbox,GetParam(),certificate);
  auto prompt=credentials();
  EXPECT_EQ(inbox.auth->replyCredentials(prompt.id,prompt.generation,"","password"),PromptReply::Accepted);
  auto outcome=attempt.finish(); EXPECT_EQ(outcome.kind,Outcome::Ready) << outcome.error;
  EXPECT_TRUE(attempt.server.get().empty()); EXPECT_TRUE(attempt.peer.verified);
}
TEST_P(AuthenticationSocket, IncorrectPasswordIsRejectedByServer)
{
  Attempt attempt(*session,inbox,GetParam(),certificate);
  auto prompt=credentials();
  EXPECT_EQ(inbox.auth->replyCredentials(prompt.id,prompt.generation,"","incorrect"),PromptReply::Accepted);
  EXPECT_EQ(attempt.finish().kind,Outcome::Rejected);
  EXPECT_TRUE(attempt.server.get().empty()); EXPECT_FALSE(attempt.peer.verified);
}
TEST_P(AuthenticationSocket, CloseOutstandingPromptThenReconnectRejectsOldReplies)
{
  AuthenticationPrompt old;
  {
    Attempt attempt(*session,inbox,GetParam(),certificate);
    old=inbox.take(); attempt.stopFromUI();
    auto outcome=attempt.finish(); EXPECT_EQ(outcome.kind,Outcome::Interrupted);
    EXPECT_EQ(outcome.reason,PromptCancelReason::Cancelled);
    EXPECT_FALSE(session->desktop().active);
    EXPECT_EQ(inbox.auth->replyTrust(old.id,old.generation,true),PromptReply::NoPendingRequest);
  }
  Attempt retry(*session,inbox,GetParam(),certificate);
  auto prompt=credentials(); EXPECT_GT(prompt.generation,old.generation);
  EXPECT_GT(prompt.id,old.id);
  EXPECT_EQ(inbox.auth->replyCredentials(old.id,old.generation,"","incorrect"),PromptReply::StaleRequest);
  EXPECT_EQ(inbox.auth->replyCredentials(prompt.id,prompt.generation,"","password"),PromptReply::Accepted);
  EXPECT_EQ(inbox.auth->replyCredentials(prompt.id,prompt.generation,"","incorrect"),PromptReply::NoPendingRequest);
  EXPECT_EQ(retry.finish().kind,Outcome::Ready);
  EXPECT_TRUE(retry.server.get().empty()); EXPECT_TRUE(retry.peer.verified);
}
TEST_P(AuthenticationSocket, QuitCancelsCredentialPromptWithoutQueuedWorkerCommand)
{
  Attempt attempt(*session,inbox,GetParam(),certificate);
  credentials();
  const auto start=steady_clock::now(); attempt.stopFromUI();
  EXPECT_LT(steady_clock::now()-start,milliseconds(100));
  auto outcome=attempt.finish(); EXPECT_EQ(outcome.kind,Outcome::Interrupted);
  EXPECT_EQ(outcome.reason,PromptCancelReason::Cancelled);
  EXPECT_FALSE(session->desktop().active);
  EXPECT_NO_THROW(session->close());
}
TEST_P(AuthenticationSocket, OutstandingPromptTimesOutAndDrains)
{
  // The timeout starts when the callback publishes, not during TLS negotiation.
  session.reset();
  inbox.auth=std::make_shared<PromptAuthentication>([this] { inbox.notify(); },milliseconds(100));
  makeSession();
  Attempt attempt(*session,inbox,GetParam(),certificate);
  inbox.take();
  auto outcome=attempt.finish(); EXPECT_EQ(outcome.kind,Outcome::Interrupted);
  EXPECT_EQ(outcome.reason,PromptCancelReason::TimedOut);
  EXPECT_FALSE(session->desktop().active);
}
TEST_P(AuthenticationSocket, PeerClosureWakesOutstandingPromptWithoutReadingItsStream)
{
  Attempt attempt(*session,inbox,GetParam(),certificate);
  inbox.take(); attempt.peerDisappears();
  auto outcome=attempt.finish(); EXPECT_EQ(outcome.kind,Outcome::Interrupted);
  EXPECT_EQ(outcome.reason,PromptCancelReason::PeerClosed);
  EXPECT_FALSE(session->desktop().active);
}
TEST_P(AuthenticationSocket, RejectsMismatchedOrDeniedTrustReplies)
{
  Attempt attempt(*session,inbox,GetParam(),certificate);
  auto prompt=inbox.take();
  if (GetParam()) {
    ASSERT_EQ(prompt.kind,PromptKind::Certificate);
    EXPECT_EQ(inbox.auth->replyCredentials(prompt.id,prompt.generation,"","password"),PromptReply::WrongKind);
    EXPECT_EQ(inbox.auth->replyTrust(prompt.id,prompt.generation,false),PromptReply::Accepted);
    EXPECT_EQ(attempt.finish().kind,Outcome::Rejected);
  } else {
    EXPECT_EQ(inbox.auth->replyTrust(prompt.id,prompt.generation,true),PromptReply::WrongKind);
    attempt.stopFromUI(); EXPECT_EQ(attempt.finish().kind,Outcome::Interrupted);
  }
  attempt.wires.stop();
  EXPECT_FALSE(attempt.server.get().empty());
  EXPECT_FALSE(attempt.peer.verified);
}
TEST_P(AuthenticationSocket, OtherSecuritySessionCompletesWhileFirstPromptIsParked)
{
  Attempt parked(*session,inbox,GetParam(),certificate);
  auto pending=inbox.take();
  PromptInbox other;
  other.auth=std::make_shared<PromptAuthentication>([&] { other.notify(); },seconds(2));
  rfb::ClientTLSOptions options;
  options.priority="NORMAL:-VERS-ALL:+VERS-TLS1.2";
  ProtocolSession independent(rfb::SecurityClient(
    {static_cast<uint32_t>(GetParam() ? rfb::secTypeVncAuth : rfb::secTypeX509Vnc)},options),{},{},other.auth);
  Attempt progressing(independent,other,!GetParam(),certificate);
  auto prompt=other.take();
  if (!GetParam()) {
    ASSERT_EQ(prompt.kind,PromptKind::Certificate);
    EXPECT_EQ(other.auth->replyTrust(prompt.id,prompt.generation,true),PromptReply::Accepted);
    prompt=other.take();
  }
  ASSERT_EQ(prompt.kind,PromptKind::Credentials);
  EXPECT_EQ(other.auth->replyCredentials(prompt.id,prompt.generation,"","password"),PromptReply::Accepted);
  EXPECT_EQ(progressing.finish().kind,Outcome::Ready);
  EXPECT_TRUE(progressing.server.get().empty()); EXPECT_TRUE(progressing.peer.verified);
  // The first attempt is still awaiting its own response, not an inherited one.
  EXPECT_EQ(parked.client.wait_for(milliseconds(0)),std::future_status::timeout);
  EXPECT_EQ(pending.generation,1u);
  parked.stopFromUI(); EXPECT_EQ(parked.finish().kind,Outcome::Interrupted);
}
INSTANTIATE_TEST_SUITE_P(Loopback,AuthenticationSocket,::testing::Bool(),
  [](const ::testing::TestParamInfo<bool>& info) { return info.param ? "X509Vnc" : "Vnc"; });
