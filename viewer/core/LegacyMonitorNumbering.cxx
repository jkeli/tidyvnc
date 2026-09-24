/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "LegacyMonitorNumbering.h"

#include <algorithm>

namespace viewer {
std::vector<uint32_t> legacyMonitorOrder(const std::vector<LegacyMonitor>& monitors)
{
  if (monitors.empty()) throw MonitorNumberingError(MonitorNumberingProblem::Empty);
  if (monitors.size() > 64) throw MonitorNumberingError(MonitorNumberingProblem::TooMany);
  auto ordered = monitors;
  std::sort(ordered.begin(), ordered.end(), [](const LegacyMonitor& a, const LegacyMonitor& b) {
    return a.x != b.x ? a.x < b.x : a.y != b.y ? a.y < b.y : a.id < b.id;
  });
  std::vector<uint32_t> ids;
  for (size_t i = 0; i < ordered.size(); i++) {
    if (i > 0 && ordered[i].x == ordered[i - 1].x && ordered[i].y == ordered[i - 1].y)
      throw MonitorNumberingError(MonitorNumberingProblem::AmbiguousOrigin);
    ids.push_back(ordered[i].id);
  }
  auto unique = ids;
  std::sort(unique.begin(), unique.end());
  if (std::adjacent_find(unique.begin(), unique.end()) != unique.end())
    throw MonitorNumberingError(MonitorNumberingProblem::DuplicateId);
  return ids;
}
}
