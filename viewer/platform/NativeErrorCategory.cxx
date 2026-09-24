/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/platform/NativeErrorCategory.h>
#ifdef _WIN32
#include <winsock2.h>
#include <winerror.h>
#else
#include <cerrno>
#endif

viewer::NativeErrorCategory viewer::classifyNativeError(int32_t code)
{
  switch (code) {
#ifdef _WIN32
  // Winsock reports socket failures; Win32 network codes can reach the
  // adapters through overlapped completions.
  case WSAEACCES: case ERROR_ACCESS_DENIED: case ERROR_NETWORK_ACCESS_DENIED:
    return NativeErrorCategory::NetworkPolicy;
  case WSAECONNREFUSED: case ERROR_CONNECTION_REFUSED:
    return NativeErrorCategory::Refused;
  case WSAENETDOWN: case WSAENETUNREACH: case WSAEHOSTDOWN: case WSAEHOSTUNREACH:
  case ERROR_NETWORK_UNREACHABLE: case ERROR_HOST_UNREACHABLE: case ERROR_PROTOCOL_UNREACHABLE:
    return NativeErrorCategory::Routing;
  case WSAETIMEDOUT: case ERROR_SEM_TIMEOUT:
    return NativeErrorCategory::TimedOut;
#else
  case EACCES: case EPERM:
    return NativeErrorCategory::NetworkPolicy;
  case ECONNREFUSED:
    return NativeErrorCategory::Refused;
  case ENETDOWN: case ENETUNREACH: case EHOSTDOWN: case EHOSTUNREACH:
    return NativeErrorCategory::Routing;
  case ETIMEDOUT:
    return NativeErrorCategory::TimedOut;
#endif
  default:
    return NativeErrorCategory::Other;
  }
}
