/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_SESSION_EVENTS_H
#define TIDYVNC_SESSION_EVENTS_H
#include <cstddef>
#include <cstdint>
#include <memory>
#include <array>
#include <rfb/PixelFormat.h>
#include <viewer/core/RemoteDesktopLayout.h>
#include <viewer/platform/MailboxWakeup.h>

namespace viewer {
enum class SessionState { Idle, Negotiating, Connected, Closed, Failed, Authenticating, Disconnecting,
                          Resolving, Connecting };
enum class SessionEndReason {
  Cancelled, PeerClosed, PromptTimedOut, AuthenticationRejected,
  TransportFailure, ProtocolFailure, ResourceFailure, InternalFailure,
  EventOverflow, None, ResolutionFailure, ConnectionFailure, ResolutionTimedOut,
  ConnectionTimedOut, UnsupportedEndpoint, InvalidEndpoint
};
enum class SessionEventKind { Snapshot, State, Desktop, Bell, Statistics, Completion, Overflow };
enum class OperationResult { Succeeded, Cancelled, Failed };
enum class OperationFailure { None, TimedOut, ServerRejected };
// Bounded immutable observation payload, copied on the protocol executor.
// No endpoint, credentials, certificates or filesystem paths are included.
struct SessionInformation {
  std::array<char,1025> desktopName{};
  bool nameTruncated = false, secure = false;
  uint32_t protocolMajor = 0, protocolMinor = 0, securityType = 0;
  int requestedEncoding = -1, lastEncoding = -1;
  uint64_t bitsPerSecond = 0;
  rfb::PixelFormat pixelFormat;
};
struct SessionSnapshot {
  uint64_t generation = 1, frames = 0, bells = 0;
  uint32_t width = 0, height = 0;
  SessionState state = SessionState::Idle;
  SessionEndReason endReason = SessionEndReason::None;
  int nativeError = 0;
  bool supportsDesktopResize = false, resizePending = false;
  std::shared_ptr<const RemoteDesktopLayout> layout;
  std::shared_ptr<const SessionInformation> information;
};
struct SessionEvent {
  SessionEventKind kind = SessionEventKind::Snapshot;
  uint64_t sequence = 0, operation = 0;
  SessionSnapshot snapshot;
  OperationResult result = OperationResult::Succeeded;
  OperationFailure failure = OperationFailure::None;
  uint32_t nativeResult = 0;
  uint64_t origin = 0; // Host-supplied correlation value; no protocol meaning.
};
// One ordered consumer per queue. take/snapshot/sealed may run on any thread;
// state publication belongs to the serialized owning executor. reserve/complete
// may also run on command admission/cancellation threads. Internal locking
// makes producer/consumer access safe; there are no host callbacks. Fixed-size
// records and preallocated storage bound queue memory. Layouts are immutable
// retained payloads of at most 255 screens each. Connection information is a
// fixed-size immutable payload with at most 1024 desktop-name bytes. Operation
// IDs are queue-local; pair them with the queue identity and event generation.
class SessionEvents {
public:
  explicit SessionEvents(SessionSnapshot initial, size_t capacity = 128);
  ~SessionEvents();
  SessionEvents(const SessionEvents&) = delete;
  SessionEvents& operator=(const SessionEvents&) = delete;
  bool take(SessionEvent& event);
  // Replaces the weak internal readiness target and signals an initial check.
  // Notifications may coalesce or be spurious; drain take() on each wake.
  void setWakeup(std::weak_ptr<MailboxWakeup> wakeup);
  SessionSnapshot snapshot() const;
  // Zero means rejected: no completion is owed. A nonzero ID reserves capacity
  // for exactly one completion, including when the queue subsequently overflows.
  // Accepts the current generation, or a future generation already reserved by
  // reserveAttempt (e.g. immediate disconnect before the worker starts setup).
  // Operations from different generations may never be pending together.
  uint64_t reserve(uint64_t generation, uint64_t origin = 0);
  // Reusable-session owner only, between drained attempts. Reserves a connect
  // completion for a strictly newer generation without publishing that state
  // from the admission thread. No other pending operation may span the boundary.
  uint64_t reserveAttempt(uint64_t generation);
  // Observation only. The command owner arbitrates dequeue versus cancellation;
  // this does not hold a queue lock across protocol execution.
  bool pending(uint64_t operation, uint64_t generation) const;
  bool complete(uint64_t operation, OperationResult result,
                OperationFailure failure = OperationFailure::None, uint32_t nativeResult = 0);
  // Statistics are replaceable; other events cannot be dropped. On exhaustion,
  // pending operations fail and one out-of-band Overflow terminates this stream.
  bool publish(SessionEventKind kind, SessionSnapshot snapshot);
  void cancelPending(OperationResult result);
  // Preserve queued events, complete pending operations and seal the stream.
  void seal(OperationResult pendingResult);
  bool sealed() const;
private:
  struct Impl;
  std::unique_ptr<Impl> impl;
};
}
#endif
