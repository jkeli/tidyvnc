/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "RemoteDesktopLayout.h"
#include <stdexcept>
#include <utility>

namespace viewer {
RemoteDesktopLayout::RemoteDesktopLayout(uint32_t width, uint32_t height,
                                       std::vector<RemoteScreen> screens)
  : desktopWidth(width), desktopHeight(height), values(std::move(screens))
{
  if (!width || !height || width > 65535 || height > 65535 || values.empty() || values.size() > 255)
    throw std::invalid_argument("Invalid remote desktop layout");
  for (size_t i = 0; i < values.size(); ++i) {
    const auto& screen = values[i];
    if (!screen.width || !screen.height || screen.x > width || screen.y > height ||
        screen.width > width - screen.x || screen.height > height - screen.y)
      throw std::invalid_argument("Remote screen outside desktop");
    for (size_t previous = 0; previous < i; ++previous)
      if (values[previous].id == screen.id)
        throw std::invalid_argument("Duplicate remote screen identity");
  }
}
}
