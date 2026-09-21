/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "PrivateFileLogger.h"
#include "detail/SocketIO.h"
#include <atomic>
#include <cstdio>
#include <cstring>
#include <memory>
#include <sys/file.h>
#include <sys/stat.h>
#ifdef __APPLE__
#include <sys/acl.h>
#endif

using namespace viewer;
namespace {
using detail::Descriptor;
[[noreturn]] void fail() { throw std::runtime_error("Private logging file unavailable"); }
void require(bool condition) { if (!condition) fail(); }
int privateDescriptor(int fd) {
  if (fd < 0 || fd >= 3) return fd;
  const int replacement = fcntl(fd,F_DUPFD_CLOEXEC,3), code = errno;
  close(fd); errno = code; return replacement;
}
struct stat inspect(int fd) {
  struct stat value;
  require(fstat(fd,&value) == 0);
  require(S_ISREG(value.st_mode) && value.st_uid == geteuid() && value.st_nlink == 1);
  return value;
}
void makePrivate(int fd) {
#ifdef __APPLE__
  acl_t acl = acl_init(0); require(acl != nullptr);
  const int result = acl_set_fd_np(fd,acl,ACL_TYPE_EXTENDED); acl_free(acl);
  require(result == 0);
#endif
  require(fchmod(fd,0600) == 0);
}
bool noExtendedACL(int fd) {
#ifdef __APPLE__
  acl_t acl = acl_get_fd_np(fd,ACL_TYPE_EXTENDED);
  if (!acl) return errno == ENOENT;
  acl_entry_t entry;
  const int result = acl_get_entry(acl,ACL_FIRST_ENTRY,&entry);
  const int code = errno; acl_free(acl);
  return result == -1 && code == EINVAL;
#else
  (void)fd; return true; // POSIX ACL access is bounded by mode bits at creation.
#endif
}
bool privateLock(int fd, const struct stat& value) {
  return (value.st_mode & 0777) == 0600 && noExtendedACL(fd);
}
bool sameAt(int root, const char* name, const struct stat& expected) {
  struct stat current;
  return fstatat(root,name,&current,AT_SYMLINK_NOFOLLOW) == 0 &&
    S_ISREG(current.st_mode) && current.st_dev == expected.st_dev && current.st_ino == expected.st_ino;
}
int existing(int root, const std::string& name) {
  const int fd = privateDescriptor(openat(root,name.c_str(),O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC));
  if (fd < 0 && errno != ENOENT) fail();
  return fd;
}
// Predictability does not grant access: O_EXCL and mode 0600 own creation. The
// bounded sequence also avoids random-source/logging recursion on a log worker.
struct Temporary {
  explicit Temporary(int root_) : root(root_) {
    static std::atomic<unsigned long long> sequence{0};
    for (unsigned i = 0; i < 64; ++i) {
      std::snprintf(name,sizeof(name),".tidyvnc-log-%ld-%llu.tmp",static_cast<long>(getpid()),++sequence);
      const int createdFd = openat(root,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
      if (createdFd >= 0) {
        fd.value = privateDescriptor(createdFd);
        if (fd.value < 0) { unlinkat(root,name,0); fail(); }
        return;
      }
      if (errno != EEXIST) fail();
    }
    fail();
  }
  ~Temporary() { if (created) unlinkat(root,name,0); }
  int root;
  char name[80]{};
  Descriptor fd;
  bool created = true;
};
std::string parent(const std::string& path) {
  PrivateFileLogger::validatePath(path);
  const auto slash = path.rfind('/'); return slash == 0 ? "/" : path.substr(0,slash);
}
}

const char* PrivateFileLogger::defaultPath() { return "/tmp/vncviewer.log"; }
void PrivateFileLogger::validatePath(const std::string& path) {
  if (path.empty() || path[0] != '/' || path.size() >= PATH_MAX || path.find('\0') != std::string::npos)
    throw LogFilePathError();
  const auto name = path.substr(path.rfind('/')+1);
  if (name.empty() || name == "." || name == ".." || name.size() > NAME_MAX-5)
    throw LogFilePathError();
}
PrivateFileLogger::PrivateFileLogger(const std::string& path)
  : Logger_File("native-file"), directory(parent(path)), filename(path.substr(path.rfind('/')+1)),
    backup(filename+".bak"), lockname(filename+".lock") {}
PrivateFileLogger::~PrivateFileLogger() {
  closeFile(); // Hold the cross-process lock until the output stream is closed.
  if (lockDescriptor >= 0) close(lockDescriptor);
}

void PrivateFileLogger::initialize() {
  // /tmp on macOS is a system symlink. Resolve the chosen parent once, then pin
  // it and perform all leaf operations through its descriptor.
  Descriptor root(privateDescriptor(open(directory.c_str(),O_RDONLY|O_DIRECTORY|O_CLOEXEC)));
  require(root.value >= 0);
  struct stat dir;
  require(fstat(root.value,&dir) == 0 && S_ISDIR(dir.st_mode));
  require((dir.st_uid == geteuid() || dir.st_uid == 0) &&
    (!(dir.st_mode & 0022) || (dir.st_uid == 0 && (dir.st_mode & S_ISVTX))));
  // An inherited macOS ACL can grant access independently of mode 0600. Refuse
  // extended directory ACLs before creating even an empty file: removing an ACL
  // afterwards cannot revoke a descriptor opened during that creation window.
  require(noExtendedACL(root.value));
  bool createdLock = true;
  Descriptor lock(privateDescriptor(openat(root.value,lockname.c_str(),O_RDWR|O_CREAT|O_EXCL|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC,0600)));
  if (lock.value < 0 && errno == EEXIST) {
    createdLock = false;
    lock.value = privateDescriptor(openat(root.value,lockname.c_str(),O_RDWR|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC));
  }
  require(lock.value >= 0);
  auto lockInfo = inspect(lock.value);
  if (createdLock) { makePrivate(lock.value); lockInfo = inspect(lock.value); }
  require(privateLock(lock.value,lockInfo));
  require(flock(lock.value,LOCK_EX|LOCK_NB) == 0);
  require(sameAt(root.value,lockname.c_str(),lockInfo));

  Descriptor old(existing(root.value,filename)), previous(existing(root.value,backup));
  struct stat oldInfo{}, previousInfo{};
  if (old.value >= 0) oldInfo = inspect(old.value);
  if (previous.value >= 0) {
    previousInfo = inspect(previous.value);
    if (old.value < 0) makePrivate(previous.value); // Retain an orphan backup privately.
  }
  Temporary temporary(root.value);
  inspect(temporary.fd.value); makePrivate(temporary.fd.value);
  FILE* stream = fdopen(temporary.fd.value,"w"); require(stream != nullptr);
  temporary.fd.value = -1;
  std::unique_ptr<FILE,decltype(&std::fclose)> owned(stream,&std::fclose);
  if (old.value >= 0) {
    makePrivate(old.value);
    if (previous.value >= 0) {
      require(sameAt(root.value,backup.c_str(),previousInfo));
      require(unlinkat(root.value,backup.c_str(),0) == 0);
    }
    require(sameAt(root.value,filename.c_str(),oldInfo));
    // linkat is atomic and does not replace an unexpected backup. Keep the old
    // bytes reachable through .bak before removing the original directory entry.
    require(linkat(root.value,filename.c_str(),root.value,backup.c_str(),0) == 0);
    require(sameAt(root.value,backup.c_str(),oldInfo));
    require(sameAt(root.value,filename.c_str(),oldInfo));
    require(unlinkat(root.value,filename.c_str(),0) == 0);
  }
  require(linkat(root.value,temporary.name,root.value,filename.c_str(),0) == 0);
  require(unlinkat(root.value,temporary.name,0) == 0); temporary.created = false;
  setFile(owned.get()); owned.release();
  lockDescriptor = lock.value; lock.value = -1;
}

void PrivateFileLogger::useStandardError() {
  fallback = true; closeFile();
  if (lockDescriptor >= 0) { close(lockDescriptor); lockDescriptor = -1; }
  const int fd = fcntl(STDERR_FILENO,F_DUPFD_CLOEXEC,3);
  if (fd < 0) return;
  FILE* stream = fdopen(fd,"w");
  if (!stream) { close(fd); return; }
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
