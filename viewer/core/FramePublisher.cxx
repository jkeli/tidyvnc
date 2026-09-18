/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "FramePublisher.h"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <utility>
#include <vector>

namespace viewer {
namespace {
struct Budget {
  explicit Budget(size_t maximum_) : maximum(maximum_), used(0) {}
  const size_t maximum;
  std::atomic<size_t> used;
};
size_t pixelBytes(const PixelView& p)
{
  if (!p.data || !p.width || !p.height || p.width > 65535 || p.height > 65535)
    throw std::invalid_argument("Invalid pixel dimensions or storage");
  if ((p.format != PixelFormat::BGRA8 && p.format != PixelFormat::RGBA8) ||
      (p.alpha != AlphaMode::Opaque && p.alpha != AlphaMode::Straight &&
       p.alpha != AlphaMode::Premultiplied) ||
      (p.origin != PixelOrigin::TopLeft && p.origin != PixelOrigin::BottomLeft))
    throw std::invalid_argument("Invalid pixel layout");
  const size_t row = size_t(p.width) * 4;
  const size_t maximum = std::numeric_limits<size_t>::max();
  if (p.stride < row || row > maximum / p.height ||
      (p.height > 1 && p.stride > (maximum - row) / (p.height - 1)))
    throw std::invalid_argument("Invalid pixel stride");
  if (p.length < (p.height - 1) * p.stride + row)
    throw std::invalid_argument("Pixel storage is truncated");
  return row * p.height;
}
Damage full(uint32_t w, uint32_t h) { return {0, 0, w, h}; }
Damage unite(Damage a, Damage b)
{
  if (a.empty()) return b;
  if (b.empty()) return a;
  const uint32_t x = std::min(a.x, b.x), y = std::min(a.y, b.y);
  return {x, y, std::max(a.x + a.width, b.x + b.width) - x,
                std::max(a.y + a.height, b.y + b.height) - y};
}
uint64_t increment(uint64_t value)
{
  if (value == std::numeric_limits<uint64_t>::max())
    throw std::overflow_error("Publication generation exhausted");
  return value + 1;
}
}

struct PixelStorage {
  PixelStorage(std::shared_ptr<Budget> budget_, size_t bytes_)
    : budget(budget_), bytes(bytes_) {}
  ~PixelStorage() {
    std::vector<uint8_t>().swap(data);
    budget->used.fetch_sub(bytes);
  }
  std::shared_ptr<Budget> budget;
  const size_t bytes;
  uint32_t width, height;
  PixelFormat format;
  AlphaMode alpha;
  std::vector<uint8_t> data;
};
PixelLease::PixelLease(std::shared_ptr<const PixelStorage> storage_) : storage(storage_) {}
const uint8_t* PixelLease::data() const { return storage->data.data(); }
size_t PixelLease::length() const { return storage->bytes; }
size_t PixelLease::stride() const { return size_t(storage->width) * 4; }
uint32_t PixelLease::width() const { return storage->width; }
uint32_t PixelLease::height() const { return storage->height; }
PixelFormat PixelLease::format() const { return storage->format; }
AlphaMode PixelLease::alpha() const { return storage->alpha; }

struct ViewMailbox {
  std::mutex mutex;
  ViewUpdate update;
};
FrameSubscription::FrameSubscription(std::shared_ptr<ViewMailbox> mailbox_) : mailbox(mailbox_) {}
bool FrameSubscription::take(ViewUpdate& output)
{
  std::lock_guard<std::mutex> lock(mailbox->mutex);
  if (!mailbox->update.frameChanged && !mailbox->update.cursorChanged)
    return false;
  output = std::move(mailbox->update);
  mailbox->update = ViewUpdate();
  return true;
}

struct FramePublisher::Impl {
  Impl(size_t budget_, size_t max_) : budget(new Budget(budget_)), maximumSubscribers(max_) {}
  std::shared_ptr<Budget> budget;
  size_t maximumSubscribers;
  uint64_t generation = 1, sizeGeneration = 0, sequence = 0;
  FrameLease latest;
  CursorLease cursor;
  Damage skipped;
  bool skippedResize = false;
  std::vector<std::weak_ptr<ViewMailbox>> subscribers;

