/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_LOGGING_POLICY_H
#define TIDYVNC_LOGGING_POLICY_H
#include <cstddef>
#include <stdexcept>
#include <string>
#include <vector>

namespace viewer {
enum class LoggingProblem { TooLarge, NullByte, InvalidRule, LevelOverflow,
                            UnknownWriter, UnknownTarget, InvalidCatalog };
class LoggingError : public std::invalid_argument {
public:
  LoggingError(LoggingProblem problem_, size_t entry_)
    : std::invalid_argument("Invalid logging policy"), problem(problem_), entry(entry_) {}
  const LoggingProblem problem;
  // One-based comma-separated entry, including empty entries; zero for input or
  // catalog errors. Never includes input, paths, writer names or target names.
  const size_t entry;
};
struct LoggingRule {
  std::string writer, target;
  int level;
  size_t entry;
};
struct LoggingRoute {
  std::string writer, target;
  int level;
};
// Owned startup candidate, with no registry, file, stream or environment access.
// Parsing does not authorize a destination. The host must resolve against its
// actual compiled writers and supported targets, then apply before workers start.
class LoggingPolicy {
public:
  static constexpr size_t maximumBytes = 65536;
  static LoggingPolicy parse(const std::string& value);
  const std::vector<LoggingRule>& rules() const { return entries; }
  // Returns one route per supplied writer, in catalog order. Every rule is
  // validated, even if a later wildcard overrides it. All unspecified writers
  // start disabled, matching each retained Log assignment's reset semantics.
  // Empty target disables output; names resolve case-insensitively. No partial
  // result escapes on failure. Catalogs are caller-owned startup metadata.
  // Duplicate writer names retain registry order: named rules affect the first
  // match; wildcard rules affect every node. Duplicate targets are invalid.
  std::vector<LoggingRoute> resolve(const std::vector<std::string>& writers,
                                    const std::vector<std::string>& targets) const;
private:
  std::vector<LoggingRule> entries;
};
}
#endif
