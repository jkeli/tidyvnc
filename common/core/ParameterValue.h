/* Boolean syntax extracted from Configuration.cxx.
 * Copyright (C) 2002-2005 RealVNC Ltd. All Rights Reserved.
 * Copyright 2004-2005 Cendio AB.
 * Copyright 2017 Peter Astrand <astrand@cendio.se> for Cendio AB
 * Copyright 2011-2025 Pierre Ossman for Cendio AB
 * Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
 */
#ifndef TIDYVNC_PARAMETER_VALUE_H
#define TIDYVNC_PARAMETER_VALUE_H
#include <string>
#include <cstring>
namespace core {
inline bool asciiParameterEqual(const std::string& value, const char* expected) {
  if (value.size() != std::strlen(expected)) return false;
  const auto lower = [](unsigned char c) { return c >= 'A' && c <= 'Z' ? c + ('a'-'A') : c; };
  for (size_t i = 0; i < value.size(); ++i) if (lower(value[i]) != lower(expected[i])) return false;
  return true;
}
// Exact legacy boolean tokens; empty means enabled, whitespace is not trimmed.
// Failure leaves the caller's output unchanged. No registry access or logging.
inline bool parseBooleanValue(const std::string& value, bool& out) {
  if (value.empty() || asciiParameterEqual(value,"1") || asciiParameterEqual(value,"on") ||
      asciiParameterEqual(value,"true") || asciiParameterEqual(value,"yes")) { out = true; return true; }
  if (asciiParameterEqual(value,"0") || asciiParameterEqual(value,"off") ||
      asciiParameterEqual(value,"false") || asciiParameterEqual(value,"no")) { out = false; return true; }
  return false;
}
}
#endif
