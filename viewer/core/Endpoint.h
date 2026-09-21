/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_ENDPOINT_H
#define TIDYVNC_ENDPOINT_H

#include <cstdint>
#include <stdexcept>
#include <string>

namespace viewer {
enum class EndpointTransport { Tcp, UnixSocket };
enum class EndpointErrorCode {
  TooLong, InvalidHost, UnmatchedBracket, InvalidPort, InvalidPath,
  InvalidRoute, UnsupportedTransport
};
class EndpointError : public std::invalid_argument {
public:
  explicit EndpointError(EndpointErrorCode value)
    : std::invalid_argument("Invalid endpoint"), code(value) {}
  const EndpointErrorCode code;
};

// An owned destination, not a resolved socket address. Parsing performs no IO.
// DNS ASCII case and numeric IP spellings normalize; aliases, DNS trailing dots,
// IPv6 scope IDs and tunnel routes remain distinct. Original text is retained.
class Endpoint {
public:
  // As in the POSIX viewer, any slash selects a Unix socket and preserves its
  // path bytes (including spaces). Hosts without a name mean localhost.
  // Hosts can disable Unix transport explicitly, independent of the build OS.
  // Text and opaque, non-secret route identity are each bounded to 4096 bytes.
  static Endpoint parse(const std::string& text, bool allowUnixSockets = true,
                        const std::string& routeIdentity = std::string());

  EndpointTransport transport() const { return kind; }
  const std::string& original() const { return label; }
  const std::string& host() const { return canonicalHost; }
  const std::string& scope() const { return ipv6Scope; }
  uint16_t port() const { return tcpPort; }
  const std::string& path() const { return socketPath; }
  const std::string& route() const { return routeID; }
  // Resolver input: canonical host plus the exact optional %scope suffix.
  std::string networkHost() const;
  // Destination equivalence excludes the user's presentation label. This is
  // not a complete credential key (authentication kind/user also belong there).
  bool operator==(const Endpoint& other) const;
  bool operator!=(const Endpoint& other) const { return !(*this == other); }

private:
  Endpoint() = default;
  EndpointTransport kind = EndpointTransport::Tcp;
  std::string label, canonicalHost, ipv6Scope, socketPath, routeID;
  uint16_t tcpPort = 0;
};
}
#endif
