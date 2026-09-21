/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_REDACTED_LOGGER_H
#define TIDYVNC_REDACTED_LOGGER_H
#include <core/Logger.h>
#include <string>
#include <vector>

namespace viewer {
// Native diagnostic adapter. Known event templates retain their fixed wording;
// strings/pointers are removed BEFORE printf can inspect the arguments. Audited
// numeric protocol versions, sizes, flags and status codes remain useful. Key
// press/release events are suppressed. Unknown formats and preformatted text
// receive a fixed fallback. Untrusted writer names never enter output.
// Construct on the startup owner before workers (captures gettext translations).
// Does not register itself, open a destination or change global LogWriter policy.
// The host must keep destination and this adapter alive until writers have joined.
class RedactedLogger final : public core::Logger {
public:
  RedactedLogger(const char* name, core::Logger& destination);
  void write(int level, const char* source, const char* text) override;
  void write(int level, const char* source, const char* format, va_list args) override;
private:
  struct Pattern {
    const char *source, *format, *message;
    bool numeric;
    std::string translated;
  };
  static std::vector<Pattern> capturePatterns();
  static const char* safeSource(const char* source);
  void emit(int level, const char* source, const char* message);
  core::Logger& destination;
  const std::vector<Pattern> patterns;
};
}
#endif
