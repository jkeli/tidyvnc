/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include <gtest/gtest.h>
#include <viewer/core/PromptAuthentication.h>
#include <viewer/core/SessionWorker.h>
#include <viewer/platform/SocketTransport.h>
#include <network/TcpSocket.h>
#include <rfb/PixelFormat.h>
#include "../viewer/host-key-fixture.h"
#include <rdr/FdInStream.h>
#include <rdr/FdOutStream.h>
#include <rdr/TLSSocket.h>
#include <gnutls/x509.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>
#include <algorithm>
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
std::unique_ptr<SessionTransport> takeClient(Descriptor& client) {
  std::unique_ptr<network::Socket> socket(new network::TcpSocket(client.value));
  client.value=-1;
  return adoptSocketTransport(std::move(socket));
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
    : session(session_),inbox(inbox_),peer(wires,encrypted,certificate),
      transport(takeClient(wires.client)) {
    server=std::async(std::launch::async,[&] {
      try { peer.run(); return std::string(); }
      catch (const std::exception& e) { return std::string(e.what()); }
    });
    observer=std::async(std::launch::async,[&] {
      auto ready=transport->waitPeerClosure(steady_clock::now()+seconds(10));
      if (ready.peerClosed && !ready.cancelled)
        inbox.auth->cancel(PromptCancelReason::PeerClosed);
    });
    client=std::async(std::launch::async,[&] {
      Outcome outcome;
      try {
        session.start("localhost",transport->input(),transport->output());
        const auto deadline=steady_clock::now()+seconds(10);
        while (!session.desktop().ready) {
          require(steady_clock::now()<deadline,"Client deadline exceeded");
          bool progressed=session.processMessage();
          transport->flush();
          session.dispatchScheduled();
          if (!progressed) {
            auto next=deadline;
            SessionScheduler::TimePoint scheduled;
            if (session.nextDeadline(scheduled)) next=std::min(next,scheduled);
            auto ready=transport->wait(next,transport->outputPending());
            require(!ready.cancelled,"Client transport cancelled");
          }
        }
        outcome.kind=Outcome::Ready;
      } catch (const PromptInterrupted& e) {
        outcome.kind=Outcome::Interrupted; outcome.reason=e.reason;
      } catch (const rfb::auth_cancelled&) { outcome.kind=Outcome::Rejected; }
      catch (const rfb::auth_error&) { outcome.kind=Outcome::Rejected; }
      catch (const std::exception& e) { outcome.error=e.what(); }
      session.close(); // Borrowed streams outlive protocol shutdown.
      transport->control()->cancel();
      return outcome;
    });
  }
  ~Attempt() {
    inbox.auth->cancel(); transport->control()->cancel(); wires.stop();
    if (client.valid()) client.wait();
    if (observer.valid()) observer.wait();
    if (server.valid()) server.wait();
  }
  Outcome finish() {
    require(client.wait_for(seconds(5))==std::future_status::ready,"Client did not drain");
    return client.get();
  }
  void stopFromUI() { inbox.auth->cancel(); transport->control()->cancel(); wires.stop(); }
  void peerDisappears() {
    ::shutdown(wires.server.value,SHUT_RDWR);
    require(observer.wait_for(seconds(2))==std::future_status::ready,"FIN not observed");
    observer.get();
  }
  ProtocolSession& session;
  PromptInbox& inbox;
  Loopback wires;
  Peer peer;
  std::unique_ptr<SessionTransport> transport;
  std::future<std::string> server;
  std::future<void> observer;
  std::future<Outcome> client;
};

