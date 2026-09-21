/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "InputQueue.h"
#include <deque>
#include <mutex>
#include <stdexcept>
#include <limits>

namespace viewer {
struct InputQueue::Impl {
  explicit Impl(size_t capacity_) : capacity(capacity_) {}
  const size_t capacity;
  mutable std::mutex mutex;
  InputStatus status;
  uint16_t buttons = 0;
  std::deque<Command> queue;
  InputResult check(uint64_t generation) const {
    if (generation != status.generation) return InputResult::StaleGeneration;
    if (!status.connected) return InputResult::NotConnected;
    if (status.viewOnly) return InputResult::ViewOnly;
    if (!status.focused) return InputResult::Unfocused;
    return InputResult::Accepted;
  }
  void release() {
    queue.clear(); buttons = 0;
    status.releasePending = status.connected;
  }
  void policy(bool viewOnly, bool emulateMiddle) {
    const bool middleChanged = status.emulateMiddle != emulateMiddle;
    if (status.viewOnly != viewOnly || middleChanged) reroute();
    status.viewOnly = viewOnly; status.emulateMiddle = emulateMiddle;
    if (viewOnly || middleChanged) release();
  }
  void reroute() {
    if (status.routingRevision == std::numeric_limits<uint64_t>::max())
      throw std::overflow_error("Input routing revision exhausted");
    ++status.routingRevision;
  }
  void overflow() {
    reroute(); release(); status.focused = false; ++status.overflows;
  }
  InputResult push(const Command& command) {
    if (queue.size() == capacity) { overflow(); return InputResult::Overflow; }
    try { queue.push_back(command); }
    catch (const std::bad_alloc&) { overflow(); return InputResult::Overflow; }
    return InputResult::Accepted;
  }
};
InputQueue::InputQueue(size_t capacity) : impl(new Impl(capacity)) {
  if (!capacity || capacity > 65536) throw std::invalid_argument("Invalid input queue capacity");
}
InputQueue::~InputQueue() = default;
InputResult InputQueue::key(uint64_t generation, uint32_t id, uint32_t symbol,
                            uint32_t code, bool down) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  auto result = impl->check(generation);
  if (result != InputResult::Accepted) return result;
  if (down && !symbol && !code) return InputResult::Invalid;
  Command command;
  command.kind = Command::Key; command.keyId = id; command.keySym = symbol;
  command.keyCode = code; command.down = down;
  return impl->push(command);
}
InputResult InputQueue::pointer(uint64_t generation, int32_t x, int32_t y, uint16_t buttons) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  auto result = impl->check(generation);
  if (result != InputResult::Accepted) return result;
  if (buttons & ~0x1ff) return InputResult::Invalid;
  Command command;
  command.kind = Command::Pointer; command.x = x; command.y = y; command.buttons = buttons;
  command.transition = buttons != impl->buttons;
  // Do not move a button transition to a later coordinate, or cross a key event.
  if (!command.transition && !impl->queue.empty()) {
    auto& last = impl->queue.back();
    if (last.kind == Command::Pointer && !last.transition) {
      last = command; return InputResult::Coalesced;
    }
  }
  result = impl->push(command);
  if (result == InputResult::Accepted) impl->buttons = buttons;
  return result;
}
InputResult InputQueue::setFocused(uint64_t generation, bool focused) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (generation != impl->status.generation) return InputResult::StaleGeneration;
  if (impl->status.focused != focused) impl->reroute();
  impl->status.focused = focused;
  if (!focused) impl->release();
  return InputResult::Accepted;
}
InputResult InputQueue::releaseAll(uint64_t generation) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (generation != impl->status.generation) return InputResult::StaleGeneration;
  if (!impl->status.connected) return InputResult::NotConnected;
  impl->reroute(); impl->release(); return InputResult::Accepted;
}
void InputQueue::setViewOnly(bool enabled) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->policy(enabled, impl->status.emulateMiddle);
}
void InputQueue::setPolicy(bool viewOnly, bool emulateMiddle) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->policy(viewOnly, emulateMiddle);
}
InputStatus InputQueue::status() const {
  std::lock_guard<std::mutex> lock(impl->mutex);
  auto result = impl->status;
  result.queued = impl->queue.size();
  return result;
}
void InputQueue::begin(uint64_t generation) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->queue.clear(); impl->buttons = 0;
  impl->status.generation = generation;
  impl->status.connected = impl->status.releasePending = false;
  // Keep host focus and view-only policy across attempts.
}
void InputQueue::connected() {
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->status.connected = true;
}
void InputQueue::end(uint64_t generation) { begin(generation); }
bool InputQueue::take(Command& command) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (!impl->status.connected) return false;
  if (impl->status.releasePending) {
    command = Command(); impl->status.releasePending = false;
  } else {
    if (impl->queue.empty()) return false;
    command = impl->queue.front(); impl->queue.pop_front();
  }
  command.routingRevision = impl->status.routingRevision;
  command.emulateMiddle = impl->status.emulateMiddle;
  return true;
}
void InputQueue::overflow() {
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->overflow();
}
}
