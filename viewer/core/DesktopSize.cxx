/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/core/DesktopSize.h>
#include <stdexcept>

using namespace viewer;
namespace {
constexpr uint32_t maximumDimension = 65535;
[[noreturn]] void invalid() { throw std::invalid_argument("Invalid desktop size"); }
bool space(char c) { return c == ' ' || (c >= '\t' && c <= '\r'); }
bool digit(char c) { return c >= '0' && c <= '9'; }
// Accumulates decimal digits at position, rejecting values above the bound
// before they can overflow; at least one digit and a nonzero value are required.
uint32_t dimension(const std::string& value, size_t& position)
{
  const auto start = position;
  uint32_t result = 0;
  while (position < value.size() && digit(value[position])) {
    result = result * 10 + static_cast<uint32_t>(value[position] - '0');
    if (result > maximumDimension) invalid();
    ++position;
  }
  if (position == start || result == 0) invalid();
  return result;
}
}
std::string DesktopSize::text() const
{
  return empty() ? std::string() : std::to_string(width) + "x" + std::to_string(height);
}
DesktopSize DesktopSize::parse(const std::string& value, DesktopSizeSyntax syntax)
{
  DesktopSize result;
  if (value.empty()) return result;
  size_t position = 0;
  if (syntax == DesktopSizeSyntax::Legacy) {
    auto number = [&] {
      while (position < value.size() && space(value[position])) ++position;
      if (position < value.size() && value[position] == '+') ++position;
      return dimension(value, position);
    };
    result.width = number();
    if (position >= value.size() || value[position] != 'x') invalid();
    ++position;
    result.height = number(); // Trailing text is ignored, as with sscanf.
    return result;
  }
  if (syntax != DesktopSizeSyntax::Strict || value.size() > 32) invalid();
  result.width = dimension(value, position);
  if (position >= value.size() || value[position] != 'x') invalid();
  ++position;
  result.height = dimension(value, position);
  if (position != value.size()) invalid();
  return result;
}
