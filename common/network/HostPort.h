/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_HOST_PORT_H
#define TIDYVNC_HOST_PORT_H

#include <cstdint>
#include <stdexcept>
#include <string>

namespace network {
enum class HostPortErrorCode { InvalidHost, UnmatchedBracket, InvalidPort };

class HostPortError : public std::invalid_argument {
public:
  explicit HostPortError(HostPortErrorCode value)
    : std::invalid_argument("Invalid endpoint"), code(value) {}
  const HostPortErrorCode code;
};

struct HostPort {
  std::string host;
  uint16_t port;
};

// No DNS, locale, socket initialization or global configuration. Preserves VNC
// display syntax (single colon values below 100 add basePort), bracketed hosts,
// bare IPv6 and historical double-colon ambiguities: ::1 means localhost port 1,
// and 2001::1 means host 2001 port 1. Brackets disambiguate all IPv6 literals.
// Rejects malformed/empty port suffixes and ports outside 1..65535.
HostPort parseHostAndPort(const std::string& address, int basePort = 5900);
}
#endif
