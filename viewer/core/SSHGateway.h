/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_SSH_GATEWAY_H
#define TIDYVNC_SSH_GATEWAY_H
#include <cstdint>
#include <string>
namespace viewer {
// Strict decimal port: one or more ASCII digits, value 0..65535. No sign,
// whitespace or trailing text. Returns false without changing out on failure.
bool parseDecimalPort(const std::string& text, uint32_t& out);

// SSH gateway ("via") destination: [user@]host or ssh://[user@]host[:port].
// At most 4096 bytes without NUL; user is 1..255 bytes of [A-Za-z0-9._-]; a port
// (1..65535, default 22) is only accepted in URI form; IPv6 hosts use brackets.
// The host must parse as a TCP endpoint whose name and scope stay within the
// OpenSSH forwarding character set, and may not begin with '-' or contain a
// slash. Throws std::invalid_argument; nothing is resolved or launched.
struct SSHGateway {
  std::string host, scope;  // Endpoint host and optional IPv6 zone, exact bytes.
  std::string user;         // Empty when hasUser is false.
  bool hasUser = false, portIsExplicit = false;
  uint32_t port = 22;
  std::string canonicalURI; // ssh://[user@]host[%scope] (bracketed IPv6)[:port]
  static SSHGateway parse(const std::string& text);
};
}
#endif
