/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Native error categories through the C ABI: the macOS NativeConnectionIssue
// errno mapping on POSIX, and the same categories for Winsock/Win32 codes.
#include <gtest/gtest.h>
#include <tidyvnc.h>
#ifdef _WIN32
#include <winsock2.h>
#else
#include <cerrno>
#endif

namespace {
uint32_t category(int32_t code) {
  uint32_t value = 99;
  EXPECT_EQ(tidyvnc_native_error_category(code, &value, nullptr), TIDYVNC_OK);
  return value;
}
}

TEST(NativeErrorCategory, AdvertisedAndValidatesOutput)
{
  tidyvnc_abi_info abi{}; abi.size = sizeof(abi); abi.version = TIDYVNC_ABI_VERSION;
  ASSERT_EQ(tidyvnc_get_abi(&abi, nullptr), TIDYVNC_OK);
  EXPECT_NE(abi.features & TIDYVNC_FEATURE_NATIVE_ERROR_CATEGORY, 0u);
  EXPECT_EQ(tidyvnc_native_error_category(0, nullptr, nullptr), TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(category(0), static_cast<uint32_t>(TIDYVNC_NATIVE_ERROR_OTHER));
  EXPECT_EQ(category(-1), static_cast<uint32_t>(TIDYVNC_NATIVE_ERROR_OTHER));
}

TEST(NativeErrorCategory, PlatformCodesMapToSharedCategories)
{
#ifdef _WIN32
  EXPECT_EQ(category(WSAEACCES), static_cast<uint32_t>(TIDYVNC_NATIVE_ERROR_NETWORK_POLICY));
  EXPECT_EQ(category(WSAECONNREFUSED), static_cast<uint32_t>(TIDYVNC_NATIVE_ERROR_REFUSED));
  EXPECT_EQ(category(ERROR_CONNECTION_REFUSED), static_cast<uint32_t>(TIDYVNC_NATIVE_ERROR_REFUSED));
  for (int32_t code : std::initializer_list<int32_t>{WSAENETDOWN, WSAENETUNREACH, WSAEHOSTDOWN, WSAEHOSTUNREACH,
                       ERROR_NETWORK_UNREACHABLE, ERROR_HOST_UNREACHABLE})
    EXPECT_EQ(category(code), static_cast<uint32_t>(TIDYVNC_NATIVE_ERROR_ROUTING)) << code;
  EXPECT_EQ(category(WSAETIMEDOUT), static_cast<uint32_t>(TIDYVNC_NATIVE_ERROR_TIMED_OUT));
  EXPECT_EQ(category(WSAECONNRESET), static_cast<uint32_t>(TIDYVNC_NATIVE_ERROR_OTHER));
  EXPECT_EQ(category(WSAHOST_NOT_FOUND), static_cast<uint32_t>(TIDYVNC_NATIVE_ERROR_OTHER));
#else
  for (int32_t code : {EACCES, EPERM})
    EXPECT_EQ(category(code), static_cast<uint32_t>(TIDYVNC_NATIVE_ERROR_NETWORK_POLICY));
  EXPECT_EQ(category(ECONNREFUSED), static_cast<uint32_t>(TIDYVNC_NATIVE_ERROR_REFUSED));
  for (int32_t code : {ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH})
    EXPECT_EQ(category(code), static_cast<uint32_t>(TIDYVNC_NATIVE_ERROR_ROUTING));
  EXPECT_EQ(category(ETIMEDOUT), static_cast<uint32_t>(TIDYVNC_NATIVE_ERROR_TIMED_OUT));
  EXPECT_EQ(category(ECONNRESET), static_cast<uint32_t>(TIDYVNC_NATIVE_ERROR_OTHER));
#endif
}
