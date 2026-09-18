/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/FramePublisher.h>
#include <rfb/PixelBuffer.h>
#include <atomic>
#include <limits>
#include <thread>
#include <vector>

using namespace viewer;
namespace {
PixelView pixels(const std::vector<uint8_t>& data, uint32_t w = 4, uint32_t h = 4)
{
  return {data.data(), data.size(), w, h, size_t(w)*4,
          PixelFormat::BGRA8, AlphaMode::Opaque, PixelOrigin::TopLeft};
}
void expectDamage(const Damage& d, uint32_t x, uint32_t y, uint32_t w, uint32_t h)
{
  EXPECT_EQ(d.x, x); EXPECT_EQ(d.y, y); EXPECT_EQ(d.width, w); EXPECT_EQ(d.height, h);
}
}

TEST(FramePublisher, CopiesPaddedBottomOriginAndRetainsAfterTeardown)
{
  FrameLease retained;
  {
    FramePublisher publisher(1024);
    auto view = publisher.subscribe();
    ViewUpdate update;
    ASSERT_TRUE(view->take(update));
    EXPECT_TRUE(update.frameChanged && update.cursorChanged);
    EXPECT_FALSE(update.frame);
    EXPECT_EQ(update.generation, 1u);
    std::vector<uint8_t> source = {1,2,3,4, 5,6,7,8, 99,99,99,99,
                                  9,10,11,12, 13,14,15,16};
    auto input = pixels(source, 2, 2);
    input.stride = 12;
    input.origin = PixelOrigin::BottomLeft;
    input.format = PixelFormat::RGBA8;
    input.alpha = AlphaMode::Premultiplied;
    ASSERT_EQ(publisher.publishFrame(1, input, {0,0,2,2}), PublishResult::Published);
    std::fill(source.begin(), source.end(), 0);
    ASSERT_TRUE(view->take(update));
    retained = update.frame;
    EXPECT_EQ(retained->pixels.length(), 16u);
    EXPECT_EQ(retained->pixels.stride(), 8u);
    EXPECT_EQ(retained->pixels.origin(), PixelOrigin::TopLeft);
    EXPECT_EQ(retained->pixels.format(), PixelFormat::RGBA8);
    EXPECT_EQ(retained->pixels.alpha(), AlphaMode::Premultiplied);
    EXPECT_EQ(retained->generation, 1u);
    EXPECT_EQ(retained->sizeGeneration, 1u);
    EXPECT_EQ(retained->sequence, 1u);
  }
  EXPECT_EQ((std::vector<uint8_t>(retained->pixels.data(), retained->pixels.data()+16)),
            (std::vector<uint8_t>{9,10,11,12,13,14,15,16,1,2,3,4,5,6,7,8}));
}

TEST(FramePublisher, SlowViewsMergeDamageIndependently)
{
  FramePublisher publisher(1024);
  auto fast = publisher.subscribe(), slow = publisher.subscribe();
  std::vector<uint8_t> source(64, 1);
  ASSERT_EQ(publisher.publishFrame(1, pixels(source), {0,0,4,4}), PublishResult::Published);
  ViewUpdate f, s;
  ASSERT_TRUE(fast->take(f)); ASSERT_TRUE(slow->take(s));
  for (int i = 0; i < 3; ++i) {
    source[i*4] = 2;
    ASSERT_EQ(publisher.publishFrame(1, pixels(source), {uint32_t(i),0,1,1}), PublishResult::Published);
    ASSERT_TRUE(fast->take(f));
    expectDamage(f.damage, i, 0, 1, 1);
  }
  ASSERT_TRUE(slow->take(s));
  expectDamage(s.damage, 0,0,3,1);
  EXPECT_EQ(s.frame, f.frame);
  EXPECT_FALSE(slow->take(s));
  EXPECT_EQ(s.frame->sequence, 4u);
  auto late = publisher.subscribe();
  ASSERT_TRUE(late->take(s));
  expectDamage(s.damage, 0,0,4,4);
}

TEST(FramePublisher, RetainedFramesBoundMemoryAndSkippedDamageIsRecovered)
{
  FramePublisher publisher(192); // Three packed frames, including external leases.
  auto view = publisher.subscribe();
  std::vector<uint8_t> source(64, 1);
  ViewUpdate update;
  ASSERT_EQ(publisher.publishFrame(1, pixels(source), {0,0,4,4}), PublishResult::Published);
  ASSERT_TRUE(view->take(update));
  auto oldest = update.frame;
  ASSERT_EQ(publisher.publishFrame(1, pixels(source), {1,1,1,1}), PublishResult::Published);
  ASSERT_TRUE(view->take(update));
  auto second = update.frame;
  ASSERT_EQ(publisher.publishFrame(1, pixels(source), {2,2,1,1}), PublishResult::Published);
  ASSERT_TRUE(view->take(update));
  EXPECT_EQ(publisher.bytesInUse(), 192u);
  source[0] = 42;
  EXPECT_EQ(publisher.publishFrame(1, pixels(source), {0,0,1,1}), PublishResult::Backpressure);
  EXPECT_FALSE(view->take(update));
  EXPECT_EQ(publisher.bytesInUse(), 192u);
  oldest.reset();
  EXPECT_EQ(publisher.bytesInUse(), 128u);
  ASSERT_EQ(publisher.publishFrame(1, pixels(source), {3,3,1,1}), PublishResult::Published);
  ASSERT_TRUE(view->take(update));
  expectDamage(update.damage, 0,0,4,4);
  EXPECT_EQ(update.frame->pixels.data()[0], 42);
  EXPECT_EQ(update.frame->sequence, 4u); // Failed publication did not advance it.
  EXPECT_EQ(second->pixels.data()[0], 1);
  EXPECT_LE(publisher.bytesInUse(), 192u);
}

