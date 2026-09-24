/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// W1.13 (plans/native-ui-winui/TODO.md): an end-to-end consumer of
// tidyvnc_viewer.dll that uses only the exported C ABI, the way the .NET
// frontend will. An in-process loopback RFB peer (independent of the core's
// protocol code) offers VncAuth, or VeNCrypt X509Vnc over TLS 1.2; the client
// connects, answers the trust and password prompts, receives a frame and
// checks its pixels, disconnects and drains the session and runtime.
#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include <tidyvnc.h>
#include <rdr/FdInStream.h>
#include <rdr/FdOutStream.h>
#include <rdr/TLSSocket.h>
#include <rfb/PixelFormat.h>
#include <rfb/SecurityClient.h>
#include <gnutls/gnutls.h>
#include <gnutls/x509.h>
#include <network/Socket.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <future>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>

using namespace std::chrono;
namespace {
void require(bool okay, const char* what) { if (!okay) throw std::runtime_error(what); }
void tls(int result) { if (result < 0) throw std::runtime_error(gnutls_strerror(result)); }
template<class T> T init() { T value{}; value.size = sizeof(T); value.version = TIDYVNC_ABI_VERSION; return value; }
template<class F> bool until(F test, seconds limit = seconds(10)) {
  const auto deadline = steady_clock::now() + limit;
  do { if (test()) return true; std::this_thread::sleep_for(milliseconds(2)); } while (steady_clock::now() < deadline);
  return test();
}
bool readable(SOCKET socket, int timeout) { WSAPOLLFD event{socket, POLLRDNORM, 0}; return ::WSAPoll(&event, 1, timeout) > 0; }

struct Certificate {
  Certificate() {
    tls(gnutls_global_init());
    tls(gnutls_x509_privkey_init(&key));
    tls(gnutls_x509_privkey_generate(key, GNUTLS_PK_ECDSA, GNUTLS_CURVE_TO_BITS(GNUTLS_ECC_CURVE_SECP256R1), 0));
    tls(gnutls_x509_crt_init(&certificate));
    tls(gnutls_x509_crt_set_version(certificate, 3));
    const uint8_t serial = 7;
    tls(gnutls_x509_crt_set_serial(certificate, &serial, 1));
    tls(gnutls_x509_crt_set_activation_time(certificate, time(nullptr) - 3600));
    tls(gnutls_x509_crt_set_expiration_time(certificate, time(nullptr) + 86400));
    tls(gnutls_x509_crt_set_dn(certificate, "CN=tidyvnc-dll-end-to-end.invalid", nullptr));
    tls(gnutls_x509_crt_set_key(certificate, key));
    tls(gnutls_x509_crt_set_subject_alt_name(certificate, GNUTLS_SAN_DNSNAME, "localhost", 9, GNUTLS_FSAN_SET));
    tls(gnutls_x509_crt_sign2(certificate, certificate, key, GNUTLS_DIG_SHA256, 0));
    tls(gnutls_certificate_allocate_credentials(&credentials));
    tls(gnutls_certificate_set_x509_key(credentials, &certificate, 1, key));
  }
  ~Certificate() {
    gnutls_certificate_free_credentials(credentials);
    gnutls_x509_crt_deinit(certificate); gnutls_x509_privkey_deinit(key);
    gnutls_global_deinit();
  }
  gnutls_x509_privkey_t key = nullptr;
  gnutls_x509_crt_t certificate = nullptr;
  gnutls_certificate_credentials_t credentials = nullptr;
};

// Independent RFB 3.8 peer: VncAuth (optionally inside VeNCrypt X509Vnc),
// ServerInit for a 2x2 desktop and one Raw update of colour (10,20,30).
class Peer {
public:
  Peer(bool encrypted_, Certificate& certificate_) : encrypted(encrypted_), certificate(certificate_) {
    network::initSockets();
    listener = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP); require(listener != INVALID_SOCKET, "listener");
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    require(::bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0, "bind");
    int length = sizeof(address);
    require(::getsockname(listener, reinterpret_cast<sockaddr*>(&address), &length) == 0, "getsockname");
    require(::listen(listener, 1) == 0, "listen");
    port = ntohs(address.sin_port);
    result = std::async(std::launch::async, [this] {
      try { run(); return std::string(); } catch (const std::exception& e) { return std::string(e.what()); }
    });
  }
  ~Peer() {
    stopping = true;
    if (result.valid()) result.wait();
    if (listener != INVALID_SOCKET) ::closesocket(listener);
  }
  std::string endpoint() const { return "127.0.0.1::" + std::to_string(port); }
  std::future<std::string> result;
  bool verified = false;
  std::atomic<bool> stopping{false}, requestSeen{false};
private:
  void run() {
    require(readable(listener, 10000), "no client");
    const SOCKET accepted = ::accept(listener, nullptr, nullptr); require(accepted != INVALID_SOCKET, "accept");
    struct Closer { SOCKET s; ~Closer() { ::closesocket(s); } } closer{accepted};
    fd = static_cast<int>(accepted);
    rdr::FdInStream rawInput(fd); rdr::FdOutStream rawOutput(fd);
    input = &rawInput; output = &rawOutput;
    deadline = steady_clock::now() + seconds(10);
    try { exchange(accepted); } catch (...) { closeTLS(); throw; }
    closeTLS();
  }
  void closeTLS() {
    if (tlsSocket) tlsSocket->shutdown();
    tlsSocket.reset();
    if (tlsSession) gnutls_deinit(tlsSession);
    tlsSession = nullptr;
  }
  void exchange(SOCKET accepted) {
    const uint8_t version[] = "RFB 003.008\n"; uint8_t received[16];
    output->writeBytes(version, 12); output->flush(); read(received, 12);
    require(!std::memcmp(version, received, 12), "version");
    const uint8_t type = encrypted ? rfb::secTypeVeNCrypt : rfb::secTypeVncAuth;
    output->writeU8(1); output->writeU8(type); output->flush();
    read(received, 1); require(received[0] == type, "security type");
    if (encrypted) {
      output->writeU8(0); output->writeU8(2); output->flush(); read(received, 2);
      require(received[0] == 0 && received[1] == 2, "VeNCrypt version");
      output->writeU8(0); output->writeU8(1); output->writeU32(rfb::secTypeX509Vnc); output->flush();
      wait([&] { return input->hasData(4); });
      require(input->readU32() == rfb::secTypeX509Vnc, "VeNCrypt subtype");
      tls(gnutls_init(&tlsSession, GNUTLS_SERVER));
      tls(gnutls_priority_set_direct(tlsSession, "NORMAL:-VERS-ALL:+VERS-TLS1.2", nullptr));
      tls(gnutls_credentials_set(tlsSession, GNUTLS_CRD_CERTIFICATE, certificate.credentials));
      tlsSocket.reset(new rdr::TLSSocket(input, output, tlsSession));
      output->writeU8(1); output->flush();
      wait([&] { return tlsSocket->handshake(); });
      input = &tlsSocket->inStream(); output = &tlsSocket->outStream();
    }
    // The DES response for "password" to this fixed challenge (see d3des.cxx).
    const uint8_t challenge[] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15};
    const uint8_t expected[] = {0xb8,0x66,0x92,0x41,0x25,0xc8,0xee,0xbb,0x9d,0xeb,0xc1,0xdb,0x61,0xc5,0x38,0xe2};
    output->writeBytes(challenge, 16); output->flush(); read(received, 16);
    verified = !std::memcmp(received, expected, 16);
    output->writeU32(verified ? 0 : 1); output->flush();
    require(verified, "password");
    read(received, 1); // ClientInit
    output->writeU16(2); output->writeU16(2);
    rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0).write(output);
    output->writeU32(4); output->writeBytes(reinterpret_cast<const uint8_t*>("peer"), 4);
    output->writeU8(0); output->pad(1); output->writeU16(1);                 // FramebufferUpdate, one rect
    output->writeU16(0); output->writeU16(0); output->writeU16(2); output->writeU16(2); output->writeU32(0); // Raw
    for (int i = 0; i < 4; ++i) { output->writeU8(30); output->writeU8(20); output->writeU8(10); output->writeU8(0); }
    output->flush();
    // Consume client messages until the client disconnects.
    while (!stopping) {
      if (!input->hasData(1)) { if (!readable(accepted, 20)) continue; }
      try { if (input->hasData(1)) { input->skip(input->avail()); requestSeen = true; } }
      catch (const rdr::end_of_stream&) { return; }
    }
  }
  template<class F> void wait(F done) {
    while (!done()) { require(steady_clock::now() < deadline, "peer deadline"); readable(static_cast<SOCKET>(fd), 5); }
  }
  void read(uint8_t* bytes, size_t size) { wait([&] { return input->hasData(size); }); input->readBytes(bytes, size); }
  bool encrypted;
  Certificate& certificate;
  SOCKET listener = INVALID_SOCKET;
  uint16_t port = 0;
  int fd = -1;
  rdr::InStream* input = nullptr;
  rdr::OutStream* output = nullptr;
  gnutls_session_t tlsSession = nullptr;
  std::unique_ptr<rdr::TLSSocket> tlsSocket;
  steady_clock::time_point deadline;
};

