/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// CORE.md section 4 / W1.9: GnuTLS opens CA and CRL files with narrow C paths
// (common/rfb/CSecurityTLS.cxx). The WinUI app declares UTF-8 as its active
// code page, which makes those narrow paths UTF-8 for the CRT and for the
// UCRT-based GnuTLS DLL alike. This executable carries the same manifest
// (utf8.manifest) and proves non-ASCII (and, when Windows allows it, long)
// CA/CRL paths load through the exact GnuTLS calls the core makes.
#include <gtest/gtest.h>
#include <windows.h>
#include <gnutls/gnutls.h>
#include <gnutls/x509.h>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <random>
#include <string>
#include "../../viewer/trust-fixture.h"

namespace {
struct Directory {
  explicit Directory(const std::wstring& name) {
    std::random_device random;
    base = std::filesystem::temp_directory_path() / (L"tidyvnc-" + std::to_wstring(random()));
    path = base / name;
    std::filesystem::create_directories(path);
  }
  ~Directory() { std::error_code ignored; std::filesystem::remove_all(base, ignored); }
  std::filesystem::path base, path;
};
std::string utf8(const std::filesystem::path& path) { return path.u8string(); }
int loadTrust(const std::filesystem::path& file) {
  std::ofstream(file, std::ios::binary).write(reinterpret_cast<const char*>(trust_fixture_certificate),
                                               sizeof(trust_fixture_certificate));
  gnutls_certificate_credentials_t credentials = nullptr;
  if (gnutls_certificate_allocate_credentials(&credentials) != 0) return -1;
  const int loaded = gnutls_certificate_set_x509_trust_file(credentials, utf8(file).c_str(), GNUTLS_X509_FMT_DER);
  gnutls_certificate_free_credentials(credentials);
  return loaded;
}
bool longPathsEnabled() {
  DWORD value = 0, size = sizeof(value);
  return ::RegGetValueW(HKEY_LOCAL_MACHINE, L"SYSTEM\\CurrentControlSet\\Control\\FileSystem", L"LongPathsEnabled",
                        RRF_RT_REG_DWORD, nullptr, &value, &size) == ERROR_SUCCESS && value == 1;
}
}

TEST(WindowsPaths, ManifestSelectsUtf8ActiveCodePage)
{
  EXPECT_EQ(::GetACP(), static_cast<UINT>(CP_UTF8));
}

TEST(WindowsPaths, NonAsciiCaFileLoadsThroughNarrowGnuTLSPath)
{
  Directory directory(L"café 秘密 доверие");
  EXPECT_EQ(loadTrust(directory.path / L"x509_ca é.der"), 1);
  // The same narrow path through the CRT, as ConnectionDocument readers use.
  FILE* file = std::fopen(utf8(directory.path / L"x509_ca é.der").c_str(), "rb");
  ASSERT_NE(file, nullptr); std::fclose(file);
}

TEST(WindowsPaths, UncStyleExtendedPathLoads)
{
  Directory directory(L"extended");
  const auto file = directory.path / L"ca.der";
  std::ofstream(file, std::ios::binary).write(reinterpret_cast<const char*>(trust_fixture_certificate),
                                               sizeof(trust_fixture_certificate));
  gnutls_certificate_credentials_t credentials = nullptr;
  ASSERT_EQ(gnutls_certificate_allocate_credentials(&credentials), 0);
  const std::string extended = "\\\\?\\" + utf8(file);
  EXPECT_EQ(gnutls_certificate_set_x509_trust_file(credentials, extended.c_str(), GNUTLS_X509_FMT_DER), 1);
  gnutls_certificate_free_credentials(credentials);
}

TEST(WindowsPaths, LongCaFilePathLoadsWhenWindowsAllowsLongPaths)
{
  if (!longPathsEnabled())
    GTEST_SKIP() << "LongPathsEnabled is 0 on this machine; long paths need that system setting (W20 stays open)";
  Directory directory(std::wstring(120, L'a') + L"\\" + std::wstring(120, L'b') + L"\\" + std::wstring(40, L'é'));
  const auto file = directory.path / L"ca.der";
  ASSERT_GT(utf8(file).size(), 260u);
  EXPECT_EQ(loadTrust(file), 1);
}
