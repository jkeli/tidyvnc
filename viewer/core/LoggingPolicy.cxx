/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "LoggingPolicy.h"
#include <climits>
#include <unordered_map>
#include <utility>

using namespace viewer;
namespace {
bool space(char c) { return c == ' ' || c == '\f' || c == '\n' || c == '\r' || c == '\t' || c == '\v'; }
int level(const std::string& text, size_t entry) {
  // Preserve defined atoi behavior: decimal prefix, optional sign, leading C
  // whitespace, no digits -> zero and ignored suffix. Overflow is undefined in
  // atoi; reject it here without calling a global parameter or logging input.
  size_t i = 0;
  while (i < text.size() && space(text[i])) ++i;
  const bool negative = i < text.size() && text[i] == '-';
  if (i < text.size() && (text[i] == '-' || text[i] == '+')) ++i;
  const unsigned limit = negative ? static_cast<unsigned>(INT_MAX)+1u : INT_MAX;
  unsigned value = 0;
  while (i < text.size() && text[i] >= '0' && text[i] <= '9') {
    const unsigned digit = text[i++]-'0';
    if (value > (limit-digit)/10) throw LoggingError(LoggingProblem::LevelOverflow,entry);
    value = value*10+digit;
  }
  if (!negative) return static_cast<int>(value);
  if (value == static_cast<unsigned>(INT_MAX)+1u) return INT_MIN;
  return -static_cast<int>(value);
}
std::string key(std::string name) {
  for (auto& c : name) if (c >= 'A' && c <= 'Z') c += 'a'-'A';
  return name;
}
using Catalog = std::unordered_map<std::string,size_t>;
Catalog catalog(const std::vector<std::string>& names, bool duplicateWriters = false) {
  Catalog result;
  for (size_t i = 0; i < names.size(); ++i) {
    const auto& name = names[i];
    if (name.empty() || name == "*" || name.find_first_of(std::string(",:\0",3)) != std::string::npos)
      throw LoggingError(LoggingProblem::InvalidCatalog,0);
    // Shared client/server objects can both register e.g. TLS. Legacy named
    // lookup selects the first node, while wildcard rules still affect both.
    if (!result.emplace(key(name),i).second && !duplicateWriters)
      throw LoggingError(LoggingProblem::InvalidCatalog,0);
  }
  return result;
}
}

LoggingPolicy LoggingPolicy::parse(const std::string& value) {
  if (value.size() > maximumBytes) throw LoggingError(LoggingProblem::TooLarge,0);
  if (value.find('\0') != std::string::npos) throw LoggingError(LoggingProblem::NullByte,0);
  LoggingPolicy result;
  size_t start = 0, entry = 1;
  while (start <= value.size()) {
    const auto end = value.find(',',start);
    auto item = value.substr(start,end == std::string::npos ? end : end-start);
    const auto first = item.find_first_not_of(" \f\n\r\t\v");
    if (first != std::string::npos) {
      item = item.substr(first,item.find_last_not_of(" \f\n\r\t\v")-first+1);
      const auto a = item.find(':');
      const auto b = a == std::string::npos ? a : item.find(':',a+1);
      if (b == std::string::npos || item.find(':',b+1) != std::string::npos)
        throw LoggingError(LoggingProblem::InvalidRule,entry);
      result.entries.push_back({item.substr(0,a),item.substr(a+1,b-a-1),level(item.substr(b+1),entry),entry});
    }
    if (end == std::string::npos) break;
    start = end+1; ++entry;
  }
  return result;
}

std::vector<LoggingRoute> LoggingPolicy::resolve(const std::vector<std::string>& writers,
                                                const std::vector<std::string>& targets) const {
  const auto writerIndex = catalog(writers,true), targetIndex = catalog(targets);
  std::vector<LoggingRoute> result;
  result.reserve(writers.size());
  for (const auto& writer : writers) result.push_back({writer,"",0});
  for (const auto& rule : entries) {
    std::string target;
    if (!rule.target.empty()) {
      const auto found = targetIndex.find(key(rule.target));
      if (found == targetIndex.end()) throw LoggingError(LoggingProblem::UnknownTarget,rule.entry);
      target = targets[found->second];
    }
    if (rule.writer == "*") {
      for (auto& route : result) { route.target = target; route.level = rule.level; }
    } else {
      const auto found = writerIndex.find(key(rule.writer));
      if (found == writerIndex.end()) throw LoggingError(LoggingProblem::UnknownWriter,rule.entry);
      auto& route = result[found->second]; route.target = std::move(target); route.level = rule.level;
    }
  }
  return result;
}
