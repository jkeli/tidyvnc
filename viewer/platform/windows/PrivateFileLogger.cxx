/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Windows private log file (plans/native-ui-winui/CORE.md §5). Files are
// created with a protected DACL granting only the current user and SYSTEM,
// a LockFileEx lock on a private .lock sidecar serialises cooperating TidyVNC
// processes, the previous log rotates to .bak with MoveFileExW, and reparse
// points, hard-linked or foreign-owned entries are refused. Any failure
// switches once to standard error, which a GUI process may not have (then the
// output is discarded), exactly like the POSIX adapter's fallback.
#include <viewer/platform/PrivateFileLogger.h>
#include "WinIO.h"
#include "StandardStream.h"

#include <aclapi.h>
#include <sddl.h>
#include <fcntl.h>
#include <io.h>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <vector>

using namespace viewer;
namespace {
[[noreturn]] void fail() { throw std::runtime_error("Private logging file unavailable"); }
void require(bool condition) { if (!condition) fail(); }
struct CloseStream { void operator()(FILE* stream) const noexcept { std::fclose(stream); } };
struct LocalMemory {
  ~LocalMemory() { if (value) ::LocalFree(value); }
  HLOCAL value = nullptr;
};

bool separator(wchar_t c) { return c == L'\\' || c == L'/'; }
bool separator(char c) { return c == '\\' || c == '/'; }

// A SID from the process token: the user, or the default owner of new
// objects (which differs from the user in an elevated process).
std::vector<uint8_t> tokenSid(TOKEN_INFORMATION_CLASS kind)
{
  winio::Handle token;
  require(::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token.value) != 0);
  DWORD size = 0;
  ::GetTokenInformation(token.value, kind, nullptr, 0, &size);
  require(size > 0);
  std::vector<uint8_t> buffer(size);
  require(::GetTokenInformation(token.value, kind, buffer.data(), size, &size) != 0);
  const PSID source = kind == TokenUser ? reinterpret_cast<const TOKEN_USER*>(buffer.data())->User.Sid
                                        : reinterpret_cast<const TOKEN_OWNER*>(buffer.data())->Owner;
  const DWORD length = ::GetLengthSid(source);
  std::vector<uint8_t> sid(length);
  require(::CopySid(length, sid.data(), source) != 0);
  return sid;
}

struct PrivateSecurity {
  PrivateSecurity() {
    const auto sid = tokenSid(TokenUser);
    LocalMemory text;
    require(::ConvertSidToStringSidW(const_cast<uint8_t*>(sid.data()), reinterpret_cast<LPWSTR*>(&text.value)) != 0);
    // Protected (no inheritance), full access for this user and SYSTEM only.
    const std::wstring sddl = std::wstring(L"D:P(A;;FA;;;") + static_cast<const wchar_t*>(text.value) + L")(A;;FA;;;SY)";
    require(::ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1,
                                                                   &descriptor.value, nullptr) != 0);
    attributes.nLength = sizeof(attributes);
    attributes.lpSecurityDescriptor = descriptor.value;
    attributes.bInheritHandle = FALSE;
    user = sid;
    owner = tokenSid(TokenOwner);
  }
  LocalMemory descriptor;
  SECURITY_ATTRIBUTES attributes{};
  std::vector<uint8_t> user, owner;
};

// A regular, singly linked file owned by this user, never a reparse point.
void inspect(HANDLE file, const PrivateSecurity& security)
{
  BY_HANDLE_FILE_INFORMATION info;
  require(::GetFileInformationByHandle(file, &info) != 0);
  require(!(info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)));
  require(info.nNumberOfLinks == 1);
  PSID owner = nullptr;
  LocalMemory descriptor;
  require(::GetSecurityInfo(file, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION, &owner, nullptr, nullptr,
                            nullptr, reinterpret_cast<PSECURITY_DESCRIPTOR*>(&descriptor.value)) == ERROR_SUCCESS);
  require(owner && (::EqualSid(owner, const_cast<uint8_t*>(security.user.data())) ||
                    ::EqualSid(owner, const_cast<uint8_t*>(security.owner.data()))));
}

// Replaces an entry's DACL with the private, protected one.
void makePrivate(HANDLE file, const PrivateSecurity& security)
{
  BOOL present = FALSE, defaulted = FALSE;
  PACL dacl = nullptr;
  require(::GetSecurityDescriptorDacl(security.descriptor.value, &present, &dacl, &defaulted) != 0 && present);
  require(::SetSecurityInfo(file, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                            nullptr, nullptr, dacl, nullptr) == ERROR_SUCCESS);
}

