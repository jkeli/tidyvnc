/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_CONFIGURATION_LAYERS_H
#define TIDYVNC_CONFIGURATION_LAYERS_H

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

#include "EncodingOptions.h"

namespace viewer {
// The shared precedence of the viewer's configuration sources (plans/
// native-ui-winui CORE.md section 6; the macOS NativeOptionOverlay and
// NativeInvocationResolution): compiled defaults, then app defaults, then the
// selected profile, then the command line, then an explicit connection file.
// Within a layer the last assignment wins. The deprecated DotWhenNoCursor and
// FullScreenAllMonitors migrations run after every layer, so a migration flag
// set by a lower layer still applies unless a higher layer resets it, and the
// migrated fields take the flag's source and position. No IO, environment,
// display mapping, path interpretation or settings mutation.

enum class ConfigProblem { UnknownParameter, InvalidValue, InvalidSource, Unavailable, TooMany };
class ConfigError : public std::invalid_argument {
public:
  ConfigError(ConfigProblem value, uint32_t index_)
    : std::invalid_argument("Invalid configuration layer"), problem(value), index(index_) {}
  const ConfigProblem problem;
  const uint32_t index; // One-based input assignment, or zero.
};

struct ConfigAssignment {
  std::string name, value;
  OptionSource source; // Compiled, AppDefaults, Profile, CommandLine or Document.
  uint32_t position;   // Line, argument or value position within its source.
};

struct ConfigValue {
  std::string name, value; // Canonical.
  OptionSource source;
  uint32_t position;
  bool dormant; // Kept but inactive: CursorType without AlwaysCursor, monitors outside Selected mode.
};

enum class ConfigNoteKind { DotWhenNoCursor = 1, FullScreenAllMonitors = 2 };
struct ConfigNote {
  ConfigNoteKind kind;
  std::string parameter; // The field the migration set.
  OptionSource source;
  uint32_t position;
};

struct ConfigResolution {
  std::vector<ConfigValue> values; // By canonical name, ASCII order; deprecated flags included.
  std::vector<ConfigNote> notes;   // Migrations applied, in a fixed order.
};

constexpr size_t configMaximumAssignments = 16384;
ConfigResolution resolveConfiguration(const std::vector<ConfigAssignment>& assignments);
}
#endif
