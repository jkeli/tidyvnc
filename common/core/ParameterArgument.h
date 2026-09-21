/* Argument syntax extracted from Configuration.cxx.
 * Copyright (C) 2002-2005 RealVNC Ltd. All Rights Reserved.
 * Copyright 2004-2005 Cendio AB.
 * Copyright 2017 Peter Astrand <astrand@cendio.se> for Cendio AB
 * Copyright 2011-2025 Pierre Ossman for Cendio AB
 * Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
 */
#ifndef TIDYVNC_PARAMETER_ARGUMENT_H
#define TIDYVNC_PARAMETER_ARGUMENT_H
#include <core/ParameterValue.h>
#include <utility>

namespace core {
struct ParameterArgument {
  std::string name, value;
  bool hasValue = false;
};
// Lexical only: no lookup, registry mutation, escaping, IO or diagnostics.
// No '--' terminator, abbreviation, whitespace trimming or shell expansion.
// Failure leaves the output unchanged. Callers reject embedded NUL beforehand.
inline bool splitParameterArgument(const std::string& input, ParameterArgument& out) {
  const auto equal = input.find('=');
  if (equal == 0) return false;
  if ((input.empty() || input[0] != '-') && equal == std::string::npos) return false;
  ParameterArgument result;
  result.name = input.substr(0,equal);
  result.hasValue = equal != std::string::npos;
  if (result.hasValue) result.value = input.substr(equal+1);
  if (!result.name.empty() && result.name[0] == '-')
    result.name.erase(0,result.name.size() > 1 && result.name[1] == '-' ? 2 : 1);
  out = std::move(result);
  return true;
}
// A separate empty argv token is an operand, even though an empty '=value'
// enables a boolean. Share the exact token list with boolean value validation.
inline bool isSeparateBooleanArgument(const std::string& input) {
  bool ignored;
  return !input.empty() && parseBooleanValue(input,ignored);
}
}
#endif
