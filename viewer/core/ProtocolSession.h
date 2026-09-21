/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_PROTOCOL_SESSION_H
#define TIDYVNC_PROTOCOL_SESSION_H

#include <viewer/core/FramePublisher.h>
#include <viewer/core/InputQueue.h>
#include <viewer/core/MiddleButtonEmulator.h>
#include <viewer/core/SessionEvents.h>
#include <viewer/core/EncodingOptions.h>
#include <viewer/core/SessionScheduler.h>
#include <viewer/core/ClipboardChannel.h>
#include <rfb/SecurityClient.h>
#include <rfb/ClientMessageLimits.h>
#include <memory>
#include <string>

namespace rdr { class InStream; class OutStream; }
namespace viewer {

// Synchronous protocol seam, retained by the session. PromptAuthentication
// supplies a cancellable worker rendezvous; no UI event loop belongs in core.
class SessionAuthentication {
public:
  virtual ~SessionAuthentication() = default;
  virtual void beginAttempt(uint64_t, const std::string&) {}
  virtual void cancelPending() noexcept {}
  virtual void credentials(bool secure, std::string* username, std::string* password) = 0;
  // The negotiated subtype is captured on the protocol worker at the prompt.
  // Legacy adapters may continue implementing the original callback.
  virtual void credentialsForSecurity(uint32_t, bool secure, std::string* username, std::string* password) {
    credentials(secure, username, password);
  }
  virtual bool certificate(unsigned int, const uint8_t*, size_t) { return false; }
  virtual bool hostKey(const uint8_t*, size_t, const char*) { return false; }
};
struct SessionBufferLimits {
  size_t framebufferBytes = 64 * 1024 * 1024;
  size_t publicationBytes = 128 * 1024 * 1024;
  size_t subscribers = 16;
  size_t inputCommands = 256;
  size_t heldKeys = 64;
  size_t clipboardTextBytes = 256 * 1024;
  size_t clipboardRetainedBytes = 1024 * 1024;
};
struct SessionDesktop {
  bool active = false, ready = false;
  uint32_t width = 0, height = 0;
  uint64_t generation = 1, bells = 0;
  std::string name;
};
struct SessionTiming {
  std::chrono::milliseconds statisticsInterval{100};
  std::chrono::milliseconds publicationRetryInterval{16};
  std::chrono::milliseconds desktopResizeTimeout{10000};
  // Zero preserves the unthrottled low-level protocol seam. Desktop frontends
  // explicitly select their policy; the retained viewer default is 17 ms.
  std::chrono::milliseconds pointerEventInterval{0};
  // Worker-only clock, injectable for deterministic tests. Must be monotonic.
  std::function<SessionScheduler::TimePoint()> now = SessionScheduler::Clock::now;
  std::shared_ptr<SchedulerWakeup> wakeup;
};
enum class SessionTerminalOwnership { Protocol, Host };

// A window-independent RFB attempt owner, driven by the host's serialized
// executor. Transport readiness, command/event lifecycle and async drain are
// separate layers. Subscription take/release and InputQueue operations may run
// on other threads; all protocol operations stay on the owning worker.
// Authentication handlers must not reenter processMessage/close/publication.
class ProtocolSession {
public:
  ProtocolSession(const rfb::SecurityClient& security,
                  const rfb::ClientMessageLimits& messages = rfb::ClientMessageLimits(),
                  const SessionBufferLimits& buffers = SessionBufferLimits(),
                  std::shared_ptr<SessionAuthentication> authentication = nullptr,
                  const EncodingOptions& encoding = EncodingOptions(),
                  const SessionTiming& timing = SessionTiming(),
                  SessionTerminalOwnership terminalOwnership = SessionTerminalOwnership::Protocol,
                  ClipboardPolicy clipboardPolicy = {}, bool shared = false);
  ~ProtocolSession();
  ProtocolSession(const ProtocolSession&) = delete;
  ProtocolSession& operator=(const ProtocolSession&) = delete;

