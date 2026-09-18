// Original TidyVNC work, 2026. SPDX-License-Identifier: GPL-2.0-or-later
#ifndef _WIN32
#include <core/AtomicFile.h>
#include <core/Exception.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <vector>
#include <stdexcept>

core::AtomicFile::AtomicFile(const char* path) : destination(path), file(nullptr)
{
  std::string pattern = destination + ".XXXXXX";
  std::vector<char> name(pattern.begin(), pattern.end());
  name.push_back('\0');
  int fd = mkstemp(name.data());
  if (fd < 0) throw posix_error("Create temporary settings file", errno);
  temporary = name.data();
  file = fdopen(fd, "w");
  if (!file) {
    int error = errno;
    close(fd);
    unlink(temporary.c_str());
    throw posix_error("Open temporary settings file", error);
  }
}

core::AtomicFile::~AtomicFile()
{
  if (file) fclose(file);
  if (!temporary.empty()) unlink(temporary.c_str());
}

void core::AtomicFile::commit(bool replace)
{
  if (ferror(file) || fflush(file) != 0 || fsync(fileno(file)) != 0)
    throw posix_error("Write settings file", errno ? errno : EIO);
  struct stat st;
  if (lstat(destination.c_str(), &st) == 0) {
    if (!S_ISREG(st.st_mode))
      throw std::runtime_error("Settings destination is not a regular file");
    if (replace && fchmod(fileno(file), st.st_mode & 0777) != 0)
      throw posix_error("Preserve settings permissions", errno);
  } else if (errno != ENOENT) {
    throw posix_error("Inspect settings destination", errno);
  }
  FILE* closing = file;
  file = nullptr;
  if (fclose(closing) != 0) throw posix_error("Close settings file", errno);
  if (replace) {
    if (rename(temporary.c_str(), destination.c_str()) != 0)
      throw posix_error("Replace settings file", errno);
  } else {
    // link fails with EEXIST: a concurrent first run must not overwrite state.
    if (link(temporary.c_str(), destination.c_str()) != 0)
      throw posix_error("Import settings file", errno);
    unlink(temporary.c_str());
  }
  temporary.clear();
}
#endif
