/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Windows counterpart of tests/unit/privatefilelogger.cxx for
// viewer/platform/windows/PrivateFileLogger.cxx. "Private" means a protected
// DACL granting only this user and SYSTEM; unsafe leaves are symbolic links,
// hard links and directories; an unsafe directory is one other users can
// write to.
#include <gtest/gtest.h>
#include <viewer/platform/PrivateFileLogger.h>
#include <viewer/core/RedactedLogger.h>
#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <io.h>
#include <fcntl.h>
#include <cstdarg>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <random>
#include <thread>
#include <vector>

namespace {
struct Directory {
  Directory() {
    std::random_device random;
    path = std::filesystem::temp_directory_path() / ("tidyvnc-private-log-" + std::to_string(random()));
    std::filesystem::create_directory(path);
  }
  ~Directory() { std::error_code error; std::filesystem::remove_all(path, error); }
  std::filesystem::path path;
};
// Redirects the CRT's standard error (descriptor 2) into a temporary file.
struct Capture {
  Capture() : file(std::tmpfile()) {
    std::fflush(stderr);
    saved = _dup(2);
    if (saved < 0 || !file || _dup2(_fileno(file), 2) < 0) throw std::runtime_error("Capture failed");
  }
  ~Capture() { std::fflush(stderr); _dup2(saved, 2); _close(saved); std::fclose(file); }
  std::string read() {
    std::fflush(stderr); std::fflush(file); std::rewind(file); char buffer[4096]; std::string value;
    while (const auto size = std::fread(buffer, 1, sizeof(buffer), file)) value.append(buffer, size);
    return value;
  }
  int saved; FILE* file;
};
std::string read(const std::filesystem::path& path) {
  std::ifstream file(path, std::ios::binary); return std::string(std::istreambuf_iterator<char>(file), {});
}
void emit(core::Logger& logger, const char* format, ...) {
  va_list args; va_start(args, format); logger.write(30, "CConnection", format, args); va_end(args);
}
std::wstring sidString(PSID sid) {
  LPWSTR text = nullptr; if (!::ConvertSidToStringSidW(sid, &text)) return L"";
  std::wstring value(text); ::LocalFree(text); return value;
}
std::wstring currentUser() {
  HANDLE token = nullptr; ::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token);
  DWORD size = 0; ::GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> buffer(size); ::GetTokenInformation(token, TokenUser, buffer.data(), size, &size);
  ::CloseHandle(token);
  return sidString(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid);
}
// Protected DACL whose allow entries are only this user and SYSTEM; one link.
void privateFile(const std::filesystem::path& path) {
  HANDLE file = ::CreateFileW(path.c_str(), READ_CONTROL | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  ASSERT_NE(file, INVALID_HANDLE_VALUE);
  BY_HANDLE_FILE_INFORMATION info; ASSERT_TRUE(::GetFileInformationByHandle(file, &info));
  EXPECT_EQ(info.nNumberOfLinks, 1u);
  EXPECT_EQ(info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY), 0u);
  PACL dacl = nullptr; PSECURITY_DESCRIPTOR descriptor = nullptr;
  ASSERT_EQ(::GetSecurityInfo(file, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, nullptr, nullptr, &dacl, nullptr, &descriptor),
            static_cast<DWORD>(ERROR_SUCCESS));
  SECURITY_DESCRIPTOR_CONTROL control = 0; DWORD revision = 0;
  ASSERT_TRUE(::GetSecurityDescriptorControl(descriptor, &control, &revision));
  EXPECT_NE(control & SE_DACL_PROTECTED, 0);
  ASSERT_NE(dacl, nullptr);
  const auto user = currentUser();
  for (DWORD i = 0; i < dacl->AceCount; ++i) {
    ACE_HEADER* header = nullptr; ASSERT_TRUE(::GetAce(dacl, i, reinterpret_cast<void**>(&header)));
    ASSERT_EQ(header->AceType, ACCESS_ALLOWED_ACE_TYPE);
    const auto sid = sidString(reinterpret_cast<PSID>(&reinterpret_cast<ACCESS_ALLOWED_ACE*>(header)->SidStart));
    EXPECT_TRUE(sid == user || sid == L"S-1-5-18") << "Unexpected ACE for " << std::string(sid.begin(), sid.end());
  }
  ::LocalFree(descriptor); ::CloseHandle(file);
}
bool canCreateSymlinks(const std::filesystem::path& directory) {
  const auto probe = directory / "symlink-probe";
  const bool created = ::CreateSymbolicLinkW(probe.c_str(), L"target", SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE) != 0;
  if (created) ::DeleteFileW(probe.c_str());
  return created;
}
// Grants Everyone the right to remove entries from a directory (an unsafe
// parent: adding alone is allowed, like a sticky /tmp).
void shareWithEveryone(const std::filesystem::path& directory) {
  PACL old = nullptr; PSECURITY_DESCRIPTOR descriptor = nullptr;
  ASSERT_EQ(::GetNamedSecurityInfoW(directory.c_str(), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, nullptr, nullptr, &old,
                                    nullptr, &descriptor), static_cast<DWORD>(ERROR_SUCCESS));
  EXPLICIT_ACCESSW access{}; access.grfAccessPermissions = FILE_ADD_FILE | FILE_DELETE_CHILD;
  access.grfAccessMode = GRANT_ACCESS; access.grfInheritance = NO_INHERITANCE;
  BYTE everyone[SECURITY_MAX_SID_SIZE]; DWORD size = sizeof(everyone);
  ASSERT_TRUE(::CreateWellKnownSid(WinWorldSid, nullptr, everyone, &size));
  access.Trustee.TrusteeForm = TRUSTEE_IS_SID; access.Trustee.TrusteeType = TRUSTEE_IS_WELL_KNOWN_GROUP;
  access.Trustee.ptstrName = reinterpret_cast<LPWSTR>(everyone);
  PACL updated = nullptr;
  ASSERT_EQ(::SetEntriesInAclW(1, &access, old, &updated), static_cast<DWORD>(ERROR_SUCCESS));
  ASSERT_EQ(::SetNamedSecurityInfoW(const_cast<LPWSTR>(directory.c_str()), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION,
                                    nullptr, nullptr, updated, nullptr), static_cast<DWORD>(ERROR_SUCCESS));
  ::LocalFree(updated); ::LocalFree(descriptor);
}
}