bool trustedWriter(PSID sid, const PrivateSecurity& security)
{
  if (::EqualSid(sid, const_cast<uint8_t*>(security.user.data())) ||
      ::EqualSid(sid, const_cast<uint8_t*>(security.owner.data())))
    return true;
  // OWNER RIGHTS (S-1-3-4) applies to the object's owner, which is itself checked.
  for (auto kind : {WinLocalSystemSid, WinBuiltinAdministratorsSid, WinCreatorOwnerSid, WinCreatorOwnerRightsSid}) {
    BYTE buffer[SECURITY_MAX_SID_SIZE]; DWORD size = sizeof(buffer);
    if (::CreateWellKnownSid(kind, nullptr, buffer, &size) && ::EqualSid(sid, buffer)) return true;
  }
  return false;
}

// The Windows form of the POSIX directory rule (not group/world writable
// unless sticky): other principals may add entries, as in a sticky /tmp, but
// only this user, SYSTEM and Administrators may delete, rename or
// re-permission them. Entries others plant are refused by the owner,
// reparse-point and CREATE_NEW checks. The directory is not a reparse point.
void checkDirectory(const std::wstring& root, const PrivateSecurity& security)
{
  winio::Handle directory(::CreateFileW(root.c_str(), READ_CONTROL | FILE_READ_ATTRIBUTES,
                                        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                                        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  require(directory.value != INVALID_HANDLE_VALUE);
  BY_HANDLE_FILE_INFORMATION info;
  require(::GetFileInformationByHandle(directory.value, &info) != 0);
  require((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT));
  PSID owner = nullptr; PACL dacl = nullptr;
  LocalMemory descriptor;
  require(::GetSecurityInfo(directory.value, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                            &owner, nullptr, &dacl, nullptr,
                            reinterpret_cast<PSECURITY_DESCRIPTOR*>(&descriptor.value)) == ERROR_SUCCESS);
  require(owner && trustedWriter(owner, security));
  require(dacl != nullptr); // A null DACL grants everyone everything.
  const ACCESS_MASK writes = FILE_DELETE_CHILD | WRITE_DAC | WRITE_OWNER | GENERIC_ALL;
  for (DWORD i = 0; i < dacl->AceCount; ++i) {
    ACE_HEADER* header = nullptr;
    require(::GetAce(dacl, i, reinterpret_cast<void**>(&header)) != 0);
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE || (header->AceFlags & INHERIT_ONLY_ACE)) continue;
    auto* ace = reinterpret_cast<ACCESS_ALLOWED_ACE*>(header);
    if (ace->Mask & writes) require(trustedWriter(reinterpret_cast<PSID>(&ace->SidStart), security));
  }
}

// Opens an existing entry without following reparse points, checks it and
// makes it private. Null when absent.
HANDLE existing(const std::wstring& path, const PrivateSecurity& security)
{
  const HANDLE file = ::CreateFileW(path.c_str(), READ_CONTROL | WRITE_DAC | FILE_READ_ATTRIBUTES,
                                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                                    OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    const DWORD error = ::GetLastError();
    require(error == ERROR_FILE_NOT_FOUND);
    return nullptr;
  }
  winio::Handle owned(file);
  inspect(file, security);
  makePrivate(file, security);
  owned.value = nullptr;
  return file;
}

std::string defaultLogPath()
{
  // The retained FLTK viewer's order: %TMP%, %TEMP%, then %USERPROFILE%.
  for (const wchar_t* name : {L"TMP", L"TEMP", L"USERPROFILE"}) {
    wchar_t buffer[32768];
    const DWORD length = ::GetEnvironmentVariableW(name, buffer, 32768);
    if (length == 0 || length >= 32768) continue;
    std::wstring directory(buffer, length);
    while (!directory.empty() && separator(directory.back())) directory.pop_back();
    try {
      const auto path = winio::narrow(directory) + "\\vncviewer.log";
      PrivateFileLogger::validatePath(path);
      return path;
    } catch (...) {}
  }
  return "C:\\vncviewer.log";
}
}

const char* PrivateFileLogger::defaultPath()
{
  static const std::string path = defaultLogPath();
  return path.c_str();
}

