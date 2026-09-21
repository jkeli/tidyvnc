/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_STARTUP_LOGGING_H
#define TIDYVNC_STARTUP_LOGGING_H
#include "LoggingPolicy.h"
#include <core/LogWriter.h>
#include <functional>
#include <memory>
#include <mutex>
#include <vector>

namespace viewer {
class RedactedLogger;
class LoggingFrozen : public std::logic_error {
public:
  LoggingFrozen() : std::logic_error("Logging startup is closed") {}
};
// One process startup owner. The host captures registered writers after static
// initialization, configures at most once, then freezes before any worker starts.
// Validation reads immutable metadata; configure/freeze admission is serialized.
// Writes never take
// this owner's lock. Construction/configuration/destruction are host operations,
// not session operations. Existing legacy routing is untouched unless configured.
class StartupLogging {
public:
  using Factory = std::function<std::unique_ptr<core::Logger>(const std::string&)>;
  StartupLogging(std::vector<core::LogWriter*> writers, std::vector<std::string> targets);
  // All workers must have joined before destruction. Every owned binding is
  // detached before any sink is destroyed. Destinations are then flushed/closed
  // by their own destructors. Raw sinks are never registered or exposed.
  ~StartupLogging();
  void validate(const LoggingPolicy& policy) const;
  // Resolve all rules and construct every needed redacted destination before
  // publishing any writer change. Factory must return an owned sink, must not
  // modify logging/registry state, and must not re-enter this owner. It is only
  // called for destinations used by the final routes, once each. Failure leaves
  // writer routing and admission unchanged; factory external effects are its
  // responsibility (e.g. it should defer file creation until first output).
  void configure(const LoggingPolicy& policy, const Factory& factory);
  // Also closes startup when no explicit configuration was installed. Later
  // configure attempts fail, including after all runtimes have been destroyed.
  void freeze();
private:
  struct Destination;
  std::mutex mutex;
  const std::vector<core::LogWriter*> writers;
  const std::vector<std::string> names, targets;
  std::vector<std::unique_ptr<Destination>> destinations;
  bool frozen = false, installed = false;
};
}
#endif