TEST(FramePublisher, ResizeAndFormatChangesForceFullDamage)
{
  FramePublisher publisher(1024);
  auto view = publisher.subscribe();
  std::vector<uint8_t> source(64, 1);
  ViewUpdate update;
  ASSERT_EQ(publisher.publishFrame(1, pixels(source), {0,0,4,4}), PublishResult::Published);
  ASSERT_TRUE(view->take(update));
  auto old = update.frame;
  ASSERT_EQ(publisher.publishFrame(1, pixels(source,2,2), {0,0,1,1}), PublishResult::Published);
  ASSERT_EQ(publisher.publishFrame(1, pixels(source,2,2), {1,1,1,1}), PublishResult::Published);
  ASSERT_TRUE(view->take(update));
  EXPECT_EQ(update.frame->sizeGeneration, 2u);
  expectDamage(update.damage, 0,0,2,2);
  auto changed = pixels(source,2,2);
  changed.format = PixelFormat::RGBA8;
  ASSERT_EQ(publisher.publishFrame(1, changed, {0,0,1,1}), PublishResult::Published);
  ASSERT_TRUE(view->take(update));
  EXPECT_EQ(update.frame->sizeGeneration, 3u);
  expectDamage(update.damage, 0,0,2,2);
  EXPECT_EQ(old->pixels.width(), 4u);
}

TEST(FramePublisher, SkippedResizeAndReconnectCannotLoseInvalidation)
{
  FramePublisher publisher(128);
  auto view = publisher.subscribe();
  std::vector<uint8_t> source(64, 1), larger(256, 2);
  ViewUpdate update;
  ASSERT_EQ(publisher.publishFrame(1, pixels(source), {0,0,4,4}), PublishResult::Published);
  ASSERT_TRUE(view->take(update));
  auto retained = update.frame;
  EXPECT_EQ(publisher.publishFrame(1, pixels(larger,8,8), {0,0,1,1}), PublishResult::Backpressure);
  ASSERT_EQ(publisher.publishFrame(1, pixels(source), {1,1,1,1}), PublishResult::Published);
  ASSERT_TRUE(view->take(update));
  expectDamage(update.damage, 0,0,4,4);
  publisher.reset(2);
  ASSERT_TRUE(view->take(update));
  EXPECT_EQ(update.generation, 2u);
  EXPECT_TRUE(update.frameChanged && update.cursorChanged);
  EXPECT_FALSE(update.frame); EXPECT_FALSE(update.cursor);
  EXPECT_EQ(publisher.bytesInUse(), 64u);
  EXPECT_EQ(publisher.publishFrame(1, pixels(source), {}), PublishResult::StaleGeneration);
  ASSERT_EQ(publisher.publishFrame(2, pixels(source), {1,1,1,1}), PublishResult::Published);
  ASSERT_TRUE(view->take(update));
  EXPECT_EQ(update.frame->generation, 2u);
  EXPECT_GT(update.frame->sizeGeneration, retained->sizeGeneration);
  expectDamage(update.damage, 0,0,4,4);
  EXPECT_THROW(publisher.reset(2), std::invalid_argument);
}

TEST(FramePublisher, CursorLeaseSharesBudgetAndPreservesHotspotAndAlpha)
{
  CursorLease retained;
  {
    FramePublisher publisher(80);
    auto view = publisher.subscribe();
    std::vector<uint8_t> source(64, 1), cursor(16, 127);
    ViewUpdate update;
    ASSERT_EQ(publisher.publishFrame(1, pixels(source), {}), PublishResult::Published);
    auto input = pixels(cursor,2,2);
    input.alpha = AlphaMode::Straight;
    ASSERT_EQ(publisher.publishCursor(1, input,1,0), PublishResult::Published);
    ASSERT_TRUE(view->take(update));
    retained = update.cursor;
    EXPECT_TRUE(update.frameChanged && update.cursorChanged);
    EXPECT_EQ(retained->hotspotX, 1u); EXPECT_EQ(retained->hotspotY, 0u);
    EXPECT_EQ(retained->pixels.alpha(), AlphaMode::Straight);
    EXPECT_EQ(publisher.bytesInUse(), 80u);
    EXPECT_EQ(publisher.publishCursor(1, input,0,0), PublishResult::Backpressure);
    EXPECT_EQ(publisher.hideCursor(0), PublishResult::StaleGeneration);
    EXPECT_EQ(publisher.hideCursor(1), PublishResult::Published);
    ASSERT_TRUE(view->take(update));
    EXPECT_TRUE(update.cursorChanged); EXPECT_FALSE(update.frameChanged);
    EXPECT_FALSE(update.cursor);
    EXPECT_EQ(publisher.bytesInUse(), 80u);
  }
  EXPECT_EQ(retained->pixels.data()[0], 127);
}

