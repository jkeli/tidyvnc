/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_SOCKET_LISTENER_H
#define TIDYVNC_SOCKET_LISTENER_H
#include <viewer/platform/ListenerSource.h>
namespace viewer {
struct SocketListenOptions {
  std::string address; // Empty: wildcard on enabled families. Otherwise numeric IPv4/IPv6.
  uint16_t port = 5500; // Zero requests an ephemeral port, shared across families.
  bool ipv4 = true, ipv6 = true;
  unsigned backlog = 16; // 1..64, separate from the core pending-peer limit.
};
// macOS/Linux TCP reverse connections. No DNS, Unix paths or tunnel routing.
// Binding happens on start(), never on the caller constructing this value.
// Unavailable address families are skipped as in the legacy viewer. Other bind
// failures roll back all sockets; at least one family must be listening.
std::unique_ptr<ListenerSource> prepareSocketListener(const SocketListenOptions& options = {});
}
#endif