struct Owned {
  ~Owned() { if (id) tidyvnc_release(id, nullptr); }
  tidyvnc_handle id = 0;
};

void scenario(bool encrypted, Certificate& certificate) {
  Peer peer(encrypted, certificate);
  auto runtimeOptions = init<tidyvnc_runtime_options>();
  require(tidyvnc_runtime_options_init(&runtimeOptions, nullptr) == TIDYVNC_OK, "runtime options");
  Owned runtime, session;
  require(tidyvnc_runtime_create(&runtimeOptions, &runtime.id, nullptr) == TIDYVNC_OK, "runtime");
  auto options = init<tidyvnc_session_options>();
  require(tidyvnc_session_options_init(&options, nullptr) == TIDYVNC_OK, "session options");
  options.security_count = 1; options.security_types[0] = encrypted ? rfb::secTypeX509Vnc : rfb::secTypeVncAuth;
  const std::string priority = "NORMAL:-VERS-ALL:+VERS-TLS1.2";
  options.tls_priority = {reinterpret_cast<const uint8_t*>(priority.data()), priority.size()};
  require(tidyvnc_session_create(runtime.id, &options, &session.id, nullptr) == TIDYVNC_OK, "session");

  auto connect = init<tidyvnc_connect_options>();
  require(tidyvnc_connect_options_init(&connect, nullptr) == TIDYVNC_OK, "connect options");
  const auto endpoint = peer.endpoint();
  connect.endpoint = {reinterpret_cast<const uint8_t*>(endpoint.data()), endpoint.size()};
  auto operation = init<tidyvnc_operation>();
  require(tidyvnc_session_connect(session.id, &connect, &operation, nullptr) == TIDYVNC_OK, "connect");

  bool trusted = false, answered = false;
  require(until([&] {
    Owned prompt;
    if (tidyvnc_session_take_prompt(session.id, &prompt.id, nullptr) == TIDYVNC_OK) {
      auto info = init<tidyvnc_prompt_info>();
      require(tidyvnc_prompt_get(prompt.id, &info, nullptr) == TIDYVNC_OK, "prompt info");
      if (info.kind == TIDYVNC_PROMPT_CERTIFICATE) {
        require(encrypted && (info.certificate_status & GNUTLS_CERT_SIGNER_NOT_FOUND), "certificate prompt");
        require(tidyvnc_session_reply_trust(session.id, info.id, info.generation, 1, nullptr) == TIDYVNC_OK, "trust");
        trusted = true;
      } else if (info.kind == TIDYVNC_PROMPT_CREDENTIALS) {
        require(info.secure == (encrypted ? 1u : 0u), "credential security");
        char password[] = "password";
        tidyvnc_mutable_bytes none = {nullptr, 0}, secret = {reinterpret_cast<uint8_t*>(password), 8};
        require(tidyvnc_session_reply_credentials(session.id, info.id, info.generation, none, secret, nullptr) == TIDYVNC_OK,
                "credentials");
        require(password[0] == 0, "password wiped");
        answered = true;
      }
    }
    auto snapshot = init<tidyvnc_snapshot>();
    tidyvnc_session_snapshot(session.id, &snapshot, nullptr);
    require(snapshot.state != TIDYVNC_STATE_FAILED, "session failed");
    return snapshot.state == TIDYVNC_STATE_CONNECTED && snapshot.frames > 0;
  }), "not connected");
  require(answered && trusted == encrypted, "prompts");

  auto view = init<tidyvnc_view_update>();
  require(until([&] { return tidyvnc_session_take_view(session.id, &view, nullptr) == TIDYVNC_OK && view.frame; }), "no frame");
  Owned frame; frame.id = view.frame;
  Owned cursor; cursor.id = view.cursor;
  auto image = init<tidyvnc_image_info>();
  require(tidyvnc_image_get(frame.id, &image, nullptr) == TIDYVNC_OK, "image");
  require(image.width == 2 && image.height == 2 && image.pixels.length >= 16, "frame size");
  const uint8_t* pixels = image.pixels.data;
  const bool bgra = image.format == TIDYVNC_PIXEL_BGRA8;
  require(pixels[bgra ? 2 : 0] == 10 && pixels[1] == 20 && pixels[bgra ? 0 : 2] == 30, "frame pixels");

  auto disconnect = init<tidyvnc_operation>();
  require(tidyvnc_session_disconnect(session.id, operation.generation, &disconnect, nullptr) == TIDYVNC_OK, "disconnect");
  require(until([&] {
    auto snapshot = init<tidyvnc_snapshot>(); tidyvnc_session_snapshot(session.id, &snapshot, nullptr);
    return snapshot.state == TIDYVNC_STATE_CLOSED;
  }), "not closed");
  require(tidyvnc_session_close(session.id, nullptr) == TIDYVNC_OK, "close");
  require(until([&] { return tidyvnc_session_poll_drained(session.id, nullptr) == TIDYVNC_OK; }), "session drain");
  require(tidyvnc_runtime_shutdown(runtime.id, nullptr) == TIDYVNC_OK, "shutdown");
  require(until([&] { return tidyvnc_runtime_poll_drained(runtime.id, nullptr) == TIDYVNC_OK; }), "runtime drain");
  peer.stopping = true;
  require(peer.result.wait_for(seconds(5)) == std::future_status::ready, "peer finished");
  const auto failure = peer.result.get();
  require(failure.empty(), failure.c_str());
  require(peer.verified, "peer verified");
}
}

int main()
{
  try {
    Certificate certificate;
    scenario(false, certificate);
    std::puts("VncAuth through tidyvnc_viewer.dll: connected, frame received, disconnected, drained");
    scenario(true, certificate);
    std::puts("X509Vnc (TLS 1.2) through tidyvnc_viewer.dll: trusted, connected, frame received, drained");
    return 0;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "End-to-end failure: %s\n", error.what());
    return 1;
  }
}
