/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_FRAME_PUBLISHER_H
#define TIDYVNC_FRAME_PUBLISHER_H

#include <cstddef>
#include <cstdint>
#include <memory>
#include <viewer/platform/MailboxWakeup.h>

namespace viewer {

enum class PixelFormat { BGRA8, RGBA8 };
enum class AlphaMode { Opaque, Straight, Premultiplied };
enum class PixelOrigin { TopLeft, BottomLeft };

// All lengths/strides are bytes, dimensions and damage are remote pixels.
// Damage and hotspots always use top-left coordinates, even for bottom-up input.
// Input storage is borrowed only for publish(); decoder writes must have been
// joined by the caller. Output is packed, top-left, with the same format/alpha.
struct PixelView {
  const uint8_t* data;
  size_t length;
  uint32_t width, height;
  size_t stride;
  PixelFormat format;
  AlphaMode alpha;
  PixelOrigin origin;
};
struct Damage {
  uint32_t x = 0, y = 0, width = 0, height = 0;
  Damage() = default;
  Damage(uint32_t x_, uint32_t y_, uint32_t w, uint32_t h)
    : x(x_), y(y_), width(w), height(h) {}
  bool empty() const { return width == 0 || height == 0; }
};

struct PixelStorage;
class FramePublisher;

// Immutable shared payload, valid even after resize, reconnect or publisher
// destruction. UI consumers may retain/release leases on any thread.
class PixelLease {
public:
  const uint8_t* data() const;
  size_t length() const;
  size_t stride() const;
  uint32_t width() const;
  uint32_t height() const;
  PixelFormat format() const;
  AlphaMode alpha() const;
  PixelOrigin origin() const { return PixelOrigin::TopLeft; }
private:
  explicit PixelLease(std::shared_ptr<const PixelStorage> storage_);
  std::shared_ptr<const PixelStorage> storage;
  friend class FramePublisher;
};
struct Frame {
  PixelLease pixels;
  uint64_t generation, sizeGeneration, sequence;
};
struct Cursor {
  PixelLease pixels;
  uint32_t hotspotX, hotspotY;
  uint64_t generation, sequence;
};
using FrameLease = std::shared_ptr<const Frame>;
using CursorLease = std::shared_ptr<const Cursor>;

// Changed flags distinguish "no new update" from "clear the image/cursor".
// Damage is relative to this subscriber's last take, in top-left remote pixels.
struct ViewUpdate {
  uint64_t generation = 0;
  bool frameChanged = false, cursorChanged = false;
  FrameLease frame;
  CursorLease cursor;
  Damage damage;
};
struct ViewMailbox;
class FrameSubscription {
public:
  // Thread-safe bounded mailbox: replaces pending frames and unions damage.
  // False leaves output unchanged. A new subscription starts with a snapshot.
  bool take(ViewUpdate& output);
  // Thread-safe weak readiness target; signals an initial mailbox check.
  void setWakeup(std::weak_ptr<MailboxWakeup> wakeup);
private:
  explicit FrameSubscription(std::shared_ptr<ViewMailbox> mailbox_);
  std::shared_ptr<ViewMailbox> mailbox;
  friend class FramePublisher;
};

enum class PublishResult { Published, Backpressure, StaleGeneration };

class FramePublisher {
public:
  // Budget counts packed pixel bytes in all retained frames/cursors, including
  // mailbox and external leases, even from older generations. Metadata and
  // allocator overhead are additional; subscriber count is separately bounded.
  explicit FramePublisher(size_t byteBudget, size_t maxSubscribers = 16);
  ~FramePublisher();
  FramePublisher(const FramePublisher&) = delete;
  FramePublisher& operator=(const FramePublisher&) = delete;

  // All publisher operations except bytesInUse() run on one session executor.
  // Generation starts at 1. Reset must advance it; queued old data is discarded
  // and subscribers receive an explicit clear. Held old leases remain valid.
  uint64_t generation() const;
  void reset(uint64_t nextGeneration);
  std::shared_ptr<FrameSubscription> subscribe();
  PublishResult publishFrame(uint64_t generation, const PixelView& pixels,
                              Damage damage);
  // On backpressure the caller retries with the latest full image. Frame
  // damage is accumulated until success; cursor pixels must be supplied again.
  PublishResult publishCursor(uint64_t generation, const PixelView& pixels,
                               uint32_t hotspotX, uint32_t hotspotY);
  PublishResult hideCursor(uint64_t generation);
  size_t bytesInUse() const;

private:
  struct Impl;
  std::unique_ptr<Impl> impl;
  std::shared_ptr<const PixelStorage> copyPixels(const PixelView& pixels);
};

}
#endif
