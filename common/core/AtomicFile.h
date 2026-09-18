// Original TidyVNC work, 2026. SPDX-License-Identifier: GPL-2.0-or-later
#ifndef TIDYVNC_ATOMIC_FILE_H
#define TIDYVNC_ATOMIC_FILE_H
#ifndef _WIN32
#include <string>
#include <stdio.h>
namespace core {
// Same-directory temporary file, private by default. Commit preserves existing
// regular-file permissions and rejects symlinks. Uncommitted files are removed.
class AtomicFile {
public:
  explicit AtomicFile(const char* destination);
  ~AtomicFile();
  FILE* stream() const { return file; }
  void commit(bool replace = true);
private:
  AtomicFile(const AtomicFile&) = delete;
  AtomicFile& operator=(const AtomicFile&) = delete;
  std::string destination, temporary;
  FILE* file;
};
}
#endif
#endif
