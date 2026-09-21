/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/core/DesktopLayout.h>
#include <viewer/core/DesktopResampler.h>
#include <viewer/core/FramePublisher.h>
#include <viewer/core/ProtocolSession.h>
#include <viewer/core/Endpoint.h>
#include <rdr/MemInStream.h>
#include <rdr/MemOutStream.h>
#include <rfb/ClientCredentialCache.h>
#include <cassert>
#include <cstring>

int main()
{
  // Consume the actual window-independent session, including stream setup and
  // protocol version exchange, rather than a test-only CConnection subclass.
  const uint8_t version[] = "RFB 003.008\n";
  rdr::MemInStream input(version, 12);
  rdr::MemOutStream wire;
  viewer::ProtocolSession connection(rfb::SecurityClient({rfb::secTypeNone}));
  connection.start("fixture", input, wire);
  assert(connection.processMessage());
  assert(wire.length() == 12);
  connection.close();

  const auto endpoint = viewer::Endpoint::parse("Example.invalid:1");
  assert(endpoint.host() == "example.invalid" && endpoint.port() == 5901);

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

  viewer::FramePublisher publisher(1024);
  auto subscription = publisher.subscribe();
  viewer::PixelView pixels{output, sizeof(output), 2, 2, 8,
    viewer::PixelFormat::BGRA8, viewer::AlphaMode::Opaque, viewer::PixelOrigin::TopLeft};
  assert(publisher.publishFrame(1, pixels, {0, 0, 2, 2}) == viewer::PublishResult::Published);
  viewer::ViewUpdate update;
  assert(subscription->take(update) && update.frame);
  auto retained = update.frame;
  publisher.reset(2);
  assert(subscription->take(update) && !update.frame);
  assert(std::memcmp(retained->pixels.data(), source, 4) == 0);

  rfb::ClientCredentialCache credentials;
  credentials.remember(nullptr, "fixture", true);
  std::string password;
  assert(credentials.recall(nullptr, password) && password == "fixture");
  credentials.clear();
  assert(!credentials.recall(nullptr, password));
}
