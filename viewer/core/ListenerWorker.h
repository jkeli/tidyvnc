/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_LISTENER_WORKER_H
#define TIDYVNC_LISTENER_WORKER_H
#include <viewer/core/SessionWorker.h>
#include <viewer/platform/ListenerSource.h>
namespace viewer {
enum class ListenerState { Starting, Listening, Stopping, Closed, Failed };
struct IncomingPeer {
  uint64_t id = 0; // Monotonic, scoped to this listener handle; never reused.
  ListenerAddress address;
};
struct ListenerSnapshot {
  ListenerState state = ListenerState::Starting;
  ListenerErrorCode error = ListenerErrorCode::None;
  int nativeError = 0;
  size_t pending = 0;
  std::shared_ptr<const std::vector<ListenerAddress>> addresses;
};
enum class ListenerEventKind { State, Incoming, Accepted, Rejected, Expired };
struct ListenerEvent {
  uint64_t sequence = 0;
  ListenerEventKind kind = ListenerEventKind::State;
  ListenerSnapshot snapshot;
  std::shared_ptr<const IncomingPeer> peer;
};
class ListenerWorker;
// Single retained consumer queue, beginning with the Starting snapshot. Ordered
// transitions/peer events are bounded; overflow closes the listener and preserves
// queued events plus reserved Stopping/Failed terminal delivery. No UI callbacks.
class ListenerEvents {
public:
  ~ListenerEvents();
  ListenerSnapshot snapshot() const;
  bool take(ListenerEvent& event);
private:
  explicit ListenerEvents(size_t capacity);
  struct Impl;
  std::unique_ptr<Impl> impl;
  friend class ListenerWorker;
};
struct ListenerOptions {
  // Coalesced readiness notification, invoked outside listener locks. The host
  // drains the ordered event queue; wake must be nonblocking and noexcept.
  std::shared_ptr<MailboxWakeup> mailboxWakeup;
  size_t pendingCapacity = 8; // 1..64 accepted sockets awaiting host decision.
  size_t eventCapacity = 32; // 4..4096, plus two terminal slots.
  std::chrono::milliseconds pendingTimeout{30000}; // 1..60000; monotonic.
};
enum class PeerAdmission { Accepted, NotPending, Expired, Closing, EventCapacity };
struct AcceptedPeer {
  PeerAdmission status = PeerAdmission::NotPending;
  std::shared_ptr<const IncomingPeer> peer;
  std::unique_ptr<SessionTransport> transport;
};
class ListenerRuntime;
class ListenerWorker {
public:
  ~ListenerWorker(); // Requests stop, never joins.
  ListenerWorker(const ListenerWorker&) = delete;
  ListenerWorker& operator=(const ListenerWorker&) = delete;
  std::shared_ptr<ListenerEvents> events() const;
  // Atomic ownership handoff. Stale/duplicate IDs cannot consume another peer.
  // No RFB/authentication data is read until the host admits this transport.
  AcceptedPeer takePeer(uint64_t incomingId);
  PeerAdmission reject(uint64_t incomingId);
  // Convenience handoff into the bounded session runtime with explicit security.
  // Returns null on stale/expired/closing IDs or event-capacity failure.
  // Runtime construction/admission
  // exceptions consume and close the peer; they never put it back in the queue.
  std::shared_ptr<SessionWorker> accept(uint64_t incomingId, SessionRuntime& runtime,
    const rfb::SecurityClient& security, const SessionWorkerOptions& options = {});
  std::shared_future<ListenerSnapshot> closeAndDrain() noexcept;
  std::shared_future<ListenerSnapshot> drained() const;
private:
  struct State;
  explicit ListenerWorker(std::shared_ptr<State> state);
  std::shared_ptr<State> state;
  friend class ListenerRuntime;
};
// App-owned listener service, separate from session lifetime. Accepted sessions
// survive listener stop. Bounded workers plus one join coordinator, no detached
// threads. Destroy on an app service/shutdown thread, never the UI thread. Finish
// concurrent API calls before destruction; shutdown() itself does not join.
class ListenerRuntime {
public:
  explicit ListenerRuntime(size_t capacity = 4); // 1..16
  ~ListenerRuntime();
  ListenerRuntime(const ListenerRuntime&) = delete;
  ListenerRuntime& operator=(const ListenerRuntime&) = delete;
  std::shared_ptr<ListenerWorker> listen(std::unique_ptr<ListenerSource> source,
                                        const ListenerOptions& options = {});
  void shutdown() noexcept;
  std::shared_future<void> drained() const;
  size_t active() const;
private:
  struct Impl;
  std::unique_ptr<Impl> impl;
};
}
#endif
