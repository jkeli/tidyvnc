/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_WINDOWS_WINIO_H
#define TIDYVNC_WINDOWS_WINIO_H
// Private Windows implementation helpers for the platform adapters, not a
// frontend/service contract. The Windows counterpart of detail/SocketIO.h.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <chrono>
#include <climits>
#include <cstdint>
#include <stdexcept>
#include <system_error>
#include <network/Socket.h>

namespace viewer { namespace winio {
using Clock = std::chrono::steady_clock;
using TimePoint = Clock::time_point;

// Native codes are Win32/Winsock values (Winsock errors are Win32 errors), so
// they are reported in the system category, never mixed with errno values.
[[noreturn]] inline void fail(const char* operation, int error)
{
  throw std::system_error(error, std::system_category(), operation);
}
[[noreturn]] inline void failSocket(const char* operation) { fail(operation, ::WSAGetLastError()); }
[[noreturn]] inline void failWin32(const char* operation) { fail(operation, static_cast<int>(::GetLastError())); }

struct Socket {
  explicit Socket(SOCKET value_ = INVALID_SOCKET) : value(value_) {}
  ~Socket() { reset(); }
  Socket(const Socket&) = delete;
  Socket& operator=(const Socket&) = delete;
  void reset() noexcept { if (value != INVALID_SOCKET) { ::closesocket(value); value = INVALID_SOCKET; } }
  SOCKET release() noexcept { const SOCKET result = value; value = INVALID_SOCKET; return result; }
  SOCKET value;
};

struct Handle {
  explicit Handle(HANDLE value_ = nullptr) : value(value_) {}
  ~Handle() { if (value && value != INVALID_HANDLE_VALUE) ::CloseHandle(value); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  HANDLE value;
};

// Auto-reset events coalesce repeated signals like the POSIX wake pipe;
// manual-reset events stay set until their single owner resets them.
struct Event : Handle {
  explicit Event(bool manualReset = false)
    : Handle(::CreateEventW(nullptr, manualReset ? TRUE : FALSE, FALSE, nullptr))
  {
    if (!value) failWin32("event");
  }
  void signal() const noexcept { ::SetEvent(value); }
  void reset() const noexcept { ::ResetEvent(value); }
};

// Every socket the adapters create is overlapped-capable and never inherited
// by child processes (the SSH tunnel launches ssh.exe).
inline SOCKET openSocket(int family, int type, int protocol)
{
  network::initSockets();
  const SOCKET socket = ::WSASocketW(family, type, protocol, nullptr, 0,
                                     WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
  if (socket == INVALID_SOCKET) failSocket("socket");
  return socket;
}

// The shared network library keeps sockets as int. Windows SOCKET values are
// small kernel handles in practice; convert once, checked, where they meet.
inline int sharedDescriptor(SOCKET socket)
{
  if (socket == INVALID_SOCKET || socket > static_cast<SOCKET>(INT_MAX))
    throw std::invalid_argument("Socket handle exceeds the shared descriptor range");
  return static_cast<int>(socket);
}

// The Windows counterpart of detail::WakePipe for WSAPoll-based waits: a
// nonblocking loopback UDP socket connected to itself. Connected UDP sockets
// only accept datagrams from their peer, so other processes cannot inject
// wakes, and a full receive buffer coalesces further signals.
struct WakeSocket {
  WakeSocket() : socket(openSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)) {
    sockaddr_in address{};
    address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int length = sizeof(address);
    if (::bind(socket.value, reinterpret_cast<sockaddr*>(&address), length) == SOCKET_ERROR ||
        ::getsockname(socket.value, reinterpret_cast<sockaddr*>(&address), &length) == SOCKET_ERROR ||
        ::connect(socket.value, reinterpret_cast<sockaddr*>(&address), length) == SOCKET_ERROR)
      failSocket("wake socket");
    u_long nonblocking = 1;
    if (::ioctlsocket(socket.value, FIONBIO, &nonblocking) == SOCKET_ERROR) failSocket("wake socket mode");
  }
  void signal() const noexcept {
    const char byte = 1;
    ::send(socket.value, &byte, 1, 0); // WSAEWOULDBLOCK coalesces with pending wakes.
  }
  void consume() const noexcept {
    // Bounded, even with producers that keep signalling.
    char bytes[16];
    for (int i = 0; i < 1024 && ::recv(socket.value, bytes, sizeof(bytes), 0) > 0; ++i) {}
  }
  Socket socket;
};

inline INT pollTimeout(TimePoint deadline)
{
  if (deadline == TimePoint::max()) return -1;
  const auto now = Clock::now();
  if (deadline <= now) return 0;
  const auto left = deadline - now;
  const auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(left);
  if (millis.count() >= INT_MAX) return INT_MAX;
  return static_cast<INT>(millis.count()) + (millis < left ? 1 : 0);
}

inline DWORD timeoutMillis(TimePoint deadline)
{
  if (deadline == TimePoint::max()) return INFINITE;
  const auto now = Clock::now();
  if (deadline <= now) return 0;
  const auto left = deadline - now;
  const auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(left);
  if (millis.count() >= static_cast<long long>(INFINITE - 1)) return INFINITE - 1;
  return static_cast<DWORD>(millis.count()) + (millis < left ? 1 : 0);
}

inline std::wstring widen(const std::string& text)
{
  if (text.empty()) return std::wstring();
  if (text.size() > static_cast<size_t>(INT_MAX)) throw std::length_error("Text too long");
  const int size = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                                         static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) throw std::invalid_argument("Invalid UTF-8");
  std::wstring result(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()),
                        &result[0], size);
  return result;
}

inline std::string narrow(const std::wstring& text)
{
  if (text.empty()) return std::string();
  if (text.size() > static_cast<size_t>(INT_MAX)) throw std::length_error("Text too long");
  const int size = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
                                         static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0) throw std::invalid_argument("Invalid UTF-16");
  std::string result(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()),
                        &result[0], size, nullptr, nullptr);
  return result;
}
} }
#endif
