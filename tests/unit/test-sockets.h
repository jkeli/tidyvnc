/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_TEST_SOCKETS_H
#define TIDYVNC_TEST_SOCKETS_H
// Loopback socket helpers shared by the ABI tests, so the same peers run on
// POSIX and on Windows (Winsock). Descriptors stay int, as in the shared code.
#include <cstddef>
#include <cstdint>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <network/Socket.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace testsock {
#ifdef _WIN32
using length_t = int;
struct Startup { Startup() { network::initSockets(); } };
inline const Startup& startup() { static const Startup value; return value; }
inline int open(int family) {
  startup();
  const SOCKET socket = ::socket(family, SOCK_STREAM, 0);
  return socket == INVALID_SOCKET ? -1 : static_cast<int>(socket);
}
inline int closeSocket(int fd) { return ::closesocket(static_cast<SOCKET>(fd)); }
inline long long recvBytes(int fd, void* data, size_t length, int flags = 0) {
  return ::recv(static_cast<SOCKET>(fd), static_cast<char*>(data), static_cast<int>(length), flags);
}
inline long long sendBytes(int fd, const void* data, size_t length) {
  return ::send(static_cast<SOCKET>(fd), static_cast<const char*>(data), static_cast<int>(length), 0);
}
inline int readable(int fd, int timeoutMs) {
  WSAPOLLFD event{static_cast<SOCKET>(fd), POLLRDNORM, 0};
  return ::WSAPoll(&event, 1, timeoutMs);
}
#else
using length_t = socklen_t;
inline int open(int family) { return ::socket(family, SOCK_STREAM, 0); }
inline int closeSocket(int fd) { return ::close(fd); }
inline long long recvBytes(int fd, void* data, size_t length, int flags = 0) { return ::recv(fd, data, length, flags); }
inline long long sendBytes(int fd, const void* data, size_t length) { return ::send(fd, data, length, 0); }
inline int readable(int fd, int timeoutMs) { pollfd event{fd, POLLIN, 0}; return ::poll(&event, 1, timeoutMs); }
#endif
inline void shutdownBoth(int fd) {
#ifdef _WIN32
  ::shutdown(static_cast<SOCKET>(fd), SD_BOTH);
#else
  ::shutdown(fd, SHUT_RDWR);
#endif
}
inline void noDelay(int fd) {
  int one = 1;
  ::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&one), sizeof(one));
}
inline void noSigpipe(int fd) {
#ifdef SO_NOSIGPIPE
  int one = 1; ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#else
  (void)fd;
#endif
}
}
#endif
