/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_WINDOWS_STANDARD_STREAM_H
#define TIDYVNC_WINDOWS_STANDARD_STREAM_H
// Duplicates a standard stream's CRT descriptor for an owned logging sink.
// A GUI-subsystem process usually has no standard handles (_fileno returns a
// negative value), and a process may close descriptors 1 and 2 later; the CRT
// treats _dup on a closed descriptor as an invalid parameter and terminates
// by default. A thread-local no-op handler turns that into a -1 result, so
// the caller discards output instead (plans/native-ui-winui CORE.md section 4).
#include <cstdio>
#include <cstdlib>
#include <io.h>

namespace viewer { namespace winio {
inline void ignoreInvalidParameter(const wchar_t*, const wchar_t*, const wchar_t*, unsigned, uintptr_t) {}

inline int duplicateStandardStream(FILE* stream)
{
  const int source = _fileno(stream);
  if (source < 0) return -1;
  const auto previous = _set_thread_local_invalid_parameter_handler(ignoreInvalidParameter);
  const int duplicate = _dup(source);
  _set_thread_local_invalid_parameter_handler(previous);
  return duplicate;
}
} }
#endif
