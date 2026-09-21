/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_DETAIL_SOCKET_IO_H
#define TIDYVNC_DETAIL_SOCKET_IO_H
// Private POSIX implementation helpers, not a frontend/service contract.
#include <chrono>
#include <cerrno>
#include <climits>
#include <system_error>
#include <fcntl.h>
#include <unistd.h>
namespace viewer { namespace detail {
[[noreturn]] inline void fail(const char* operation, int error = errno)
{
  throw std::system_error(error, std::system_category(), operation);
}
struct Descriptor {
  explicit Descriptor(int value_ = -1) : value(value_) {}
  ~Descriptor() { if (value >= 0) ::close(value); }
  Descriptor(const Descriptor&) = delete;
  Descriptor& operator=(const Descriptor&) = delete;
  int value;
};
inline void configure(int fd, bool nonblocking)
{
  int flags = ::fcntl(fd, F_GETFD);
  if (flags < 0 || ::fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) fail("socket close-on-exec");
  if (nonblocking) {
    flags = ::fcntl(fd, F_GETFL);
    if (flags < 0 || ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) fail("socket nonblocking");
  }
}
struct WakePipe {
  WakePipe() {
    int fds[2];
    if (::pipe(fds) < 0) fail("socket wake pipe");
    read.value = fds[0]; write.value = fds[1];
    configure(read.value, true); configure(write.value, true);
  }
  void signal() noexcept {
    const char byte = 1;
    while (::write(write.value, &byte, 1) < 0 && errno == EINTR) {}
    // EAGAIN coalesces with a previous readable notification. Ownership keeps
    // both ends alive for the complete call, so cancellation cannot race close.
  }
  void consume() noexcept {
    char bytes[4096];
    while (::read(read.value, bytes, sizeof(bytes)) < 0 && errno == EINTR) {}
    // Bound the drain even with continuously notifying producers.
  }
  Descriptor read, write;
};
inline int timeoutMillis(std::chrono::steady_clock::time_point deadline)
{
  using Clock = std::chrono::steady_clock;
  if (deadline == Clock::time_point::max()) return -1;
  const auto now = Clock::now();
  if (deadline <= now) return 0;
  const auto left = deadline - now;
  const auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(left);
  if (millis.count() >= INT_MAX) return INT_MAX;
  return static_cast<int>(millis.count()) + (millis < left ? 1 : 0);
}
} }
#endif
