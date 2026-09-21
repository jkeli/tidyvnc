/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_SOCKET_CONNECTOR_H
#define TIDYVNC_SOCKET_CONNECTOR_H
#include <viewer/core/Endpoint.h>
#include <viewer/platform/ConnectionAttempt.h>

namespace viewer {
struct SocketConnectOptions {
  bool ipv4 = true, ipv6 = true;
  std::chrono::milliseconds resolveTimeout{10000};
  std::chrono::milliseconds connectTimeout{10000};
  std::chrono::milliseconds addressTimeout{2000};
};
// macOS: asynchronous system hostname resolution; macOS/Linux: numeric IPv4/v6
// (including scopes) and Unix sockets. Linux hostnames are explicitly unsupported
// until a cancellable resolver is available. Nonempty tunnel routes are rejected;
// the tunnel service must prepare its own attempt rather than silently bypass it.
// Resolves at most 16 addresses and tries each within the total connect budget.
// Timeouts must be 1..60000ms; at least one IP family must be enabled for TCP.
std::unique_ptr<ConnectionAttempt> prepareSocketConnection(
  const Endpoint& endpoint, const SocketConnectOptions& options = SocketConnectOptions());
}
#endif
