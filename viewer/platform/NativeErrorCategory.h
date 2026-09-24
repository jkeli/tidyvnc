/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_NATIVE_ERROR_CATEGORY_H
#define TIDYVNC_NATIVE_ERROR_CATEGORY_H
#include <cstdint>

namespace viewer {
// Frontend-neutral meaning of a connection or transport native error code
// (plans/native-ui-winui PLAN.md section 6). Codes are this platform's: errno
// on macOS/Linux, Winsock/Win32 values on Windows. The categories are the ones
// the macOS app derives from errno in NativeConnectionIssue.
enum class NativeErrorCategory : uint32_t { Other = 0, NetworkPolicy = 1, Refused = 2, Routing = 3, TimedOut = 4 };
NativeErrorCategory classifyNativeError(int32_t code);
}
#endif