  // Borrowed streams must outlive close(). No socket or native handle is exposed.
  // Start is allowed only without an active attempt; reconnect creates a fresh
  // CConnection with the configured security, unchanged limits and newer generation.
  void start(const std::string& serverName, rdr::InStream& input, rdr::OutStream& output);
  // Worker-only, no active connection. A host preparing DNS/connect can advance
  // identity before streams exist. Equal publisher generation is allowed after
  // close already invalidated old frames; never move backwards or reuse an
  // attempt's event generation. Publishes Idle for the new attempt.
  void prepareAttempt(uint64_t generation);
  // Worker-only, between drained attempts. The next CConnection owns this copy.
  void setSecurity(const rfb::SecurityClient& options);
  void setShared(bool shared);
  bool processMessage();
  // failed is for failures detected by the host (e.g. a readiness wait), outside
  // processMessage(). Already-terminal attempts are unaffected.
  void close(bool failed = false);
  SessionDesktop desktop() const;
  // Worker-only latest counters/state, including statistics not yet published.
  SessionSnapshot snapshot() const { return eventState; }
  std::shared_ptr<FrameSubscription> attachView();
  // Dropping the last subscription reference detaches it. Retained leases live on.
  // Retry a backpressured frame/cursor only after a complete protocol update.
  // Returns false while an update is in progress or publication remains blocked.
  bool retryPublication();
  size_t publicationBytesInUse() const;
  std::shared_ptr<InputQueue> inputQueue() const;
  std::shared_ptr<ClipboardChannel> clipboard() const { return clipboardMailbox; }
  // Prepared local text is generation/focus/policy tagged and budgeted by the
  // channel. Completion means announced/sent, not remote pasteboard acceptance.
  uint64_t offerClipboard(ClipboardLease text, uint64_t operation = 0);
  uint64_t clearClipboard(uint64_t operation = 0);
  // Worker-only. Processes at most inputCommands + one release barrier per call.
  // Returns false after held-key overflow; the mailbox records the fault and
  // requires explicit focus reactivation before accepting more input.
  bool drainInput();
  // Worker-only subscription: one lifecycle coordinator, independent of views.
  // Starts with the current snapshot. Retain and take events on any thread.
  std::shared_ptr<SessionEvents> subscribeEvents(size_t capacity = 128);
  // Requires a connected session and event subscriber. Zero rejects without
  // changing protocol state; completion means the refresh request was scheduled.
  // A nonzero operation must already be reserved in this event stream/generation.
  // The worker uses this to execute an asynchronously admitted command without
  // reserving a second completion; that caller must then complete the reservation.
  // The caller owns arbitration of execution versus cancellation for that token.
  // Zero retains synchronous admission and completion behavior.
  uint64_t requestRefresh(uint64_t operation = 0);
  // Worker-only, connected sessions with an event coordinator. Zero means no
  // admission and no mutation. Completion means policy scheduled for a safe RFB
  // update boundary, not acknowledgement from the server. Persists on reconnect.
  uint64_t applyEncodingOptions(const EncodingOptions& options, uint64_t operation = 0);
  // One request on the wire at a time. Zero rejects without writing or reserving.
  // A nonzero accepted operation is completed here only after a client-reason
  // ExtendedDesktopSize reply, timeout or close. Caller-reserved operations
  // transfer completion ownership on success. origin is retained in completions.
  uint64_t requestDesktopLayout(const RemoteDesktopLayout& layout,
                               uint64_t operation = 0, uint64_t origin = 0);
  EncodingOptions encodingOptions() const { return encoding; }
  // Worker-only event-loop seam. After commands/IO, query the next deadline and
  // wait for IO, wakeup or that deadline; dispatch timers even with no socket IO.
  // No OS descriptors or process-global Timer queue are involved.
  bool nextDeadline(SessionScheduler::TimePoint& deadline) const;
  size_t dispatchScheduled(size_t budget = 2);

private:
  bool emit(SessionEventKind kind);
  void authenticating();
  void finish(bool failed);
  void scheduleStatistics();
  bool sendInput(const InputQueue::Command& command);
  void sendMiddleBatch(const MiddleButtonEmulator::Batch& batch);
  void resetMiddle();
  void sendPointer(const InputQueue::Command& command);
  void resetPointer();
  void flushPointer();
  void publicationResult(bool published);
  SessionScheduler::TimePoint deadlineAfter(std::chrono::milliseconds interval) const;
  class Connection;
  rfb::SecurityClient security;
  bool shared;
  const rfb::ClientMessageLimits messages;
  const SessionBufferLimits buffers;
  EncodingOptions encoding;
  const SessionTiming timing;
  // Host ownership still cleans protocol resources on error, but leaves terminal
  // publication, remaining completions and sealing to the host's classified exit.
  const SessionTerminalOwnership terminalOwnership;
  SessionScheduler scheduler;
  SessionScheduler::Token statisticsTimer, publicationTimer;
  SessionScheduler::Token desktopResizeTimer, middleTimer;
  SessionScheduler::Token pointerTimer;
  InputQueue::Command pendingPointer;
  uint16_t lastPointerButtons = 0;
  MiddleButtonEmulator middle;
  uint64_t middleRevision = 0;
  uint64_t desktopResizeOperation = 0;
  std::shared_ptr<SessionAuthentication> authentication;
  FramePublisher publisher;
  const std::shared_ptr<InputQueue> inputMailbox;
  const std::shared_ptr<ClipboardChannel> clipboardMailbox;
  std::unique_ptr<Connection> connection;
  bool processing = false;
  SessionSnapshot eventState;
  std::weak_ptr<SessionEvents> eventObserver;
};
}
#endif
