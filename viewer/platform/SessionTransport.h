/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_SESSION_TRANSPORT_H
#define TIDYVNC_SESSION_TRANSPORT_H

#include <chrono>
#include <memory>
#include <viewer/platform/SessionWakeup.h>

namespace rdr { class InStream; class OutStream; }
namespace viewer {
class TransportControl : public SchedulerWakeup {
public:
  // Any thread. Irreversible for this attempt, idempotent and nonblocking.
  // Interrupts IO and both waits without touching worker-owned stream state.
  // Does not cancel an authentication rendezvous; the host must do that too.
  // Retained controls become harmless after the transport has been destroyed.
  virtual void cancel() noexcept = 0;
};

struct TransportReady {
  bool readable = false;
  bool writable = false;
  bool woken = false;
  bool peerClosed = false;
  bool timedOut = false;
  bool cancelled = false;
};

// Owns one established connection, with no UI loop or internally owned threads.
// Only the session worker accesses streams/flush/outputPending/wait. One separate
// observer may call waitPeerClosure while that worker is parked on authentication.
// Stream availability checks and flush must not block waiting for network IO;
// insufficient input/output capacity returns no progress for the next wait.
// Destroy only after protocol cleanup and after both wait callers have drained.
class SessionTransport {
public:
  using Clock = std::chrono::steady_clock;
  using TimePoint = Clock::time_point;
  virtual ~SessionTransport() = default;
  virtual rdr::InStream& input() = 0;
  virtual rdr::OutStream& output() = 0;
  virtual void flush() = 0;
  virtual bool outputPending() = 0;
  virtual std::shared_ptr<TransportControl> control() const = 0;

  // Absolute monotonic deadline (max means indefinite). Write interest is
  // explicit: enable only while outputPending(), otherwise writable sockets
  // spin. Readiness is advisory; the worker must check buffered protocol work
  // before waiting and recheck commands/timers after every return. Several flags
  // may be set together, including readable + peerClosed (unread final bytes).
  // IO failures throw std::system_error with an operation and native error code.
  virtual TransportReady wait(TimePoint deadline, bool wantWrite = false) = 0;

  // Observes FIN/error without consuming or peeking at any protocol bytes.
  // Ignores ordinary incoming data and worker wakeups. Returns only peerClosed,
  // timedOut or cancelled. Peer closure is sticky until transport destruction.
  virtual TransportReady waitPeerClosure(TimePoint deadline) = 0;
};
}
#endif