void PrivateFileLogger::validatePath(const std::string& path) {
  // Absolute drive-letter (C:\...) or UNC (\\server\share\..., \\?\...) paths.
  const bool drive = path.size() >= 3 && ((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) &&
    path[1] == ':' && separator(path[2]);
  const bool unc = path.size() >= 3 && separator(path[0]) && separator(path[1]) && !separator(path[2]);
  if (path.empty() || (!drive && !unc) || path.size() >= 32767 || path.find('\0') != std::string::npos)
    throw LogFilePathError();
  size_t slash = path.size();
  while (slash > 0 && !separator(path[slash - 1])) --slash;
  const auto name = path.substr(slash);
  if (name.empty() || name == "." || name == ".." || name.size() > 250 ||
      name.find_first_of("<>:\"|?*") != std::string::npos)
    throw LogFilePathError();
  try { winio::widen(path); } catch (...) { throw LogFilePathError(); }
}

namespace {
std::string parent(const std::string& path) {
  PrivateFileLogger::validatePath(path);
  size_t slash = path.size();
  while (slash > 0 && !separator(path[slash - 1])) --slash;
  return path.substr(0, slash - 1);
}
std::string leaf(const std::string& path) {
  size_t slash = path.size();
  while (slash > 0 && !separator(path[slash - 1])) --slash;
  return path.substr(slash);
}
}

PrivateFileLogger::PrivateFileLogger(const std::string& path)
  : Logger_File("native-file"), directory(parent(path)), filename(leaf(path)),
    backup(filename+".bak"), lockname(filename+".lock") {}

PrivateFileLogger::~PrivateFileLogger() {
  closeFile(); // Hold the cross-process lock until the output stream is closed.
  if (lockHandle) ::CloseHandle(static_cast<HANDLE>(lockHandle));
}

void PrivateFileLogger::initialize() {
  PrivateSecurity security;
  const std::wstring root = winio::widen(directory) + L"\\";
  const std::wstring logPath = root + winio::widen(filename), backupPath = root + winio::widen(backup),
    lockPath = root + winio::widen(lockname);
  // Trailing separator: "C:\" is a root; "C:" would be a working directory.
  checkDirectory(root, security);

  winio::Handle lock(::CreateFileW(lockPath.c_str(), GENERIC_READ | GENERIC_WRITE | READ_CONTROL | WRITE_DAC,
                                   FILE_SHARE_READ | FILE_SHARE_WRITE, &security.attributes, OPEN_ALWAYS,
                                   FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  require(lock.value != INVALID_HANDLE_VALUE);
  inspect(lock.value, security);
  makePrivate(lock.value, security);
  OVERLAPPED region{};
  require(::LockFileEx(lock.value, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &region) != 0);

  winio::Handle old(existing(logPath, security)), previous(existing(backupPath, security));
  if (old.value) {
    // Close our inspection handles first; MoveFileExW needs delete access.
    ::CloseHandle(old.value); old.value = nullptr;
    if (previous.value) { ::CloseHandle(previous.value); previous.value = nullptr; }
    require(::MoveFileExW(logPath.c_str(), backupPath.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0);
  }
  // CREATE_NEW never replaces an unexpected entry that appeared meanwhile.
  winio::Handle created(::CreateFileW(logPath.c_str(), GENERIC_WRITE | READ_CONTROL, FILE_SHARE_READ,
                                      &security.attributes, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
  require(created.value != INVALID_HANDLE_VALUE);
  inspect(created.value, security);
  const int fd = ::_open_osfhandle(reinterpret_cast<intptr_t>(created.value), _O_WRONLY | _O_TEXT);
  require(fd >= 0);
  created.value = nullptr; // Owned by the CRT descriptor now.
  FILE* stream = ::_fdopen(fd, "w");
  if (!stream) { ::_close(fd); fail(); }
  setFile(stream);
  lockHandle = lock.value; lock.value = nullptr;
}

void PrivateFileLogger::useStandardError() {
  fallback = true; closeFile();
  if (lockHandle) { ::CloseHandle(static_cast<HANDLE>(lockHandle)); lockHandle = nullptr; }
  // A GUI-subsystem process usually has no standard error; then nothing is
  // written, as the plan requires for stdio routes without a console.
  const int fd = winio::duplicateStandardStream(stderr);
  if (fd < 0) return;
  FILE* stream = ::_fdopen(fd, "w");
  if (!stream) { ::_close(fd); return; }
  setFile(stream);
  core::Logger_File::write(0,"TidyVNC","File logging is unavailable; using standard error.");
}

void PrivateFileLogger::write(int level, const char* source, const char* message) {
  std::lock_guard<std::recursive_mutex> guard(writeMutex);
  if (!initialized) {
    initialized = true;
    try { initialize(); } catch (...) { useStandardError(); }
  }
  if (!m_file) return;
  core::Logger_File::write(level,source,message);
  if (!fallback && ferror(m_file)) {
    useStandardError();
    if (m_file) core::Logger_File::write(level,source,message);
  }
}
