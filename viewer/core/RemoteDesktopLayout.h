/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_REMOTE_DESKTOP_LAYOUT_H
#define TIDYVNC_REMOTE_DESKTOP_LAYOUT_H
#include <cstdint>
#include <vector>

namespace viewer {
struct RemoteScreen {
  uint32_t id, x, y, width, height, flags;
};
// Immutable validated RFB desktop geometry, in remote pixels. No local display
// or OS identity is implied. IDs and flags are preserved; gaps/overlap are legal
// as in ScreenSet. Owns 1..255 screens enclosed by a 1..65535 pixel framebuffer.
class RemoteDesktopLayout {
public:
  RemoteDesktopLayout(uint32_t width, uint32_t height, std::vector<RemoteScreen> screens);
  uint32_t width() const { return desktopWidth; }
  uint32_t height() const { return desktopHeight; }
  const std::vector<RemoteScreen>& screens() const { return values; }
private:
  const uint32_t desktopWidth, desktopHeight;
  const std::vector<RemoteScreen> values;
};
}
#endif