TEST(PrivateFileLogger, LazyRedactedCreationAndBackupPreserveExistingBytes) {
  Directory directory; const auto path = directory.path / L"\u79d8\u5bc6.log";
  const auto backup = std::filesystem::path(path.wstring() + L".bak");
  { std::ofstream(path) << "previous log"; std::ofstream(backup) << "previous backup"; }
  const std::string utf8 = path.u8string(); // C++17: UTF-8 in std::string.
  {
    viewer::PrivateFileLogger raw(utf8); viewer::RedactedLogger logger("fixture", raw);
    EXPECT_EQ(read(path), "previous log"); EXPECT_EQ(read(backup), "previous backup");
    EXPECT_FALSE(std::filesystem::exists(path.wstring() + L".lock"));
    emit(logger, "Reading protocol version"); emit(logger, "%s", "private-endpoint\nforged: secret");
    EXPECT_EQ(read(backup), "previous log");
    const auto current = read(path);
    EXPECT_NE(current.find("Reading protocol version"), std::string::npos);
    EXPECT_NE(current.find("Diagnostic details redacted."), std::string::npos);
    EXPECT_EQ(current.find("private"), std::string::npos); EXPECT_EQ(current.find("forged"), std::string::npos);
    privateFile(path); privateFile(backup); privateFile(path.wstring() + L".lock");
  }
  const auto previous = read(path);
  { viewer::PrivateFileLogger raw(utf8); viewer::RedactedLogger logger("fixture", raw);
    emit(logger, "Initialisation done"); }
  EXPECT_EQ(read(backup), previous); EXPECT_NE(read(path).find("Initialisation done"), std::string::npos);
}

TEST(PrivateFileLogger, LongPathsLogWithoutTheLongPathsSetting) {
  // A log folder beyond MAX_PATH, created through \\?\ so neither side needs LongPathsEnabled.
  Directory directory;
  const auto folder = directory.path / std::wstring(120, L'a') / std::wstring(120, L'b');
  const std::wstring extended = L"\\\\?\\";
  std::filesystem::create_directories(extended + folder.wstring());
  const auto path = folder / L"viewer.log";
  ASSERT_GT(path.wstring().size(), 260u);
  {
    viewer::PrivateFileLogger raw(path.u8string()); viewer::RedactedLogger logger("fixture", raw);
    emit(logger, "Reading protocol version");
  }
  EXPECT_NE(read(extended + path.wstring()).find("Reading protocol version"), std::string::npos);
  privateFile(extended + path.wstring());
  std::error_code ignored;
  std::filesystem::remove_all(extended + directory.path.wstring(), ignored);
}

