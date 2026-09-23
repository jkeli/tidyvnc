/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_DESKTOP_SIZE_H
#define TIDYVNC_DESKTOP_SIZE_H
#include <cstdint>
#include <string>
namespace viewer {
// DesktopSize ("initial remote size") grammars. Both accept empty as "no explicit
// size" and bound each dimension to 1..65535 remote pixels.
//  Legacy: the retained command-line sscanf("%dx%d") form with checked arithmetic:
//          optional C whitespace and '+' before each number, lowercase 'x', and
//          ignored trailing text. Signs other than '+' are rejected.
//  Strict: native settings/profiles: exactly decimal WxH, at most 32 bytes.
enum class DesktopSizeSyntax { Legacy = 1, Strict = 2 };
struct DesktopSize {
  uint32_t width = 0, height = 0; // Both zero means no explicit size.
  bool empty() const { return width == 0; }
  std::string text() const; // Canonical "WxH", or empty.
  // Throws std::invalid_argument for malformed or out-of-range input.
  static DesktopSize parse(const std::string& value, DesktopSizeSyntax syntax);
};
}
#endif
