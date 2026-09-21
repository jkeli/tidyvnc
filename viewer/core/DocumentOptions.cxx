/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "DocumentOptions.h"
#include <viewer/core/EncodingOptions.h>
#include <viewer/core/SecurityOptions.h>
#include <viewer/core/DesktopTransform.h>
#include <core/ParameterValue.h>
#include <cerrno>
#include <climits>
#include <cstdlib>

using namespace viewer;
namespace {
std::vector<std::string> list(const std::string& input) {
  std::vector<std::string> result;
  size_t start = 0;
  do {
    const auto comma = input.find(',',start);
    auto entry = input.substr(start,comma == std::string::npos ? comma : comma-start);
    const auto first = entry.find_first_not_of(" \f\n\r\t\v");
    entry = first == std::string::npos ? "" : entry.substr(first,entry.find_last_not_of(" \f\n\r\t\v")-first+1);
    if (entry.empty()) {
      if (!start && comma == std::string::npos) return {};
      throw DocumentError(DocumentErrorCode::InvalidValue);
    }
    result.push_back(entry);
    if (comma == std::string::npos) break;
    start = comma+1;
  } while (true);
  return result;
}
std::string choice(const std::string& value, std::initializer_list<const char*> choices) {
  for (auto* candidate : choices) if (core::asciiParameterEqual(value,candidate)) return candidate;
  throw DocumentError(DocumentErrorCode::InvalidValue);
}
}
bool viewer::documentOptionValue(const DocumentAssignment& entry, DocumentAssignment& out) {
  const char* name = ConnectionDocument::exportName(entry.name);
  if (!name) {
    for (auto* old : {"FullScreenAllMonitors","DotWhenNoCursor"})
      if (core::asciiParameterEqual(entry.name,old)) name = old;
  }
  if (!name) return false;
  const auto& value = entry.value;
  try {
    std::string canonical = value;
    const std::string key(name);
    bool handled = false;
    for (const auto& schema : encodingSchema()) {
      if (key != schema.name) continue;
      canonical = EncodingOptions().withPatch({{key,value}},OptionSource::Session).value(schema.id);
      handled = true; break;
    }
    if (!handled) {
      if (key == "ServerName" || key == "X509CA" || key == "X509CRL") {}
      else if (key == "SecurityTypes") canonical = SecuritySelection(value).text();
      else if (key == "ScalingFactor") canonical = ScalingSettings::parse(value).serialize();
      else if (key == "ScalingQuality") canonical = choice(value,{"Nearest","Bilinear","Area"});
      else if (key == "DesktopPixelUnits") canonical = choice(value,{"Logical","Device"});
      else if (key == "FullScreenMode") canonical = choice(value,{"Current","Selected","All"});
      else if (key == "CursorType") canonical = choice(value,{"Dot","System"});
      else if (key == "ShortcutModifiers") {
        unsigned mask = 0;
        for (const auto& item : list(value)) {
          const auto modifier = choice(item,{"Ctrl","Shift","Alt","Super","Win","Option","Cmd"});
          if (modifier == "Ctrl") mask |= 1;
          else if (modifier == "Shift") mask |= 2;
          else if (modifier == "Alt" || modifier == "Option") mask |= 4;
          else mask |= 8;
        }
        canonical.clear();
        const char* names[] = {"Ctrl","Shift","Alt","Super"};
        for (unsigned i = 0; i < 4; ++i) if (mask & (1u << i)) {
          if (!canonical.empty()) canonical += ',';
          canonical += names[i];
        }
      } else if (key == "FullScreenSelectedMonitors") {
        canonical.clear();
        for (const auto& item : list(value)) {
          char* end; errno = 0; const auto index = std::strtol(item.c_str(),&end,0);
          if (errno == ERANGE || *end || index < 1 || index > INT_MAX) throw DocumentError(DocumentErrorCode::InvalidValue);
          if (!canonical.empty()) canonical += ',';
          canonical += std::to_string(index);
        }
      } else {
        bool flag;
        if (!core::parseBooleanValue(value,flag)) throw DocumentError(DocumentErrorCode::InvalidValue);
        canonical = flag ? "on" : "off";
      }
    }
    out = {name,std::move(canonical)};
    return true;
  } catch (const DocumentError& error) { throw DocumentError(error.code); }
  catch (const OptionError& error) {
    throw DocumentError(error.code == OptionErrorCode::Unsupported ? DocumentErrorCode::Unavailable : DocumentErrorCode::InvalidValue);
  } catch (const SecurityOptionError& error) {
    throw DocumentError(error.problem == SecurityOptionProblem::Unavailable ? DocumentErrorCode::Unavailable : DocumentErrorCode::InvalidValue);
  } catch (const std::invalid_argument&) { throw DocumentError(DocumentErrorCode::InvalidValue); }
}

bool viewer::documentOption(const DocumentEntry& entry, DocumentAssignment& out) {
  // Unknown values remain opaque, including future escapes.
  const auto name = ConnectionDocument::exportName(entry.name);
  if (!name && !core::asciiParameterEqual(entry.name,"FullScreenAllMonitors") &&
      !core::asciiParameterEqual(entry.name,"DotWhenNoCursor")) return false;
  try { return documentOptionValue({entry.name,entry.value()},out); }
  catch (const DocumentError& error) { throw DocumentError(error.code,entry.line); }
}
