/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_SOCKET_TRANSPORT_H
#define TIDYVNC_SOCKET_TRANSPORT_H

#include <memory>
#include <viewer/platform/SessionTransport.h>

namespace network { class Socket; }
namespace viewer {
// macOS/Linux adapter boundary, separate from the portable transport contract.
// Takes exclusive ownership of an established TCP/Unix stream socket, including
// on failure. No other thread may access the socket. Sets nonblocking/CLOEXEC.
// Invalid/unconnected/listening or select-incompatible sockets are rejected.
// DNS/connect/listen policy belongs to the host, not this established transport.
std::unique_ptr<SessionTransport>
adoptSocketTransport(std::unique_ptr<network::Socket> socket);
}
#endif
