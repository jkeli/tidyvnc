/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_CLIPBOARD_CHANNEL_H
#define TIDYVNC_CLIPBOARD_CHANNEL_H
#include <viewer/core/InputQueue.h>
#include <viewer/platform/MailboxWakeup.h>
#include <memory>
#include <string>
namespace viewer {
struct ClipboardPolicy {
  ClipboardPolicy(bool send_ = true, bool receive_ = true) : send(send_), receive(receive_) {}
  bool send, receive;
};
struct ClipboardRoute { uint64_t generation = 0, focus = 0, policy = 0; };
enum class ClipboardResult { Accepted, Stale, NotConnected, Unfocused, ViewOnly, Disabled,
                             Echo, TooLarge, InvalidText, Backpressure };
struct ClipboardBudget;
class ClipboardChannel;
class ClipboardText {
public:
  ~ClipboardText();
  ClipboardText(const ClipboardText&) = delete;
  ClipboardText& operator=(const ClipboardText&) = delete;
  const std::string& text() const { return value; }
  bool fromRemote() const { return remote; }
  ClipboardRoute route() const { return routing; }
private:
  ClipboardText(std::string value, bool remote, ClipboardRoute route, std::shared_ptr<ClipboardBudget> budget);
  const std::string value;
  const bool remote;
  const ClipboardRoute routing;
  const std::shared_ptr<ClipboardBudget> budget;
  friend class ClipboardChannel;
};
using ClipboardLease = std::shared_ptr<const ClipboardText>;
struct ClipboardPrepared { ClipboardResult result; ClipboardLease text; };
enum class ClipboardUpdateKind { Offered, Text, Unavailable, Invalidated, Rejected };
struct ClipboardUpdate {
  uint64_t sequence = 0;
  ClipboardRoute route;
  ClipboardUpdateKind kind = ClipboardUpdateKind::Invalidated;
  ClipboardResult result = ClipboardResult::Accepted;
  ClipboardLease text;
};
// One coalesced receive mailbox, one shared byte budget for all text leases,
// including queued/local offers and externally retained data. No UI callbacks.
// Host must route pasteboard observation to the active session and tag remote
// writes with their lease; passing a remote origin suppresses automatic echoes.
// Recheck the update's route immediately before a deferred native pasteboard
// write. Focus selection and native writes belong to the same host/UI executor.
class ClipboardChannel {
public:
  ClipboardChannel(std::shared_ptr<InputQueue> input, size_t textLimit = 256*1024,
                   size_t retainedLimit = 1024*1024, ClipboardPolicy policy = {});
  ~ClipboardChannel();
  ClipboardChannel(const ClipboardChannel&) = delete;
  ClipboardChannel& operator=(const ClipboardChannel&) = delete;
  // All methods thread-safe. Policy changes invalidate queued routing tokens.
  // Wake the session after changing policy, as for focus/view-only changes.
  void setPolicy(ClipboardPolicy policy);
  ClipboardPolicy policy() const;
  ClipboardRoute route() const;
  ClipboardResult check(ClipboardRoute route, bool sending) const;
  ClipboardResult checkLocal(const ClipboardLease& text) const;
  ClipboardPrepared prepareLocal(uint64_t generation, const std::string& text,
                                 const ClipboardLease& origin = {});
  bool take(ClipboardUpdate& update);
  // Weak internal readiness target; notification occurs outside mailbox locks.
  void setWakeup(std::weak_ptr<MailboxWakeup> wakeup);
  size_t bytesInUse() const;
  // Protocol-worker publication. Expected route also guards a delayed server
  // reply after focus/view-only/policy changes. Data is UTF-8 with LF newlines.
  void offerRemote(bool available);
  void receive(const char* text, ClipboardRoute expected);
  void invalidate();
private:
  struct Impl;
  std::unique_ptr<Impl> impl;
  ClipboardPrepared prepare(const std::string& text, bool remote, ClipboardRoute route);
};
}
#endif
