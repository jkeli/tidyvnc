/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_LEGACY_MONITOR_NUMBERING_H
#define TIDYVNC_LEGACY_MONITOR_NUMBERING_H

#include <cstdint>
#include <stdexcept>
#include <vector>

namespace viewer {
enum class MonitorNumberingProblem { Empty, TooMany, DuplicateId, AmbiguousOrigin };
class MonitorNumberingError : public std::invalid_argument {
public:
  explicit MonitorNumberingError(MonitorNumberingProblem value)
    : std::invalid_argument("Invalid monitor list"), problem(value) {}
  const MonitorNumberingProblem problem;
};

struct LegacyMonitor {
  uint32_t id;  // Caller-owned token.
  int32_t x, y; // Top-left origin in the platform's desktop coordinates (Y down).
};

// The retained viewer's monitor numbers (MonitorIndicesParameter): ascending
// x, then y; number n is result[n-1]. That rule cannot tell two displays with
// the same origin apart (the retained viewer collapses exact mirrors and sorts
// the rest arbitrarily), so any shared origin is rejected rather than mapped
// to an arbitrary display (NativeDisplaySnapshot.documentMonitorOrder on
// macOS). 1..64 monitors with distinct ids.
std::vector<uint32_t> legacyMonitorOrder(const std::vector<LegacyMonitor>& monitors);
}
#endif