TEST(PrivateFileLogger, SuppressedEventsAndUnusedSinksNeverTouchTheFilesystem) {
  Directory directory; const auto path = directory.path / "viewer.log";
  { viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger logger("fixture", raw);
    emit(logger, "Key pressed: %d => 0x%02x / XK_%s (0x%04x)", 1, 2, "private-key", 3); }
  EXPECT_TRUE(std::filesystem::is_empty(directory.path));
}

TEST(PrivateFileLogger, UnsafeLeavesArePreservedAndFallbackWarnsOnceWithoutPaths) {
  Directory probe; const bool symlinks = canCreateSymlinks(probe.path);
  for (const auto* suffix : {"", ".bak", ".lock"}) for (int kind = 0; kind < 3; ++kind) {
    if (kind == 0 && !symlinks) continue; // Needs Developer Mode or the symlink privilege.
    Directory directory; Capture capture; const auto path = directory.path / "private-path.log";
    const auto unsafe = std::filesystem::path(path.string() + suffix);
    const auto victim = directory.path / "victim";
    { std::ofstream(victim) << "unrelated original"; }
    if (kind == 0) ASSERT_TRUE(::CreateSymbolicLinkW(unsafe.c_str(), victim.c_str(), SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE));
    else if (kind == 1) ASSERT_TRUE(::CreateHardLinkW(unsafe.c_str(), victim.c_str(), nullptr));
    else ASSERT_TRUE(std::filesystem::create_directory(unsafe));
    {
      viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger logger("fixture", raw);
      emit(logger, "Reading protocol version"); emit(logger, "%s", "private-value");
      const auto text = capture.read();
      const std::string warning = "File logging is unavailable; using standard error.";
      const auto first = text.find(warning); ASSERT_NE(first, std::string::npos) << suffix << " kind " << kind;
      EXPECT_EQ(text.find(warning, first + 1), std::string::npos);
      EXPECT_NE(text.find("Reading protocol version"), std::string::npos);
      EXPECT_EQ(text.find("private"), std::string::npos);
    }
    EXPECT_EQ(read(victim), "unrelated original");
    if (kind == 0) EXPECT_TRUE(std::filesystem::is_symlink(unsafe));
    else if (kind == 1) EXPECT_EQ(std::filesystem::hard_link_count(victim), 2u);
    else EXPECT_TRUE(std::filesystem::is_directory(unsafe));
  }
}

TEST(PrivateFileLogger, CooperativeOwnersCannotRotateAnActiveLog) {
  Directory directory; Capture capture; const auto path = directory.path / "viewer.log";
  viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger first("first", raw);
  emit(first, "Reading protocol version"); std::fflush(nullptr); const auto before = read(path);
  { viewer::PrivateFileLogger otherRaw(path.string()); viewer::RedactedLogger other("second", otherRaw);
    emit(other, "Initialisation done"); }
  EXPECT_EQ(read(path), before); EXPECT_FALSE(std::filesystem::exists(path.string() + ".bak"));
  EXPECT_NE(capture.read().find("File logging is unavailable"), std::string::npos);
  emit(first, "Initialisation done"); std::fflush(nullptr);
  EXPECT_NE(read(path).find("Initialisation done"), std::string::npos);
}

TEST(PrivateFileLogger, ConcurrentFirstWritesCreateOnePrivateDestination) {
  Directory directory; const auto path = directory.path / "viewer.log";
  {
    viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger logger("fixture", raw);
    std::vector<std::thread> threads;
    for (int worker = 0; worker < 6; ++worker) threads.emplace_back([&] {
      for (int i = 0; i < 100; ++i) emit(logger, "Reading protocol version");
    });
    for (auto& thread : threads) thread.join();
  }
  const auto text = read(path); const std::string record = "Reading protocol version";
  size_t count = 0, position = 0;
  while ((position = text.find(record, position)) != std::string::npos) { ++count; position += record.size(); }
  EXPECT_EQ(count, 600u); EXPECT_FALSE(std::filesystem::exists(path.string() + ".bak"));
  privateFile(path);
}

