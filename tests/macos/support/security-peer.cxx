/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
/* Test-only loopback RFB server built from the project's own server-side
 * security handlers (rfb::SConnection, SecurityServer, SSecurityVncAuth,
 * SSecurityVeNCrypt/TLS and SSecurityRSAAES). Used by
 * tests/integration/macos-security-smoke.py to complete real security
 * handshakes against the actual native app.
 *
 *   native-security-peer [--close-after-update] <SecurityTypes> [Param=value ...]
 *
 * Parameters are applied to the core configuration (e.g. RSAKey=, X509Cert=,
 * X509Key=); VncPassword=<text> sets the obfuscated Password parameter. It listens on an ephemeral 127.0.0.1 port,
 * prints "127.0.0.1::<port>", serves one connection at a time and prints
 * "accepted", "authenticated <SecurityTypes>", "encodings <list>", "request" and
 * "closed <reason>".
 * --close-after-update drops each connection after its first update. */
#include <core/Configuration.h>
#include <core/LogWriter.h>
#include <core/Logger_stdio.h>
#include <core/Rect.h>
#include <core/string.h>
#include <rdr/FdInStream.h>
#include <rdr/FdOutStream.h>
#include <rfb/EncodeManager.h>
#include <rfb/PixelBuffer.h>
#include <rfb/SConnection.h>
#include <rfb/SMsgWriter.h>
#include <rfb/UpdateTracker.h>
#include <rfb/obfuscate.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <string>
#include <vector>

namespace {

const rfb::PixelFormat format(32, 24, false, true, 255, 255, 255, 16, 8, 0);
const char* configured = "";
bool closeAfterUpdate = false;
constexpr int width = 64, height = 48;

class Peer : public rfb::SConnection {
public:
  Peer() : SConnection(rfb::AccessDefault), framebuffer(format, width, height)
  {
    client.setDimensions(width, height);
    client.setPF(format);
    client.setName("security fixture");
    uint8_t* pixels;
    int stride;
    pixels = framebuffer.getBufferRW(framebuffer.getRect(), &stride);
    for (int y = 0; y < height; y++)
      for (int x = 0; x < width; x++) {
        uint32_t value = x < width / 2 ? 0x00ff8000 : 0x000080ff;
        memcpy(pixels + (y * stride + x) * 4, &value, 4);
      }
    framebuffer.commitBufferRW(framebuffer.getRect());
  }
  void authSuccess() override
  {
    printf("authenticated %s\n", configured);
    fflush(stdout);
  }
  void framebufferUpdateRequest(const core::Rect& r, bool incremental) override
  {
    SConnection::framebufferUpdateRequest(r, incremental);
    if (sent)
      return;
    sent = true;
    if (!manager)
      manager.reset(new rfb::EncodeManager(this));
    rfb::UpdateInfo update;
    update.changed = core::Region(framebuffer.getRect());
    manager->writeUpdate(update, &framebuffer, nullptr);
    printf("request\n");
    fflush(stdout);
  }
  bool updated() const { return sent; }
  void setEncodings(int count, const int32_t* encodings) override
  {
    SConnection::setEncodings(count, encodings);
    printf("encodings");
    for (int i = 0; i < count; i++)
      printf("%c%d", i ? ',' : ' ', encodings[i]);
    printf("\n");
    fflush(stdout);
  }
  void setDesktopSize(int, int, const rfb::ScreenSet&) override {}
  void keyEvent(uint32_t, uint32_t, bool) override {}
  void pointerEvent(const core::Point&, uint16_t) override {}

private:
  rfb::ManagedPixelBuffer framebuffer;
  std::unique_ptr<rfb::EncodeManager> manager;
  bool sent = false;
};

void serve(int fd)
{
  rdr::FdInStream in(fd);
  rdr::FdOutStream out(fd);
  Peer peer;
  try {
    peer.setStreams(&in, &out);
    peer.initialiseProtocol();
    for (;;) {
      fd_set readable;
      FD_ZERO(&readable);
      FD_SET(fd, &readable);
      struct timeval timeout = {0, 50000};
      if (select(fd + 1, &readable, nullptr, nullptr, &timeout) < 0)
        throw std::runtime_error("select failed");
      while (peer.processMsg()) {}
      // Security handlers may swap in TLS/AES streams; flush the current one.
      peer.getOutStream()->flush();
      out.flush();
      if (closeAfterUpdate && peer.updated()) {
        usleep(200000);
        printf("closing after update\n");
        break;
      }
      if (peer.state() == rfb::SConnection::RFBSTATE_CLOSING ||
          peer.state() == rfb::SConnection::RFBSTATE_INVALID)
        break;
    }
    printf("closed normally\n");
  } catch (std::exception& e) {
    printf("closed %s\n", e.what());
  }
  fflush(stdout);
  close(fd);
}

} // namespace

int main(int argc, char** argv)
{
  if (argc < 2) {
    fprintf(stderr, "usage: native-security-peer [--close-after-update] <SecurityTypes> [Param=value ...]\n");
    return 2;
  }
  if (const char* log = getenv("SECURITY_PEER_LOG")) {
    core::initStdIOLoggers();
    core::LogWriter::setLogParams(log);
  }
  if (argc > 1 && strcmp(argv[1], "--close-after-update") == 0) {
    closeAfterUpdate = true;
    argv++; argc--;
    if (argc < 2) {
      fprintf(stderr, "missing SecurityTypes\n");
      return 2;
    }
  }
  configured = argv[1];
  if (!core::Configuration::setParam("SecurityTypes", argv[1])) {
    fprintf(stderr, "invalid SecurityTypes %s\n", argv[1]);
    return 2;
  }
  for (int i = 2; i < argc; i++) {
    const char* separator = strchr(argv[i], '=');
    std::string name(argv[i], separator ? separator - argv[i] : strlen(argv[i]));
    std::string value = separator ? separator + 1 : "";
    // VncPassword=<text> is a fixture convenience: stored obfuscated as Password.
    if (name == "VncPassword") {
      std::vector<uint8_t> obfuscated = rfb::obfuscate(value.c_str());
      name = "Password"; value = core::binToHex(obfuscated.data(), obfuscated.size());
    }
    if (!separator || !core::Configuration::setParam(name.c_str(), value.c_str())) {
      fprintf(stderr, "invalid parameter %s\n", argv[i]);
      return 2;
    }
  }
  int listener = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  socklen_t length = sizeof(address);
  if (listener < 0 || bind(listener, (struct sockaddr*)&address, sizeof(address)) < 0 ||
      listen(listener, 4) < 0 || getsockname(listener, (struct sockaddr*)&address, &length) < 0) {
    perror("listen");
    return 1;
  }
  printf("127.0.0.1::%u\n", ntohs(address.sin_port));
  fflush(stdout);
  for (;;) {
    int fd = accept(listener, nullptr, nullptr);
    if (fd < 0)
      return 1;
    printf("accepted\n");
    fflush(stdout);
    serve(fd);
  }
}
