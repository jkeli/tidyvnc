/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_CONNECTION_ATTEMPT_H
#define TIDYVNC_CONNECTION_ATTEMPT_H
#include <viewer/platform/SessionTransport.h>
#include <functional>
#include <stdexcept>
#include <string>

namespace viewer {
enum class ConnectionPhase { Resolving, Connecting };
enum class ConnectionErrorCode { Cancelled, TimedOut, Resolution, Connection, Unsupported, InvalidAddress };
class ConnectionError : public std::runtime_error {
public:
  ConnectionError(ConnectionErrorCode code_, ConnectionPhase phase_, int nativeError_ = 0)
    : std::runtime_error("Connection setup failed"), code(code_), phase(phase_), nativeError(nativeError_) {}
  const ConnectionErrorCode code;
  const ConnectionPhase phase;
  const int nativeError; // Resolver or socket code, distinguished by phase.
};

// Prepared, single-use connection work. Construction performs no DNS/connect.
// run() belongs to one worker; progress runs there and must return promptly.
// cancel() on the retained control interrupts run() directly, without a queued
// worker command. No OS handles, detached resolver threads or UI loop are exposed.
// Destroy only after run() returns; controls must remain safe after destruction.
class ConnectionAttempt {
public:
  using Progress = std::function<void(ConnectionPhase)>;
  virtual ~ConnectionAttempt() = default;
  virtual std::string serverName() const = 0;
  virtual std::shared_ptr<TransportControl> control() const = 0;
  virtual std::unique_ptr<SessionTransport> run(const Progress& progress) = 0;
};
}
#endif
