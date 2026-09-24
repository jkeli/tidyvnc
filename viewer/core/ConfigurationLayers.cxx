/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "ConfigurationLayers.h"

#include <algorithm>
#include <map>

#include "Invocation.h"

namespace viewer {
namespace {
int precedence(OptionSource source)
{
  switch (source) {
  case OptionSource::Compiled: return 0;
  case OptionSource::AppDefaults: return 1;
  case OptionSource::Profile: return 2;
  case OptionSource::CommandLine: return 3;
  case OptionSource::Document: return 4;
  default: return -1; // Session changes are live edits, not a startup layer.
  }
}
}

ConfigResolution resolveConfiguration(const std::vector<ConfigAssignment>& assignments)
{
  if (assignments.size() > configMaximumAssignments) throw ConfigError(ConfigProblem::TooMany, 0);
  struct Candidate { ConfigValue value; int layer; size_t order; };
  std::vector<Candidate> candidates;
  candidates.reserve(assignments.size());
  for (size_t i = 0; i < assignments.size(); i++) {
    const auto index = static_cast<uint32_t>(i + 1);
    const auto& input = assignments[i];
    const int layer = precedence(input.source);
    if (layer < 0) throw ConfigError(ConfigProblem::InvalidSource, index);
    ConfigValue value{"", "", input.source, input.position, false};
    try {
      if (!canonicalParameter(input.name, input.value, value.name, value.value))
        throw ConfigError(ConfigProblem::UnknownParameter, index);
    } catch (const InvocationError& error) {
      throw ConfigError(error.problem == InvocationProblem::Unavailable ? ConfigProblem::Unavailable : ConfigProblem::InvalidValue, index);
    }
    candidates.push_back({std::move(value), layer, i});
  }
  // Precedence, then source order: the last assignment of the highest layer wins.
  std::stable_sort(candidates.begin(), candidates.end(), [](const Candidate& a, const Candidate& b) { return a.layer < b.layer; });
  std::map<std::string, ConfigValue> effective;
  for (auto& candidate : candidates) effective[candidate.value.name] = candidate.value;

  ConfigResolution result;
  const auto on = [&effective](const char* name) {
    const auto found = effective.find(name);
    return found != effective.end() && found->second.value == "on";
  };
  // DotWhenNoCursor=on means a visible dot: AlwaysCursor on, CursorType Dot.
  if (on("DotWhenNoCursor")) {
    const auto& flag = effective.at("DotWhenNoCursor");
    effective["AlwaysCursor"] = {"AlwaysCursor", "on", flag.source, flag.position, false};
    effective["CursorType"] = {"CursorType", "Dot", flag.source, flag.position, false};
    result.notes.push_back({ConfigNoteKind::DotWhenNoCursor, "AlwaysCursor", flag.source, flag.position});
    result.notes.push_back({ConfigNoteKind::DotWhenNoCursor, "CursorType", flag.source, flag.position});
  }
  // FullScreenAllMonitors=on selects every monitor.
  if (on("FullScreenAllMonitors")) {
    const auto& flag = effective.at("FullScreenAllMonitors");
    effective["FullScreenMode"] = {"FullScreenMode", "All", flag.source, flag.position, false};
    result.notes.push_back({ConfigNoteKind::FullScreenAllMonitors, "FullScreenMode", flag.source, flag.position});
  }
  // Values that exist but do not apply are kept for export and review.
  const auto always = effective.find("AlwaysCursor");
  if (always != effective.end() && always->second.value == "off") {
    auto shape = effective.find("CursorType");
    if (shape != effective.end()) shape->second.dormant = true;
  }
  const auto mode = effective.find("FullScreenMode");
  auto monitors = effective.find("FullScreenSelectedMonitors");
  if (monitors != effective.end() && (mode == effective.end() || mode->second.value != "Selected"))
    monitors->second.dormant = true;

  for (auto& entry : effective) result.values.push_back(std::move(entry.second));
  return result;
}
}
