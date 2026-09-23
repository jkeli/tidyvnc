/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_PRIVATE_FILE_LOGGER_H
#define TIDYVNC_PRIVATE_FILE_LOGGER_H
#include <core/Logger_file.h>
#include <stdexcept>
#include <string>

namespace viewer {
class LogFilePathError : public std::invalid_argument {
public:
  LogFilePathError() : std::invalid_argument("Invalid logging file path") {}
};
// Raw destination, always wrapped in RedactedLogger by native startup.
// Construction validates/copies an absolute path without filesystem access
// (POSIX: starts with '/'; Windows: drive-letter or UNC, windows/ adapter).
// First output creates a private file and rotates one owned regular predecessor
// to .bak. A private .lock sidecar serializes cooperating native processes.
// Existing symlinks, hard links, foreign-owned entries and unsafe directories
// are refused. Publication never overwrites an unexpected directory entry.
// Failure is nonfatal to protocol workers: switch once to an owned stderr
// duplicate and emit a fixed warning. No path or errno text enters that warning.
class PrivateFileLogger final : public core::Logger_File {
public:
  static const char* defaultPath();
  static void validatePath(const std::string& path);
  explicit PrivateFileLogger(const std::string& path);
  ~PrivateFileLogger();
  void write(int level, const char* source, const char* message) override;
private:
  using core::Logger_File::setFile;
  using core::Logger_File::setFilename;
  void initialize();
  void useStandardError();
  const std::string directory, filename, backup, lockname;
#ifdef _WIN32
  void* lockHandle = nullptr; // HANDLE of the .lock sidecar while held.
#else
  int lockDescriptor = -1;
#endif
  bool initialized = false, fallback = false;
};
}
#endif
