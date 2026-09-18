/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/core/DesktopLayout.h>
#include <viewer/core/DesktopResampler.h>
#include <rfb/CConnection.h>
#include <rfb/ClientCredentialCache.h>
#include <network/TcpSocket.h>
#include <cassert>
#include <cstring>

// A second, headless consumer of the same target used by FLTK. Link real RFB
// connection construction/teardown and transport parsing, not just value types.
class HeadlessConnection : public rfb::CConnection {
public:
  HeadlessConnection() : CConnection(rfb::SecurityClient({rfb::secTypeNone})) {}
  void getUserPasswd(bool, std::string*, std::string*) override {}
  bool verifyCertificate(unsigned int, const uint8_t*, size_t) override { return false; }
  bool verifyHostKey(const uint8_t*, size_t, const char*) override { return false; }
  void initDone() override {}
  void bell() override {}
};

int main()
{
  HeadlessConnection connection;
  connection.setJpegAllowed(false);
  connection.close();

  std::string host;
  int port;
  network::getHostAndPort("example.invalid::5901", &host, &port);
  assert(host == "example.invalid" && port == 5901);

  DisplayMetrics metrics;
  metrics.pixelsPerUnitX = metrics.pixelsPerUnitY = 2;
  assert(metrics.valid());
  DesktopTransform transform(2, 2, 2, 2, metrics,
                             ScalingSettings::parse("100%"), ScalingSettings::Logical);
  assert(transform.backingWidth == 4 && transform.backingHeight == 4);
  const uint8_t source[] = {1, 2, 3, 255};
  uint8_t output[16] = {};
  resampleDesktop(source, 1, 1, 4, output, 8, 2, 2,
                  core::Rect(0, 0, 2, 2), ScalingSettings::Nearest);
  for (int i = 0; i < 4; ++i)
    assert(std::memcmp(output + 4*i, source, 4) == 0);

  rfb::ClientCredentialCache credentials;
  credentials.remember(nullptr, "fixture", true);
  std::string password;
  assert(credentials.recall(nullptr, password) && password == "fixture");
  credentials.clear();
  assert(!credentials.recall(nullptr, password));
}
