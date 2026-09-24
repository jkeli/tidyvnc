/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "ImportProjection.h"

#include <algorithm>
#include <set>

#include <core/string.h>

#include "ConnectionDocument.h"
#include "DocumentOptions.h"
#include "EncodingOptions.h"

namespace viewer {
namespace {

std::string lower(const std::string& text)
{
  std::string out = text;
  for (auto& c : out)
    if (c >= 'A' && c <= 'Z') c = char(c + 32);
  return out;
}

// Only ordinary viewing preferences may be imported. Security, trust,
// endpoints, credentials and tunnels never reach native preferences.
const std::set<std::string>& allowed()
{
  static const std::set<std::string> names = [] {
    std::set<std::string> value = {"Shared", "ReconnectOnError", "AcceptClipboard", "SendClipboard", "ViewOnly",
                                   "EmulateMiddleButton", "FullscreenSystemKeys", "ShortcutModifiers", "AlwaysCursor",
                                   "CursorType", "DotWhenNoCursor", "ScalingFactor", "ScalingQuality",
                                   "DesktopPixelUnits", "FullScreen", "FullScreenMode", "FullScreenSelectedMonitors",
                                   "FullScreenAllMonitors"};
    for (const auto& field : encodingSchema()) value.insert(field.name);
    return value;
  }();
  return names;
}

const std::set<std::string> excluded = {"servername", "securitytypes", "x509ca", "x509crl", "tlspriority", "password",
                                        "passwd", "passwordfile", "username", "user", "via", "tunnel", "security", "trust"};
const std::set<std::string> platformOnly = {"audio", "sendprimary", "setprimary"};

// One source entry: platform-only and excluded names are reported by name,
// unknown names are reported undecoded, understood names are validated even
// when excluded (a malformed known field fails the import, as the retained
// importer does), and anything else outside the allow-list is refused.
template <class Validate>
void project(DefaultsProjection& out, const std::string& name, uint32_t line, Validate validate)
{
  const auto key = lower(name);
  if (platformOnly.count(key)) { out.notices.push_back({line, name, ImportNoticeKind::PlatformOnly}); return; }
  DocumentAssignment canonical;
  const bool known = validate(canonical);
  if (excluded.count(key)) { out.notices.push_back({line, name, ImportNoticeKind::Excluded}); return; }
  if (!known) { out.notices.push_back({line, name, ImportNoticeKind::Unknown}); return; }
  if (!allowed().count(canonical.name)) throw ImportError(ImportProblem::Unrepresentable, line);
  out.assignments.push_back({canonical.name, canonical.value, line});
}

void historyEntry(HistoryProjection& out, std::set<std::string>& seen, const std::string& text, uint32_t line, size_t maximum)
{
  if (text.size() > maximum) throw ImportError(ImportProblem::LineTooLong, line);
  if (text.find('\0') != std::string::npos || !core::isValidUTF8(text.data(), text.size()))
    throw ImportError(ImportProblem::InvalidText, line);
  // Every line is validated, including duplicates and entries past capacity.
  // Whitespace, case, display/port spelling and order are kept as written.
  if (text.empty()) return;
  if (!seen.insert(text).second) { out.duplicates++; return; }
  if (out.endpoints.size() < historyCapacity) out.endpoints.push_back(text);
  else out.omittedOlder++;
}
}

DefaultsProjection projectDefaultsFile(const std::string& bytes)
{
  const auto document = ConnectionDocument::parse(bytes);
  DefaultsProjection out;
  for (const auto& entry : document.entries())
    project(out, entry.name, static_cast<uint32_t>(entry.line), [&entry](DocumentAssignment& canonical) {
      return documentOption(entry, canonical);
    });
  return out;
}

DefaultsProjection projectDefaultsValues(const std::vector<ImportValue>& values)
{
  if (values.size() > ConnectionDocument::maximumEntries) throw ImportError(ImportProblem::TooManyEntries, 0);
  DefaultsProjection out;
  for (size_t i = 0; i < values.size(); i++) {
    const auto line = static_cast<uint32_t>(i + 1);
    const auto& value = values[i];
    // Registry strings as the retained reader loads them: at most 255 bytes.
    if (value.name.empty() || value.name.size() > 255 || value.value.size() > 255)
      throw ImportError(ImportProblem::TooLarge, line);
    for (const auto* text : {&value.name, &value.value})
      if (text->find('\0') != std::string::npos || !core::isValidUTF8(text->data(), text->size()))
        throw ImportError(ImportProblem::InvalidText, line);
    project(out, value.name, line, [&value, line](DocumentAssignment& canonical) {
      try {
        return documentOptionValue({value.name, value.value}, canonical);
      } catch (const DocumentError& error) {
        throw DocumentError(error.code, line); // The value's position, as a file line.
      }
    });
  }
  return out;
}

HistoryProjection projectHistoryFile(const std::string& bytes)
{
  if (bytes.size() > historyMaximumBytes) throw ImportError(ImportProblem::TooLarge, 0);
  HistoryProjection out;
  std::set<std::string> seen;
  uint32_t line = 0;
  size_t start = 0;
  while (true) {
    const size_t end = bytes.find('\n', start);
    std::string text = bytes.substr(start, end == std::string::npos ? std::string::npos : end - start);
    if (!text.empty() && text.back() == '\r') text.pop_back();
    historyEntry(out, seen, text, ++line, historyMaximumEntryBytes);
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return out;
}

HistoryProjection projectHistoryValues(const std::vector<std::string>& entries)
{
  if (entries.size() > ConnectionDocument::maximumEntries) throw ImportError(ImportProblem::TooManyEntries, 0);
  HistoryProjection out;
  std::set<std::string> seen;
  for (size_t i = 0; i < entries.size(); i++) historyEntry(out, seen, entries[i], static_cast<uint32_t>(i + 1), 255);
  return out;
}
}