// Same independent TCP/TLS peer, now driven by the production thread owner.
class WorkerAttempt {
public:
  WorkerAttempt(bool encrypted, Certificate& certificate, rfb::ClientTLSOptions tls = {}) : peer(wires, encrypted, certificate)
  {
    server = std::async(std::launch::async, [&] {
      try { peer.run(); return std::string(); }
      catch (const std::exception& error) { return std::string(error.what()); }
    });
    if (tls.priority.empty()) tls.priority = "NORMAL:-VERS-ALL:+VERS-TLS1.2";
    worker = runtime.start(takeClient(wires.client), "localhost",
      rfb::SecurityClient({static_cast<uint32_t>(encrypted ? rfb::secTypeX509Vnc : rfb::secTypeVncAuth)}, tls));
  }
  ~WorkerAttempt()
  {
    worker->closeAndDrain(); wires.stop();
    if (server.valid()) server.wait();
  }
  AuthenticationPrompt prompt()
  {
    AuthenticationPrompt result;
    const auto deadline = steady_clock::now() + seconds(3);
    while (!worker->authentication()->takeRequest(result)) {
      require(steady_clock::now() < deadline, "Worker prompt never arrived");
      std::this_thread::sleep_for(milliseconds(1));
    }
    return result;
  }
  SessionRuntime runtime;
  Loopback wires;
  Peer peer;
  std::future<std::string> server;
  std::shared_ptr<SessionWorker> worker;
};
// Prepared adapter for the already-established loopback fixture. The runtime
// still owns every reconnect, prompt, protocol and drain transition.
class ReadyConnection : public ConnectionAttempt {
public:
  explicit ReadyConnection(std::unique_ptr<SessionTransport> value) : transport(std::move(value)) {}
  std::string serverName() const override { return "localhost"; }
  std::shared_ptr<TransportControl> control() const override { return transport->control(); }
  std::unique_ptr<SessionTransport> run(const Progress& progress) override {
    progress(ConnectionPhase::Connecting); return std::move(transport);
  }
private:
  std::unique_ptr<SessionTransport> transport;
};
class ReusableNetworkAttempt {
public:
  ReusableNetworkAttempt(std::shared_ptr<SessionWorker> worker_, bool encrypted, Certificate& certificate)
    : worker(std::move(worker_)), peer(wires, encrypted, certificate)
  {
    server = std::async(std::launch::async, [&] {
      try { peer.run(); return std::string(); }
      catch (const std::exception& error) { return std::string(error.what()); }
    });
    connect = worker->connect(std::unique_ptr<ConnectionAttempt>(new ReadyConnection(takeClient(wires.client))));
    require(connect.status == CommandAdmission::Accepted, "Reconnect admission failed");
  }
  ~ReusableNetworkAttempt() { wires.stop(); if (server.valid()) server.wait(); }
  AuthenticationPrompt prompt() {
    AuthenticationPrompt result;
    const auto deadline = steady_clock::now() + seconds(3);
    while (!worker->authentication()->takeRequest(result)) {
      require(steady_clock::now() < deadline, "Reconnect prompt never arrived");
      std::this_thread::sleep_for(milliseconds(1));
    }
    return result;
  }
  SessionEvent completion(uint64_t id) {
    SessionEvent result;
    const auto deadline = steady_clock::now() + seconds(3);
    for (;;) {
      while (worker->events()->take(result))
        if (result.kind == SessionEventKind::Completion && result.operation == id) return result;
      require(steady_clock::now() < deadline, "Reconnect completion never arrived");
      std::this_thread::sleep_for(milliseconds(1));
    }
  }
  std::shared_ptr<SessionWorker> worker;
  Loopback wires;
  Peer peer;
  std::future<std::string> server;
  CommandSubmission connect{CommandAdmission::Busy};
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
    EXPECT_EQ(prompt.securityType,static_cast<uint32_t>(GetParam() ? rfb::secTypeX509Vnc : rfb::secTypeVncAuth));
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

TEST_P(AuthenticationSocket, ProductionWorkerAuthenticatesAndJoinsBeforeDrainCompletion)
{
  WorkerAttempt attempt(GetParam(), certificate);
  auto bridge = attempt.worker->authentication();
  auto prompt = attempt.prompt();
  if (GetParam()) {
    ASSERT_EQ(prompt.kind, PromptKind::Certificate);
    EXPECT_EQ(bridge->replyTrust(prompt.id, prompt.generation, true), PromptReply::Accepted);
    prompt = attempt.prompt();
  }
  ASSERT_EQ(prompt.kind, PromptKind::Credentials);
  EXPECT_EQ(bridge->replyCredentials(prompt.id, prompt.generation, "", "password"), PromptReply::Accepted);
  const auto deadline = steady_clock::now() + seconds(3);
  while (attempt.worker->events()->snapshot().state != SessionState::Connected && steady_clock::now() < deadline)
    std::this_thread::sleep_for(milliseconds(1));
  ASSERT_EQ(attempt.worker->events()->snapshot().state, SessionState::Connected);
  ASSERT_EQ(attempt.server.wait_for(seconds(3)), std::future_status::ready);
  EXPECT_TRUE(attempt.server.get().empty()); EXPECT_TRUE(attempt.peer.verified);
  auto done = attempt.worker->closeAndDrain();
  ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(done.get().code, WorkerResultCode::Cancelled);
  EXPECT_TRUE(attempt.worker->events()->sealed()); EXPECT_EQ(attempt.runtime.active(), 0u);
}

TEST_P(AuthenticationSocket, ReusableSessionAuthenticatesFreshSocketsWithStablePromptIdentity)
{
  SessionRuntime runtime;
  rfb::ClientTLSOptions tls; tls.priority = "NORMAL:-VERS-ALL:+VERS-TLS1.2";
  auto worker = runtime.createSession(rfb::SecurityClient(
    {static_cast<uint32_t>(GetParam() ? rfb::secTypeX509Vnc : rfb::secTypeVncAuth)}, tls));
  auto bridge = worker->authentication();
  AuthenticationPrompt previous;
  for (int n = 0; n < 2; ++n) {
    ReusableNetworkAttempt attempt(worker, GetParam(), certificate);
    auto prompt = attempt.prompt();
    if (GetParam()) {
      ASSERT_EQ(prompt.kind, PromptKind::Certificate);
      EXPECT_EQ(bridge->replyTrust(prompt.id, prompt.generation, true), PromptReply::Accepted);
      prompt = attempt.prompt();
    }
    ASSERT_EQ(prompt.kind, PromptKind::Credentials);
    if (n) {
      EXPECT_GT(prompt.id, previous.id); EXPECT_GT(prompt.generation, previous.generation);
      EXPECT_EQ(bridge->replyCredentials(previous.id, previous.generation, "", "password"), PromptReply::StaleRequest);
    }
    EXPECT_EQ(bridge->replyCredentials(prompt.id, prompt.generation, "", "password"), PromptReply::Accepted);
    auto connected = attempt.completion(attempt.connect.operation);
    EXPECT_EQ(connected.result, OperationResult::Succeeded);
    EXPECT_EQ(connected.snapshot.generation, prompt.generation);
    ASSERT_EQ(attempt.server.wait_for(seconds(3)), std::future_status::ready);
    EXPECT_TRUE(attempt.server.get().empty()); EXPECT_TRUE(attempt.peer.verified);
    auto disconnect = worker->disconnect(prompt.generation);
    ASSERT_EQ(disconnect.status, CommandAdmission::Accepted);
    auto disconnected = attempt.completion(disconnect.operation);
    EXPECT_EQ(disconnected.result, OperationResult::Succeeded);
    EXPECT_EQ(disconnected.snapshot.state, SessionState::Closed);
    EXPECT_FALSE(worker->events()->sealed()); EXPECT_EQ(worker->authentication(), bridge);
    previous = prompt;
  }
  ASSERT_EQ(worker->closeAndDrain().wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(runtime.active(), 0u);
}

TEST_P(AuthenticationSocket, ProductionWorkerObservesFinWhilePromptIsParked)
{
  WorkerAttempt attempt(GetParam(), certificate);
  auto prompt = attempt.prompt();
  EXPECT_NE(prompt.id, 0u);
  ::shutdown(attempt.wires.server.value, SHUT_RDWR);
  auto done = attempt.worker->drained();
  ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(done.get().code, WorkerResultCode::PeerClosed);
  EXPECT_EQ(attempt.worker->events()->snapshot().state, SessionState::Closed);
  EXPECT_EQ(attempt.worker->events()->snapshot().endReason, SessionEndReason::PeerClosed);
  EXPECT_EQ(attempt.worker->authentication()->replyTrust(prompt.id, prompt.generation, true), PromptReply::NoPendingRequest);
}
TEST_P(AuthenticationSocket, ProductionWorkerReportsRejectedPasswordAsOneFailedAttempt)
{
  WorkerAttempt attempt(GetParam(), certificate);
  auto bridge = attempt.worker->authentication();
  auto prompt = attempt.prompt();
  if (GetParam()) {
    EXPECT_EQ(bridge->replyTrust(prompt.id, prompt.generation, true), PromptReply::Accepted);
    prompt = attempt.prompt();
  }
  EXPECT_EQ(bridge->replyCredentials(prompt.id, prompt.generation, "", "incorrect"), PromptReply::Accepted);
  auto done = attempt.worker->drained();
  ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(done.get().code, WorkerResultCode::AuthenticationRejected);
  EXPECT_EQ(attempt.worker->events()->snapshot().state, SessionState::Failed);
  EXPECT_EQ(attempt.worker->events()->snapshot().endReason, SessionEndReason::AuthenticationRejected);
  SessionEvent event; unsigned terminals = 0;
  while (attempt.worker->events()->take(event))
    if (event.kind == SessionEventKind::State &&
        (event.snapshot.state == SessionState::Closed || event.snapshot.state == SessionState::Failed)) ++terminals;
  EXPECT_EQ(terminals, 1u);
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

#ifdef HAVE_NETTLE
TEST(AuthenticationSocket, RSAAESWireKeysReachOwnedTrustPromptBeforeCredentials)
{
  IgnoreBrokenPipe ignore;
  for (bool malformed : {false,true}) {
  for (uint8_t type : {rfb::secTypeRA2,rfb::secTypeRA2ne,rfb::secTypeRA256,rfb::secTypeRAne256}) {
    SCOPED_TRACE(unsigned(type));
    SessionRuntime runtime; Loopback wires;
    auto server=std::async(std::launch::async,[&] {
      rdr::FdInStream input(wires.server.value); rdr::FdOutStream output(wires.server.value);
      const auto deadline=steady_clock::now()+seconds(5);
      auto read=[&](uint8_t* data,size_t count) {
        while (!input.hasData(count)) { require(steady_clock::now()<deadline,"RSA fixture timeout"); waitReadable(wires.server.value); }
        input.readBytes(data,count);
      };
      const uint8_t version[]="RFB 003.008\n"; uint8_t reply[12];
      output.writeBytes(version,12); output.flush(); read(reply,12); require(!memcmp(version,reply,12),"RFB version");
      output.writeU8(1); output.writeU8(type); output.flush(); read(reply,1); require(reply[0]==type,"RSA security type");
      std::vector<uint8_t> key(std::begin(host_key_fixture),std::end(host_key_fixture));
      if (malformed) key[4]=0;
      output.writeBytes(key.data(),key.size()); output.flush();
    });
    auto worker=runtime.start(takeClient(wires.client),"rsa-fixture.invalid",rfb::SecurityClient({type}));
    if (malformed) {
      const auto deadline=steady_clock::now()+seconds(4);
      while (worker->events()->snapshot().state != SessionState::Failed && steady_clock::now()<deadline) std::this_thread::sleep_for(milliseconds(1));
      EXPECT_EQ(worker->events()->snapshot().state,SessionState::Failed);
      EXPECT_EQ(worker->events()->snapshot().endReason,SessionEndReason::ProtocolFailure);
      AuthenticationPrompt absent; EXPECT_FALSE(worker->authentication()->takeRequest(absent));
      worker->closeAndDrain().wait(); wires.stop(); ASSERT_NO_THROW(server.get()); continue;
    }
    AuthenticationPrompt prompt; const auto deadline=steady_clock::now()+seconds(4); bool ready=false;
    while (!(ready=worker->authentication()->takeRequest(prompt)) && steady_clock::now()<deadline) std::this_thread::sleep_for(milliseconds(1));
    ASSERT_TRUE(ready); EXPECT_EQ(prompt.kind,PromptKind::HostKey);
    EXPECT_EQ(prompt.identity,std::vector<uint8_t>(std::begin(host_key_fixture),std::end(host_key_fixture)));
    EXPECT_EQ(prompt.fingerprint,host_key_fixture_compatibility);
    EXPECT_EQ(worker->authentication()->replyCredentials(prompt.id,prompt.generation,"","unused"),PromptReply::WrongKind);
    EXPECT_EQ(worker->authentication()->replyTrust(prompt.id,prompt.generation,false),PromptReply::Accepted);
    EXPECT_EQ(worker->closeAndDrain().wait_for(seconds(3)),std::future_status::ready);
    wires.stop(); ASSERT_NO_THROW(server.get());
  }
  }
}
#endif

namespace {
struct TLSFile {
  explicit TLSFile(const std::string& bytes) {
    char pattern[] = "/tmp/tidyvnc-tls-files-XXXXXX";
    Descriptor fd(::mkstemp(pattern)); require(fd.value >= 0,"TLS fixture file"); path = pattern;
    size_t offset = 0;
    while (offset < bytes.size()) {
      const auto count = ::write(fd.value,bytes.data()+offset,bytes.size()-offset);
      require(count > 0,"TLS fixture write"); offset += count;
    }
  }
  ~TLSFile() { ::unlink(path.c_str()); }
  std::string path;
};
std::string certificatePEM(gnutls_x509_crt_t certificate) {
  gnutls_datum_t data{};
  tlsCheck(gnutls_x509_crt_export2(certificate,GNUTLS_X509_FMT_PEM,&data));
  std::string result(reinterpret_cast<char*>(data.data),data.size); gnutls_free(data.data); return result;
}
struct Authority {
  Authority(Certificate& leaf) {
    tlsCheck(gnutls_x509_privkey_init(&key));
    tlsCheck(gnutls_x509_privkey_generate(key,GNUTLS_PK_RSA,2048,0));
    tlsCheck(gnutls_x509_crt_init(&certificate));
    tlsCheck(gnutls_x509_crt_set_version(certificate,3));
    const uint8_t serial = 2;
    tlsCheck(gnutls_x509_crt_set_serial(certificate,&serial,1));
    tlsCheck(gnutls_x509_crt_set_activation_time(certificate,time(nullptr)-3600));
    tlsCheck(gnutls_x509_crt_set_expiration_time(certificate,time(nullptr)+86400));
    tlsCheck(gnutls_x509_crt_set_dn(certificate,"CN=TidyVNC isolated test CA",nullptr));
    tlsCheck(gnutls_x509_crt_set_key(certificate,key));
    tlsCheck(gnutls_x509_crt_set_basic_constraints(certificate,1,-1));
    tlsCheck(gnutls_x509_crt_set_key_usage(certificate,GNUTLS_KEY_KEY_CERT_SIGN|GNUTLS_KEY_CRL_SIGN));
    tlsCheck(gnutls_x509_crt_sign2(certificate,certificate,key,GNUTLS_DIG_SHA256,0));
    tlsCheck(gnutls_x509_crt_sign2(leaf.certificate,certificate,key,GNUTLS_DIG_SHA256,0));
    gnutls_certificate_free_credentials(leaf.credentials); leaf.credentials = nullptr;
    tlsCheck(gnutls_certificate_allocate_credentials(&leaf.credentials));
    tlsCheck(gnutls_certificate_set_x509_key(leaf.credentials,&leaf.certificate,1,leaf.key));
  }
  ~Authority() { gnutls_x509_crt_deinit(certificate); gnutls_x509_privkey_deinit(key); }
  std::string crl(Certificate& leaf, bool revoked) {
    gnutls_x509_crl_t list;
    tlsCheck(gnutls_x509_crl_init(&list));
    tlsCheck(gnutls_x509_crl_set_version(list,2));
    tlsCheck(gnutls_x509_crl_set_this_update(list,time(nullptr)-60));
    tlsCheck(gnutls_x509_crl_set_next_update(list,time(nullptr)+3600));
    if (revoked) tlsCheck(gnutls_x509_crl_set_crt(list,leaf.certificate,time(nullptr)-30));
    tlsCheck(gnutls_x509_crl_sign2(list,certificate,key,GNUTLS_DIG_SHA256,0));
    gnutls_datum_t data{}; tlsCheck(gnutls_x509_crl_export2(list,GNUTLS_X509_FMT_PEM,&data));
    std::string result(reinterpret_cast<char*>(data.data),data.size);
    gnutls_free(data.data); gnutls_x509_crl_deinit(list); return result;
  }
  gnutls_x509_privkey_t key = nullptr;
  gnutls_x509_crt_t certificate = nullptr;
};
void waitForFailure(WorkerAttempt& attempt) {
  const auto deadline = steady_clock::now()+seconds(3);
  while (attempt.worker->events()->snapshot().state != SessionState::Failed && steady_clock::now() < deadline)
    std::this_thread::sleep_for(milliseconds(1));
  ASSERT_EQ(attempt.worker->events()->snapshot().state,SessionState::Failed);
  EXPECT_EQ(attempt.worker->events()->snapshot().endReason,SessionEndReason::ProtocolFailure);
  AuthenticationPrompt request;
  EXPECT_FALSE(attempt.worker->authentication()->takeRequest(request));
  auto done = attempt.worker->closeAndDrain();
  ASSERT_EQ(done.wait_for(seconds(3)),std::future_status::ready);
  ASSERT_EQ(attempt.server.wait_for(seconds(3)),std::future_status::ready);
  (void)attempt.server.get();
  EXPECT_FALSE(attempt.peer.verified);
}
}
TEST(AuthenticationTLSFiles, IncompatibleExplicitPriorityFailsBeforeCredentials)
{
  IgnoreBrokenPipe ignore;
  Certificate certificate;
  rfb::ClientTLSOptions options;
  options.priority = "NORMAL:-VERS-ALL:+VERS-TLS1.3";
  WorkerAttempt attempt(true,certificate,options);
  waitForFailure(attempt); // Independent peer permits TLS 1.2 only.
}

TEST(AuthenticationTLSFiles, SelectedCAAndCRLValidateChainBeforeCredentials)
{
  IgnoreBrokenPipe ignore;
  Certificate certificate; Authority authority(certificate);
  TLSFile ca(certificatePEM(authority.certificate)), crl(authority.crl(certificate,false));
  rfb::ClientTLSOptions options; options.requireConfiguredFiles = true;
  options.caFile = ca.path; options.crlFile = crl.path;
  WorkerAttempt attempt(true,certificate,options);
  options.caFile.clear(); options.crlFile.clear(); // Worker owns its own paths.
  const auto prompt = attempt.prompt();
  ASSERT_EQ(prompt.kind,PromptKind::Credentials); // No exception prompt for a valid chain.
  EXPECT_EQ(attempt.worker->authentication()->replyCredentials(prompt.id,prompt.generation,"","password"),PromptReply::Accepted);
  ASSERT_EQ(attempt.server.wait_for(seconds(3)),std::future_status::ready);
  EXPECT_TRUE(attempt.server.get().empty()); EXPECT_TRUE(attempt.peer.verified);
  const auto deadline = steady_clock::now()+seconds(3);
  while (attempt.worker->events()->snapshot().state != SessionState::Connected && steady_clock::now() < deadline)
    std::this_thread::sleep_for(milliseconds(1));
  EXPECT_EQ(attempt.worker->events()->snapshot().state,SessionState::Connected);
}
TEST(AuthenticationTLSFiles, RevokedCertificateCannotBeApprovedOrReachCredentials)
{
  IgnoreBrokenPipe ignore;
  Certificate certificate; Authority authority(certificate);
  TLSFile ca(certificatePEM(authority.certificate)), crl(authority.crl(certificate,true));
  rfb::ClientTLSOptions options; options.requireConfiguredFiles = true;
  options.caFile = ca.path; options.crlFile = crl.path;
  WorkerAttempt attempt(true,certificate,options);
  const auto request = attempt.prompt();
  ASSERT_EQ(request.kind,PromptKind::Certificate);
  EXPECT_NE(request.certificateStatus & GNUTLS_CERT_REVOKED,0u);
  auto auth = attempt.worker->authentication();
  EXPECT_EQ(auth->replyTrust(request.id,request.generation,true),PromptReply::PolicyRejected);
  EXPECT_EQ(attempt.worker->events()->snapshot().state,SessionState::Authenticating);
  EXPECT_EQ(auth->replyTrust(request.id,request.generation,false),PromptReply::Accepted);
  auto done = attempt.worker->closeAndDrain();
  ASSERT_EQ(done.wait_for(seconds(3)),std::future_status::ready);
  ASSERT_EQ(attempt.server.wait_for(seconds(3)),std::future_status::ready);
  (void)attempt.server.get();
  EXPECT_FALSE(attempt.peer.verified);
}
TEST(AuthenticationTLSFiles, RequiredFilesFailClosedOnMissingEmptyMalformedOrWrongKind)
{
  IgnoreBrokenPipe ignore;
  Certificate certificate; Authority authority(certificate);
  TLSFile ca(certificatePEM(authority.certificate)), crl(authority.crl(certificate,false));
  TLSFile malformed("not PEM\n"), empty(""), missing(""); ::unlink(missing.path.c_str());
  for (bool checkCA : {true,false}) {
    for (const auto& path : {malformed.path,empty.path,missing.path,checkCA ? crl.path : ca.path}) {
      SCOPED_TRACE(checkCA ? "CA" : "CRL");
      rfb::ClientTLSOptions options; options.requireConfiguredFiles = true;
      options.caFile = checkCA ? path : ca.path; options.crlFile = checkCA ? crl.path : path;
      WorkerAttempt attempt(true,certificate,options); waitForFailure(attempt);
    }
  }
  // Retained option consumers keep their warning-only load-error behavior.
  rfb::ClientTLSOptions legacy; legacy.caFile = missing.path; legacy.crlFile = malformed.path;
  WorkerAttempt attempt(true,certificate,legacy);
  const auto request = attempt.prompt(); EXPECT_EQ(request.kind,PromptKind::Certificate);
  EXPECT_EQ(attempt.worker->authentication()->replyTrust(request.id,request.generation,false),PromptReply::Accepted);
}
