/* Configuration syntax extracted from vncviewer/parameters.cxx.
 * Copyright (C) 2002-2005 RealVNC Ltd. All Rights Reserved.
 * Copyright 2011 Pierre Ossman <ossman@cendio.se> for Cendio AB
 * Copyright 2012 Samuel Mannehed <samuel@cendio.se> for Cendio AB
 * Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
 */
#include "ConnectionDocument.h"
#include <cstring>

using namespace viewer;
namespace {
const char* message(DocumentErrorCode code) {
  switch (code) {
  case DocumentErrorCode::Empty: return "Empty configuration file";
  case DocumentErrorCode::InvalidHeader: return "Invalid configuration file header";
  case DocumentErrorCode::NullByte: return "Configuration file contains a null byte";
  case DocumentErrorCode::LineTooLong: return "Configuration line too long";
  case DocumentErrorCode::InvalidAssignment: return "Invalid configuration assignment";
  case DocumentErrorCode::InvalidEscape: return "Invalid configuration escape";
  case DocumentErrorCode::TooLarge: return "Configuration file too large";
  case DocumentErrorCode::TooManyEntries: return "Too many configuration entries";
  case DocumentErrorCode::InvalidExportName: return "Unsupported configuration export field";
  case DocumentErrorCode::InvalidValue: return "Invalid configuration value";
  case DocumentErrorCode::Unavailable: return "Unavailable configuration value";
  }
  return "Invalid configuration file";
}
bool equalASCII(const std::string& lhs, const char* rhs) {
  if (lhs.size() != std::strlen(rhs)) return false;
  for (size_t i = 0; i < lhs.size(); ++i) {
    const auto lower = [](unsigned char c) { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c; };
    if (lower(lhs[i]) != lower(rhs[i])) return false;
  }
  return true;
}
}
DocumentError::DocumentError(DocumentErrorCode reason, size_t lineNumber)
  : std::invalid_argument(message(reason)), code(reason), line(lineNumber) {}

const char* ConnectionDocument::header() { return "TidyVNC Configuration file Version 1.0"; }
const char* ConnectionDocument::legacyHeader() { return "TigerVNC Configuration file Version 1.0"; }

ConnectionDocument ConnectionDocument::parse(const std::string& bytes) {
  if (bytes.size() > maximumBytes) throw DocumentError(DocumentErrorCode::TooLarge);
  if (bytes.empty()) throw DocumentError(DocumentErrorCode::Empty);
  ConnectionDocument result;
  size_t start = 0, lineNumber = 0;
  while (start < bytes.size()) {
    ++lineNumber;
    auto end = bytes.find('\n', start);
    end = end == std::string::npos ? bytes.size() : end + 1;
    if (end - start > maximumLineBytes) throw DocumentError(DocumentErrorCode::LineTooLong, lineNumber);
    auto line = bytes.substr(start, end - start);
    start = end;
    if (line.find('\0') != std::string::npos) throw DocumentError(DocumentErrorCode::NullByte, lineNumber);
    if (lineNumber == 1) {
      while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) line.pop_back();
      if (line != header() && line != legacyHeader()) throw DocumentError(DocumentErrorCode::InvalidHeader, 1);
      result.legacy = line == legacyHeader();
      continue;
    }
    if (line[0] == '#' || line[0] == '\n' || line[0] == '\r') continue;
    if (line.back() == '\n') line.pop_back();
    if (!line.empty() && line.back() == '\r') line.pop_back();
    const auto separator = line.find('=');
    if (separator == std::string::npos) throw DocumentError(DocumentErrorCode::InvalidAssignment, lineNumber);
    if (result.fields.size() == maximumEntries) throw DocumentError(DocumentErrorCode::TooManyEntries, lineNumber);
    result.fields.push_back({line.substr(0, separator), line.substr(separator + 1), lineNumber});
  }
  return result;
}

std::string DocumentEntry::value() const {
  try { return ConnectionDocument::decodeValue(encodedValue); }
  catch (const DocumentError& error) { throw DocumentError(error.code, line); }
}

std::string ConnectionDocument::decodeValue(const std::string& value) {
  if (value.size() > 255) throw DocumentError(DocumentErrorCode::LineTooLong);
  std::string result;
  for (size_t i = 0; i < value.size(); ++i) {
    char c = value[i];
    if (c == '\0') throw DocumentError(DocumentErrorCode::NullByte);
    if (c == '\\') {
      if (++i == value.size()) throw DocumentError(DocumentErrorCode::InvalidEscape);
      switch (value[i]) {
      case 'n': c = '\n'; break;
      case 'r': c = '\r'; break;
      case '\\': c = '\\'; break;
      default: throw DocumentError(DocumentErrorCode::InvalidEscape);
      }
    }
    result += c;
  }
  return result;
}

std::string ConnectionDocument::encodeValue(const std::string& value) {
  if (value.size() > 255) throw DocumentError(DocumentErrorCode::LineTooLong);
  std::string result;
  for (char c : value) {
    switch (c) {
    case '\0': throw DocumentError(DocumentErrorCode::NullByte);
    case '\n': result += "\\n"; break;
    case '\r': result += "\\r"; break;
    case '\\': result += "\\\\"; break;
    default: result += c;
    }
    if (result.size() > 255) throw DocumentError(DocumentErrorCode::LineTooLong);
  }
  return result;
}

const char* ConnectionDocument::exportName(const std::string& name) {
  // This is a file-format catalog, independent of platform/compiled support.
  // The frontend still validates values and filters unavailable options.
  static const char* const names[] = {
    "ServerName", "X509CA", "X509CRL", "SecurityTypes", "ReconnectOnError", "Shared", "Audio",
    "AutoSelect", "FullColor", "LowColorLevel", "PreferredEncoding", "CustomCompressLevel",
    "CompressLevel", "NoJPEG", "QualityLevel", "ScalingFactor", "ScalingQuality", "DesktopPixelUnits",
    "FullScreen", "FullScreenMode", "FullScreenSelectedMonitors", "ViewOnly", "EmulateMiddleButton",
    "AlwaysCursor", "CursorType", "AcceptClipboard", "SendClipboard", "SendPrimary", "SetPrimary",
    "FullscreenSystemKeys", "ShortcutModifiers"
  };
  for (const auto* candidate : names) if (equalASCII(name, candidate)) return candidate;
  return nullptr;
}

std::string ConnectionDocument::serialize(const std::vector<DocumentAssignment>& values) {
  if (values.size() > maximumEntries) throw DocumentError(DocumentErrorCode::TooManyEntries);
  std::string result = std::string(header()) + "\n\n";
  for (const auto& field : values) {
    const auto* name = exportName(field.name);
    if (!name) throw DocumentError(DocumentErrorCode::InvalidExportName);
    auto line = std::string(name) + "=" + encodeValue(field.value) + "\n";
    if (line.size() > maximumLineBytes) throw DocumentError(DocumentErrorCode::LineTooLong);
    if (line.size() > maximumBytes - result.size()) throw DocumentError(DocumentErrorCode::TooLarge);
    result += line;
  }
  return result;
}