TEST(PrivateFileLogger, OutputFailureFallsBackAndRetainsTheFailedRecord) {
  Directory directory; Capture capture; const auto path = directory.path / "viewer.log";
  viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger logger("fixture", raw);
  emit(logger, "Reading protocol version");
  // Find this fixture's CRT output descriptor by file identity and invalidate
  // it, producing a real write failure without filling a disk.
  HANDLE probe = ::CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                               OPEN_EXISTING, 0, nullptr);
  ASSERT_NE(probe, INVALID_HANDLE_VALUE);
  BY_HANDLE_FILE_INFORMATION expected; ASSERT_TRUE(::GetFileInformationByHandle(probe, &expected)); ::CloseHandle(probe);
  int output = -1;
  for (int fd = 3; fd < 2048 && output < 0; ++fd) {
    const intptr_t handle = _get_osfhandle(fd);
    if (handle == -1 || handle == -2) continue;
    BY_HANDLE_FILE_INFORMATION info;
    if (::GetFileInformationByHandle(reinterpret_cast<HANDLE>(handle), &info) &&
        info.dwVolumeSerialNumber == expected.dwVolumeSerialNumber &&
        info.nFileIndexHigh == expected.nFileIndexHigh && info.nFileIndexLow == expected.nFileIndexLow) output = fd;
  }
  ASSERT_GE(output, 3);
  DWORD flags = 0; ASSERT_TRUE(::GetHandleInformation(reinterpret_cast<HANDLE>(_get_osfhandle(output)), &flags));
  EXPECT_EQ(flags & HANDLE_FLAG_INHERIT, 0u);
  // Closing the descriptor under a FILE* is an invalid parameter for the MSVC
  // CRT; pointing it at a read-only handle instead makes the write fail.
  const int readOnly = _wopen(path.c_str(), _O_RDONLY | _O_BINARY);
  ASSERT_GE(readOnly, 0);
  ASSERT_EQ(_dup2(readOnly, output), 0); _close(readOnly);
  emit(logger, "Initialisation done");
  const auto text = capture.read();
  EXPECT_NE(text.find("File logging is unavailable"), std::string::npos);
  EXPECT_NE(text.find("Initialisation done"), std::string::npos);
  EXPECT_EQ(read(path).find("Initialisation done"), std::string::npos);
}

TEST(PrivateFileLogger, InvalidPathsAndUnsafeDirectoriesDoNotCreateLogs) {
  for (const auto& path : std::vector<std::string>{"", "relative", "C:", "C:relative.log", "\\rooted.log", "C:\\",
                                                   "C:\\tmp\\.", "C:\\tmp\\..", "C:\\tmp\\a:b", std::string("C:\\tmp\\a\0b", 10),
                                                   "C:\\" + std::string(40000, 'a'), "C:\\tmp\\\xff.log"})
    EXPECT_THROW(viewer::PrivateFileLogger{path}, viewer::LogFilePathError) << path.substr(0, 40);
  EXPECT_NO_THROW(viewer::PrivateFileLogger::validatePath("\\\\server\\share\\viewer.log"));
  EXPECT_NO_THROW(viewer::PrivateFileLogger::validatePath("C:/Users/viewer.log"));
  Directory directory; Capture capture; const auto path = directory.path / "viewer.log";
  shareWithEveryone(directory.path);
  { viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger logger("fixture", raw); emit(logger, "Reading protocol version"); }
  EXPECT_FALSE(std::filesystem::exists(path)); EXPECT_TRUE(std::filesystem::is_empty(directory.path));
  EXPECT_NE(capture.read().find("File logging is unavailable"), std::string::npos);
}

TEST(PrivateFileLogger, DefaultPathFollowsTheRetainedViewer) {
  const std::string path = viewer::PrivateFileLogger::defaultPath();
  EXPECT_NO_THROW(viewer::PrivateFileLogger::validatePath(path));
  EXPECT_EQ(path.substr(path.size() - 14), "\\vncviewer.log");
  wchar_t buffer[32768]; const DWORD length = ::GetEnvironmentVariableW(L"TMP", buffer, 32768);
  if (length > 0 && length < 32768) {
    std::filesystem::path tmp(std::wstring(buffer, length));
    EXPECT_EQ(std::filesystem::path(path).parent_path(), tmp.lexically_normal().parent_path() / tmp.filename());
  }
}

TEST(PrivateFileLogger, ExistingBackupWithoutALogKeepsItsBytesPrivately) {
  Directory directory; const auto path = directory.path / "viewer.log";
  const auto backup = path.string() + ".bak";
  { std::ofstream file(backup); file << "previous diagnostic bytes"; }
  {
    viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger logger("fixture", raw);
    emit(logger, "Reading protocol version");
  }
  EXPECT_EQ(read(backup), "previous diagnostic bytes"); privateFile(backup); privateFile(path);
}