TEST(FramePublisher, RejectsInvalidLayoutsBeforeReadingAndBoundsSubscriptions)
{
  FramePublisher publisher(1024, 1);
  std::vector<uint8_t> source(64);
  auto input = pixels(source);
  auto view = publisher.subscribe();
  EXPECT_THROW(publisher.subscribe(), std::length_error);
  view.reset();
  EXPECT_NO_THROW(publisher.subscribe());
  input.length = 63;
  EXPECT_THROW(publisher.publishFrame(1, input, {}), std::invalid_argument);
  input = pixels(source); input.stride = std::numeric_limits<size_t>::max();
  EXPECT_THROW(publisher.publishFrame(1, input, {}), std::invalid_argument);
  input = pixels(source); input.stride = 1;
  EXPECT_THROW(publisher.publishFrame(1, input, {}), std::invalid_argument);
  input = pixels(source); input.data = nullptr;
  EXPECT_THROW(publisher.publishFrame(1, input, {}), std::invalid_argument);
  input = pixels(source); input.width = 65536;
  EXPECT_THROW(publisher.publishFrame(1, input, {}), std::invalid_argument);
  input = pixels(source); input.origin = static_cast<PixelOrigin>(99);
  EXPECT_THROW(publisher.publishFrame(1, input, {}), std::invalid_argument);
  EXPECT_THROW(publisher.publishFrame(1, pixels(source), {4,0,1,1}), std::invalid_argument);
  EXPECT_THROW(publisher.publishCursor(1, pixels(source),4,0), std::invalid_argument);
  EXPECT_EQ(publisher.bytesInUse(), 0u);
}

TEST(FramePublisher, RealRfbBufferCanBeReleasedAfterPublication)
{
  FramePublisher publisher(1024);
  auto view = publisher.subscribe();
  {
    rfb::ManagedPixelBuffer buffer(rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0), 2,2);
    const uint8_t colour[] = {11,22,33,0};
    buffer.fillRect(buffer.getRect(), colour);
    int stride;
    const uint8_t* data = buffer.getBuffer(buffer.getRect(), &stride);
    PixelView input{data, size_t(stride)*2*4, 2,2,size_t(stride)*4,
                    PixelFormat::BGRA8, AlphaMode::Opaque, PixelOrigin::TopLeft};
    ASSERT_EQ(publisher.publishFrame(1, input, {0,0,2,2}), PublishResult::Published);
  }
  ViewUpdate update;
  ASSERT_TRUE(view->take(update));
  EXPECT_EQ(update.frame->pixels.data()[0], 11);
  EXPECT_EQ(update.frame->pixels.data()[1], 22);
  EXPECT_EQ(update.frame->pixels.data()[2], 33);
}

TEST(FramePublisher, ConcurrentConsumerRetainsConsistentFramesDuringReset)
{
  FramePublisher publisher(256);
  auto view = publisher.subscribe();
  std::atomic<bool> done{false}, failed{false};
  std::atomic<unsigned> seenFrames{0};
  std::thread consumer([&] {
    uint64_t lastGeneration = 0;
    ViewUpdate update;
    while (!done.load()) {
      if (!view->take(update)) { std::this_thread::yield(); continue; }
      if (update.generation < lastGeneration) failed = true;
      lastGeneration = update.generation;
      if (!update.frame) continue;
      const auto frame = update.frame;
      const uint8_t value = frame->pixels.data()[0];
      std::this_thread::yield();
      for (size_t i = 0; i < frame->pixels.length(); ++i)
        if (frame->pixels.data()[i] != value) failed = true;
      if (frame->generation != update.generation) failed = true;
      ++seenFrames;
    }
  });
  for (int i = 0; i < 2000; ++i) {
    if (i == 1000) publisher.reset(2);
    std::vector<uint8_t> source(64, uint8_t(i));
    publisher.publishFrame(publisher.generation(), pixels(source), {0,0,4,4});
    if (i == 0)
      while (seenFrames.load() == 0) std::this_thread::yield();
    if (publisher.bytesInUse() > 256) failed = true;
  }
  done = true;
  consumer.join();
  EXPECT_FALSE(failed);
  EXPECT_GT(seenFrames.load(), 0u);
}
