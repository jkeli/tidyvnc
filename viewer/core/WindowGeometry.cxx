/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/core/WindowGeometry.h>
#include <climits>
#include <stdexcept>
namespace viewer {
namespace {
class Scanner {
public:
  explicit Scanner(const std::string& input_) : input(input_) {}
  bool literal(char value) {
    if (position == input.size() || input[position] != value) return false;
    ++position; return true;
  }
  bool integer(int32_t& result) {
    while (position < input.size() && (input[position] == ' ' ||
           (input[position] >= '\t' && input[position] <= '\r'))) ++position;
    const bool negative = literal('-');
    if (!negative) literal('+');
    const auto start = position; uint64_t magnitude = 0;
    const uint64_t maximum = negative ? uint64_t(INT32_MAX)+1 : INT32_MAX;
    while (position < input.size() && input[position] >= '0' && input[position] <= '9') {
      magnitude = magnitude * 10 + unsigned(input[position++] - '0');
      if (magnitude > maximum) throw std::invalid_argument("Window geometry integer out of range");
    }
    if (position == start) return false;
    result = static_cast<int32_t>(negative ? -static_cast<int64_t>(magnitude) : static_cast<int64_t>(magnitude));
    return true;
  }
private:
  const std::string& input;
  size_t position = 0;
};
}
WindowGeometry WindowGeometry::parse(const std::string& input) {
  WindowGeometry result;
  if (input.empty()) return result;
  if (input.size() > 65536 || input.find('\0') != std::string::npos)
    throw std::invalid_argument("Invalid window geometry text");
  Scanner position(input);
  if (position.literal('+') && position.integer(result.x) && position.literal('+') && position.integer(result.y)) {
    result.hasPosition = true; return result;
  }
  result = {};
  Scanner dimensions(input);
  if (!dimensions.integer(result.width) || !dimensions.literal('x') || !dimensions.integer(result.height) ||
      result.width <= 0 || result.height <= 0)
    throw std::invalid_argument("Invalid window geometry dimensions");
  result.hasSize = true;
  if (dimensions.literal('+') && dimensions.integer(result.x)) {
    if (!dimensions.literal('+') || !dimensions.integer(result.y))
      throw std::invalid_argument("Incomplete window geometry position");
    result.hasPosition = true;
  }
  return result;
}
}
