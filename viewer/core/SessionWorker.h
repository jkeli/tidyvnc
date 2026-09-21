/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_SESSION_WORKER_H
#define TIDYVNC_SESSION_WORKER_H

#include <viewer/core/PromptAuthentication.h>
#include <viewer/platform/SessionTransport.h>
#include <viewer/platform/ConnectionAttempt.h>
#include <future>

namespace viewer {
using WorkerResultCode = SessionEndReason;
enum class CommandAdmission { Accepted, Closing, NotConnected, StaleGeneration, QueueFull, EventCapacity,
                              Busy, Unsupported, GenerationExhausted, ResourceLimit, ViewOnly,
                              Unfocused, Disabled, Echo, InvalidValue };
struct CommandSubmission {
  CommandSubmission(CommandAdmission status_, uint64_t operation_ = 0, uint64_t generation_ = 0)
    : status(status_), operation(operation_), generation(generation_) {}
  CommandAdmission status;
  uint64_t operation; // Zero rejects without mutation or a completion obligation.
  uint64_t generation; // Connect returns the new attempt generation immediately.
};
enum class CommandCancellation { Cancelled, NotPending, StaleGeneration };
struct WorkerResult {
  WorkerResultCode code = WorkerResultCode::InternalFailure;
  int nativeError = 0;
};
struct SessionWorkerOptions {
  rfb::ClientMessageLimits messages;
  SessionBufferLimits buffers;
  EncodingOptions encoding;
  bool shared = false; // RFB ClientInit: preserve the retained viewer default.
  ClipboardPolicy clipboard;
  std::chrono::milliseconds promptTimeout{60000};
  std::chrono::milliseconds statisticsInterval{100};
  std::chrono::milliseconds publicationRetryInterval{16};
  std::chrono::milliseconds desktopResizeTimeout{10000};
  std::chrono::milliseconds pointerEventInterval{0};
  size_t eventCapacity = 128;
  size_t commandCapacity = 32; // 1..256 fixed-size entries, independent of input.
  // Executes on the protocol worker. Must enqueue a notification and return;
  // never wait for the UI, enter protocol processing, or retain this worker.
  PromptAuthentication::RequestReady promptReady;
  // Internal readiness for event/view/prompt mailboxes and joined drain.
  std::weak_ptr<MailboxWakeup> mailboxWakeup;
};

struct SessionSharingSnapshot {
  bool shared, editable;
  uint64_t revision, generation;
};
struct SessionSecuritySnapshot {
  std::shared_ptr<const rfb::SecurityClient> options;
  uint64_t revision, generation;
  bool editable;
};
class SessionRuntime;
// An attempt or reusable logical session. All accessors and commands are safe on
// any thread. Destruction requests cancellation only; it never joins a thread.
// Mailboxes/leases may outlive this handle. Prompt IDs are scoped to this handle,
// not transferable to another attempt's authentication bridge.
class SessionWorker {
public:
  ~SessionWorker();
  SessionWorker(const SessionWorker&) = delete;
  SessionWorker& operator=(const SessionWorker&) = delete;
  std::shared_ptr<SessionEvents> events() const;
  // Includes a newly admitted connect before its worker publishes state. Use
  // this to reject delivery queued by an earlier attempt immediately on connect.
  uint64_t generation() const;
  std::shared_ptr<FrameSubscription> view() const;
  std::shared_ptr<InputQueue> input() const;
  std::shared_ptr<PromptAuthentication> authentication() const;
  std::shared_ptr<ClipboardChannel> clipboard() const;
  // Policy changes invalidate old routing tokens immediately; protocol cleanup
  // is woken automatically. Send and receive are independent, session-owned flags.
  void setClipboardPolicy(ClipboardPolicy policy);
  // Owns normalized text before admission. One queued offer/withdrawal at a
  // time; completion means protocol announcement/send, not a remote OS write.
  // Tag remote-origin pasteboard changes to suppress automatic echoes.
  CommandSubmission offerClipboard(uint64_t generation, const std::string& text,
                                    const ClipboardLease& origin = {}, uint64_t changeId = 0);
  CommandSubmission clearClipboard(uint64_t generation);
  // createSession() handles only. Takes ownership even on rejection. Connect
  // requires the previous attempt's disconnect completion/terminal cleanup;
  // Busy never queues an implicit reconnect. A reserved completion succeeds at
  // RFB Connected, or fails/cancels after setup/authentication failure or close.
  CommandSubmission connect(std::unique_ptr<ConnectionAttempt> connection);
  // Cancels the current attempt, preserving this session's mailboxes/settings.
  // Completion is published after transport/observer/decoder drain; the session
  // worker remains idle and available for connect. Use closeAndDrain permanently.
  CommandSubmission disconnect(uint64_t generation);
  // Any thread. Connected/current-generation only. Admission reserves exactly
  // one event completion before enqueueing and wakes the executor. Completion
  // means scheduled at a safe protocol boundary, not server acknowledgement.
  CommandSubmission requestRefresh(uint64_t generation);
  CommandSubmission applyEncodingOptions(uint64_t generation, const EncodingOptions& options);
  // Copies validated remote-pixel geometry before returning. One queued/on-wire
  // request per session. Completion reports the server reply, timeout or close;
  // origin is an opaque host correlation value echoed by the completion.
  CommandSubmission requestDesktopLayout(uint64_t generation, const RemoteDesktopLayout& layout,
                                         uint64_t origin = 0);
  EncodingOptions encodingOptions() const;
  SessionSecuritySnapshot securityOptions() const;
  SessionSharingSnapshot sharing() const;
  CommandAdmission setShared(uint64_t generation, uint64_t revision, bool shared);
  // Synchronous compare-and-replace between fully drained attempts. No protocol
  // work or library IO on the caller; stale/active/closed rejection is atomic.
  // Accepted policy is installed by the worker before the next attempt starts.
  CommandAdmission setSecurity(uint64_t generation, uint64_t revision,
                               const rfb::SecurityClient& options);
  // Refresh/encoding/layout/clipboard cancellation wins only while queued. Connect cancellation
  // directly interrupts setup/authentication until its successful completion;
  // cancellation completes after attempt drain. Disconnect is already committed
  // on admission and cannot be undone. No completed operation history is retained.
  CommandCancellation cancelOperation(uint64_t generation, uint64_t operation);
  // Wake after submitting input/focus/view-only changes to the mailbox.
  void wake() noexcept;
  // Directly cancels prompts and wakes IO readiness, including when parked.
  // The worker attempts input release/TLS close before final socket shutdown.
  // Idempotent; the same shared future is returned on every call. Completion
  // means both threads joined and protocol/transport resources destroyed, not
  // merely that a terminal event has been queued. Never wait on a UI thread.
  std::shared_future<WorkerResult> closeAndDrain() noexcept;
  std::shared_future<WorkerResult> drained() const;
private:
  struct State;
  explicit SessionWorker(std::shared_ptr<State> state_);
  std::shared_ptr<State> state;
  friend class SessionRuntime;
};

// Application service owning a bounded number (1..64) of worker handles and
// one join coordinator. No detached threads. Session-handle release is nonblocking.
// shutdown() requests cancellation without joining; drained() signals that all
// admitted jobs have joined. Destroy this service on an app service/shutdown
// thread, never on a session callback or UI thread: destruction joins its own
// coordinator. Keep it alive across native windows and reconnect attempts.
// Finish concurrent API calls before destroying the service; drain futures cover
// admitted jobs, not callers still constructing an admission request.
class SessionRuntime {
public:
  explicit SessionRuntime(size_t capacity = 16);
  ~SessionRuntime();
  SessionRuntime(const SessionRuntime&) = delete;
  SessionRuntime& operator=(const SessionRuntime&) = delete;
  // Bounded logical session with one persistent serialized worker. Idle sessions
  // occupy one runtime slot; mailboxes, prompt IDs and settings survive attempts.
  std::shared_ptr<SessionWorker> createSession(const rfb::SecurityClient& security,
    const SessionWorkerOptions& options = SessionWorkerOptions());
  // Owns transport even on failure. Invalid arguments throw invalid_argument;
  // closed/full runtime rejects with logic_error/length_error before admission.
  // Security is explicit: no concurrent reads of the legacy option registry.
  std::shared_ptr<SessionWorker> start(std::unique_ptr<SessionTransport> transport,
    const std::string& serverName, const rfb::SecurityClient& security,
    const SessionWorkerOptions& options = SessionWorkerOptions());
  // Admit prepared endpoint work immediately; DNS/connect and all progress
  // publication run on the session worker. Close directly cancels setup waits.
  std::shared_ptr<SessionWorker> connect(std::unique_ptr<ConnectionAttempt> connection,
    const rfb::SecurityClient& security, const SessionWorkerOptions& options = SessionWorkerOptions());
  void shutdown() noexcept;
  std::shared_future<void> drained() const;
  size_t active() const;
private:
  std::shared_ptr<SessionWorker> admit(std::shared_ptr<SessionWorker::State> state);
  struct Impl;
  std::unique_ptr<Impl> impl;
};
}
#endif