  void prune() {
    subscribers.erase(std::remove_if(subscribers.begin(), subscribers.end(),
      [](const std::weak_ptr<ViewMailbox>& entry) { return entry.expired(); }), subscribers.end());
  }
  void frameUpdate(Damage damage) {
    for (auto& entry : subscribers) {
      auto mailbox = entry.lock();
      if (!mailbox) continue;
      std::lock_guard<std::mutex> lock(mailbox->mutex);
      auto& update = mailbox->update;
      if (update.frameChanged && update.frame) {
        if (update.frame->sizeGeneration == latest->sizeGeneration)
          update.damage = unite(update.damage, damage);
        else
          update.damage = full(latest->pixels.width(), latest->pixels.height());
      } else {
        update.damage = damage;
      }
      update.generation = generation;
      update.frameChanged = true;
      update.frame = latest;
    }
  }
  void cursorUpdate() {
    for (auto& entry : subscribers) {
      auto mailbox = entry.lock();
      if (!mailbox) continue;
      std::lock_guard<std::mutex> lock(mailbox->mutex);
      mailbox->update.generation = generation;
      mailbox->update.cursorChanged = true;
      mailbox->update.cursor = cursor;
    }
  }
};

FramePublisher::FramePublisher(size_t byteBudget, size_t maxSubscribers)
  : impl(new Impl(byteBudget, maxSubscribers))
{
  if (!byteBudget || !maxSubscribers)
    throw std::invalid_argument("Publication budgets must be positive");
}
FramePublisher::~FramePublisher() = default;
uint64_t FramePublisher::generation() const { return impl->generation; }
size_t FramePublisher::bytesInUse() const { return impl->budget->used.load(); }
void FramePublisher::reset(uint64_t nextGeneration)
{
  if (nextGeneration <= impl->generation)
    throw std::invalid_argument("Session generation must advance");
  impl->generation = nextGeneration;
  impl->latest.reset();
  impl->cursor.reset();
  impl->skipped = Damage();
  impl->skippedResize = false;
  impl->prune();
  for (auto& entry : impl->subscribers) {
    auto mailbox = entry.lock();
    if (!mailbox) continue;
    std::lock_guard<std::mutex> lock(mailbox->mutex);
    mailbox->update = ViewUpdate();
    mailbox->update.generation = nextGeneration;
    mailbox->update.frameChanged = mailbox->update.cursorChanged = true;
  }
}
std::shared_ptr<FrameSubscription> FramePublisher::subscribe()
{
  impl->prune();
  if (impl->subscribers.size() >= impl->maximumSubscribers)
    throw std::length_error("Too many frame subscribers");
  auto mailbox = std::make_shared<ViewMailbox>();
  mailbox->update.generation = impl->generation;
  mailbox->update.frameChanged = mailbox->update.cursorChanged = true;
  mailbox->update.frame = impl->latest;
  mailbox->update.cursor = impl->cursor;
  if (impl->latest)
    mailbox->update.damage = full(impl->latest->pixels.width(), impl->latest->pixels.height());
  std::shared_ptr<FrameSubscription> subscription(new FrameSubscription(mailbox));
  impl->subscribers.push_back(mailbox);
  return subscription;
}
std::shared_ptr<const PixelStorage> FramePublisher::copyPixels(const PixelView& p)
{
  const size_t bytes = pixelBytes(p);
  auto budget = impl->budget;
  size_t used = budget->used.load();
  do {
    if (bytes > budget->maximum - used)
      return nullptr;
  } while (!budget->used.compare_exchange_weak(used, used + bytes));
  std::shared_ptr<PixelStorage> storage;
  try { storage = std::make_shared<PixelStorage>(budget, bytes); }
  catch (...) { budget->used.fetch_sub(bytes); throw; }
  storage->width = p.width;
  storage->height = p.height;
  storage->format = p.format;
  storage->alpha = p.alpha;
  storage->data.resize(bytes);
  const size_t row = size_t(p.width) * 4;
  for (uint32_t y = 0; y < p.height; ++y) {
    const uint32_t sourceY = p.origin == PixelOrigin::TopLeft ? y : p.height - 1 - y;
    std::memcpy(storage->data.data() + y * row, p.data + sourceY * p.stride, row);
  }
  return storage;
}
PublishResult FramePublisher::publishFrame(uint64_t generation_, const PixelView& p, Damage damage)
{
  if (generation_ != impl->generation) return PublishResult::StaleGeneration;
  pixelBytes(p);
  if (damage.x > p.width || damage.y > p.height ||
      damage.width > p.width - damage.x || damage.height > p.height - damage.y)
    throw std::invalid_argument("Damage outside framebuffer");
  const auto& old = impl->latest;
  const bool resized = !old || old->pixels.width() != p.width || old->pixels.height() != p.height ||
    old->pixels.format() != p.format || old->pixels.alpha() != p.alpha;
  const uint64_t nextSize = resized ? increment(impl->sizeGeneration) : impl->sizeGeneration;
  const uint64_t nextSequence = increment(impl->sequence);
  // Remember all unpublished damage, including allocation failures. A skipped
  // resize forces full damage even if the source later returns to the old size.
  if (resized) impl->skippedResize = true;
  if (!impl->skippedResize) impl->skipped = unite(impl->skipped, damage);
  auto storage = copyPixels(p);
  if (!storage) return PublishResult::Backpressure;
  FrameLease frame(new Frame{PixelLease(storage), generation_, nextSize, nextSequence});
  damage = impl->skippedResize ? full(p.width, p.height) : impl->skipped;
  impl->latest = frame;
  impl->sizeGeneration = nextSize;
  impl->sequence = nextSequence;
  impl->frameUpdate(damage);
  impl->skipped = Damage();
  impl->skippedResize = false;
  return PublishResult::Published;
}
PublishResult FramePublisher::publishCursor(uint64_t generation_, const PixelView& p,
                                            uint32_t hotspotX, uint32_t hotspotY)
{
  if (generation_ != impl->generation) return PublishResult::StaleGeneration;
  pixelBytes(p);
  if (hotspotX >= p.width || hotspotY >= p.height)
    throw std::invalid_argument("Cursor hotspot outside image");
  const uint64_t sequence = increment(impl->sequence);
  auto storage = copyPixels(p);
  if (!storage) return PublishResult::Backpressure;
  CursorLease cursor(new Cursor{PixelLease(storage), hotspotX, hotspotY, generation_, sequence});
  impl->cursor = cursor;
  impl->sequence = sequence;
  impl->cursorUpdate();
  return PublishResult::Published;
}
PublishResult FramePublisher::hideCursor(uint64_t generation_)
{
  if (generation_ != impl->generation) return PublishResult::StaleGeneration;
  impl->cursor.reset();
  impl->cursorUpdate();
  return PublishResult::Published;
}
}
