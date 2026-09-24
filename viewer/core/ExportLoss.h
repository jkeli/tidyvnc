/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_EXPORT_LOSS_H
#define TIDYVNC_EXPORT_LOSS_H

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace viewer {
// What a compatibility connection file (.tidyvnc, the retained viewer's format)
// cannot carry from a native configuration, as the macOS
// NativeDocumentExport reports it (plans/native-ui-winui CORE.md section 6).
// Bits are stable ABI values.
enum class ExportLoss : uint32_t {
  FailureAlerts = 1u << 0,   // AlertOnFatalError
  RemoteResize = 1u << 1,    // RemoteResize
  NetworkFamilies = 1u << 2, // UseIPv4, UseIPv6
  PointerTiming = 1u << 3,   // PointerEventInterval
  ClipboardLimit = 1u << 4,  // MaxCutText
  WindowPlacement = 1u << 5, // geometry, Maximize (initial window size, position, maximization)
  DisplayIdentity = 1u << 6, // Selected displays become monitor numbers
  IgnoredInput = 1u << 7,    // Fields ignored when the original file was opened
  SshGateway = 1u << 8,      // via
};

enum class ExportProblem { SecurityPolicy };
class ExportError : public std::invalid_argument {
public:
  explicit ExportError(ExportProblem value) : std::invalid_argument("Configuration cannot be exported"), problem(value) {}
  const ExportProblem problem;
};

struct ExportRequest {
  bool selectedDisplays = false; // Fullscreen selects specific displays.
  bool ignoredInput = false;     // The source file had fields that were ignored.
  bool sshGateway = false;       // A gateway is configured.
  std::string tlsPriority;       // Non-empty cannot be preserved: export is refused.
};

struct ExportLossInfo {
  ExportLoss loss;
  const char* name;       // Stable key (the macOS enumeration case).
  const char* parameters; // Comma-separated canonical parameters, or empty.
};

// Losses every export has (the format has no field for them; even built-in
// values may differ from the receiving viewer's preferences), plus those the
// request adds. Throws ExportError when the configuration cannot be exported.
uint32_t exportLosses(const ExportRequest& request);
const std::vector<ExportLossInfo>& exportLossCatalog();
}
#endif
