/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/core/SSHGateway.h>
#include <viewer/core/Endpoint.h>
#include <algorithm>
#include <cstring>
#include <stdexcept>

using namespace viewer;
namespace {
[[noreturn]] void invalid() { throw std::invalid_argument("Invalid SSH gateway"); }
bool alphanumeric(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'); }
bool userCharacter(char c) { return alphanumeric(c) || c == '.' || c == '_' || c == '-'; }
// These bytes reach OpenSSH's colon-delimited forwarding grammar (not a shell):
// only what DNS names, numeric IPs and zones need.
bool hostCharacter(char c) { return userCharacter(c) || c == ':'; }
uint32_t gatewayPort(const std::string& text)
{
  uint32_t port;
  if (!parseDecimalPort(text, port) || port == 0) invalid();
  return port;
}
}
bool viewer::parseDecimalPort(const std::string& text, uint32_t& out)
{
  if (text.empty()) return false;
  uint32_t value = 0;
  for (char c : text) {
    if (c < '0' || c > '9') return false;
    value = value * 10 + static_cast<uint32_t>(c - '0');
    if (value > 65535) return false;
  }
  out = value;
  return true;
}
SSHGateway SSHGateway::parse(const std::string& text)
{
  if (text.empty() || text.size() > 4096 || text.find('\0') != std::string::npos) invalid();
  SSHGateway result;
  const bool uri = text.compare(0, 6, "ssh://") == 0;
  std::string destination = uri ? text.substr(6) : text;
  const auto at = destination.find('@');
  if (at != std::string::npos) {
    if (destination.find('@', at + 1) != std::string::npos) invalid();
    const auto user = destination.substr(0, at);
    if (user.empty() || user.size() > 255 || !std::all_of(user.begin(), user.end(), userCharacter)) invalid();
    result.user = user; result.hasUser = true;
    destination = destination.substr(at + 1);
  }
  std::string host = destination;
  if (!destination.empty() && destination[0] == '[') {
    const auto end = destination.find(']');
    if (end == std::string::npos) invalid();
    host = destination.substr(0, end + 1);
    const auto suffix = destination.substr(end + 1);
    if (!suffix.empty()) {
      if (!uri || suffix[0] != ':') invalid();
      result.port = gatewayPort(suffix.substr(1)); result.portIsExplicit = true;
    }
  } else if (destination.find(':') != std::string::npos) {
    if (!uri || std::count(destination.begin(), destination.end(), ':') != 1) invalid();
    const auto delimiter = destination.find(':');
    result.port = gatewayPort(destination.substr(delimiter + 1)); result.portIsExplicit = true;
    host = destination.substr(0, delimiter);
  }
  if (host.empty() || host[0] == '-' || host.find('/') != std::string::npos || host.find('\\') != std::string::npos)
    invalid();
  const auto endpoint = [&] {
    try { return Endpoint::parse(host + "::" + std::to_string(result.port), false); }
    catch (const std::invalid_argument&) { invalid(); }
  }();
  result.host = endpoint.host(); result.scope = endpoint.scope();
  if (result.host.empty() || result.host[0] == '-' ||
      !std::all_of(result.host.begin(), result.host.end(), hostCharacter) ||
      !std::all_of(result.scope.begin(), result.scope.end(), [](char c) { return c != ':' && hostCharacter(c); }))
    invalid();
  const std::string name = result.host + (result.scope.empty() ? "" : "%" + result.scope);
  const std::string forwarding = result.host.find(':') != std::string::npos ? "[" + name + "]" : name;
  result.canonicalURI = "ssh://" + (result.hasUser ? result.user + "@" : "") + forwarding +
                        (result.portIsExplicit ? ":" + std::to_string(result.port) : "");
  // Every admitted value must stay admissible after encode/decode.
  if (result.canonicalURI.size() > 4096) invalid();
  return result;
}
