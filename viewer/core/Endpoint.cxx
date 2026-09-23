/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/core/Endpoint.h>
#include <network/HostPort.h>

#ifdef WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#endif

namespace {
std::string canonicalize(std::string host)
{
  // Numeric conversion never resolves DNS or maps IPv4-mapped IPv6 to IPv4.
  unsigned char bytes[16];
  char output[INET6_ADDRSTRLEN];
  const int family = host.find(':') == std::string::npos ? AF_INET : AF_INET6;
  if (inet_pton(family, host.c_str(), bytes) == 1) {
    if (!inet_ntop(family, bytes, output, sizeof(output)))
      throw viewer::EndpointError(viewer::EndpointErrorCode::InvalidHost);
    return output;
  }
  if (family == AF_INET6)
    throw viewer::EndpointError(viewer::EndpointErrorCode::InvalidHost);
  for (char& value : host) {
    if (value >= 'A' && value <= 'Z') value += 'a' - 'A';
  }
  return host;
}
}

viewer::Endpoint viewer::Endpoint::parse(const std::string& text,
                                        bool allowUnixSockets,
                                        const std::string& routeIdentity)
{
  if (text.size() > 4096 || routeIdentity.size() > 4096)
    throw EndpointError(EndpointErrorCode::TooLong);
  if (routeIdentity.find('\0') != std::string::npos)
    throw EndpointError(EndpointErrorCode::InvalidRoute);
  Endpoint result;
  result.label = text;
  result.routeID = routeIdentity;
  // Windows Unix-socket paths (DECISIONS.md D18) may use either separator.
#ifdef _WIN32
  const bool path = text.find_first_of("/\\") != std::string::npos;
#else
  const bool path = text.find('/') != std::string::npos;
#endif
  if (path) {
    if (!allowUnixSockets)
      throw EndpointError(EndpointErrorCode::UnsupportedTransport);
    if (text.find('\0') != std::string::npos)
      throw EndpointError(EndpointErrorCode::InvalidPath);
    result.kind = EndpointTransport::UnixSocket;
    result.socketPath = text;
    return result;
  }
  network::HostPort parsed;
  try {
    parsed = network::parseHostAndPort(text);
  } catch (const network::HostPortError& error) {
    switch (error.code) {
    case network::HostPortErrorCode::InvalidHost:
      throw EndpointError(EndpointErrorCode::InvalidHost);
    case network::HostPortErrorCode::UnmatchedBracket:
      throw EndpointError(EndpointErrorCode::UnmatchedBracket);
    case network::HostPortErrorCode::InvalidPort:
      throw EndpointError(EndpointErrorCode::InvalidPort);
    }
    throw;
  }
  const size_t scopeStart = parsed.host.find('%');
  if (scopeStart != std::string::npos) {
    result.ipv6Scope = parsed.host.substr(scopeStart + 1);
    parsed.host.resize(scopeStart);
    if (parsed.host.find(':') == std::string::npos || result.ipv6Scope.empty() ||
        result.ipv6Scope.find('%') != std::string::npos)
      throw EndpointError(EndpointErrorCode::InvalidHost);
  }
  result.canonicalHost = canonicalize(parsed.host);
  result.tcpPort = parsed.port;
  return result;
}

std::string viewer::Endpoint::networkHost() const
{
  return canonicalHost + (ipv6Scope.empty() ? "" : "%" + ipv6Scope);
}

bool viewer::Endpoint::operator==(const Endpoint& other) const
{
  return kind == other.kind && canonicalHost == other.canonicalHost &&
         ipv6Scope == other.ipv6Scope && tcpPort == other.tcpPort &&
         socketPath == other.socketPath && routeID == other.routeID;
}
