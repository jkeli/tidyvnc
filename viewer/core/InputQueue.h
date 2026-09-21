/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_INPUT_QUEUE_H
#define TIDYVNC_INPUT_QUEUE_H
#include <cstddef>
#include <cstdint>
#include <memory>

namespace viewer {
class ProtocolSession;
enum class InputResult { Accepted, Coalesced, StaleGeneration, NotConnected,
                         ViewOnly, Unfocused, Overflow, Invalid };
struct InputStatus {
  uint64_t generation = 1, overflows = 0;
  uint64_t routingRevision = 1; // Focus/view-only transitions invalidate delayed clipboard work.
  size_t queued = 0;
  bool connected = false, focused = true, viewOnly = false, releasePending = false;
  bool emulateMiddle = false;
};
// Retainable UI-to-worker mailbox. All public methods are thread-safe. The host
// wakes the session executor after submission; no protocol or UI callbacks run
// on a submitting thread. Close leaves retained mailboxes inert until reconnect.
class InputQueue {
public:
  ~InputQueue();
  InputQueue(const InputQueue&) = delete;
  InputQueue& operator=(const InputQueue&) = delete;
  // keyId identifies a physical key for matching release/repeat; symbols are RFB
  // keysyms and keyCode is the optional QEMU keycode, already mapped by the host.
  InputResult key(uint64_t generation, uint32_t keyId, uint32_t keySym,
                  uint32_t keyCode, bool down);
  InputResult pointer(uint64_t generation, int32_t x, int32_t y, uint16_t buttons);
  InputResult setFocused(uint64_t generation, bool focused);
  InputResult releaseAll(uint64_t generation);
  // Enabling view-only discards unsent input and requests release of held state.
  void setViewOnly(bool enabled);
  // Atomic policy update. Changing emulation discards unsent input and releases
  // held state; routing revisions invalidate any delayed button press.
  void setPolicy(bool viewOnly, bool emulateMiddle);
  InputStatus status() const;
private:
  friend class ProtocolSession;
  struct Command {
    enum Kind { Key, Pointer, ReleaseAll } kind = ReleaseAll;
    uint32_t keyId = 0, keySym = 0, keyCode = 0;
    int32_t x = 0, y = 0;
    uint16_t buttons = 0;
    bool down = false, transition = false, emulateMiddle = false;
    uint64_t routingRevision = 0;
  };
  explicit InputQueue(size_t capacity);
  void begin(uint64_t generation);
  void connected();
  void end(uint64_t generation);
  bool take(Command& command);
  void overflow();
  struct Impl;
  std::unique_ptr<Impl> impl;
};
}
#endif
