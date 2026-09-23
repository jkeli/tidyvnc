/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/FrameTileRenderer.h>
#include <algorithm>
#include <array>
#include <cstring>
using namespace viewer;
namespace {
struct Source {
  FramePublisher publisher{16*1024*1024};
  std::shared_ptr<FrameSubscription> subscription = publisher.subscribe();
  std::vector<uint8_t> pixels;
  Source() : pixels(512*4*4,0) {}
  FrameLease publish(Damage damage = {0,0,512,4}, int width = 512, int height = 4) {
    PixelView view{pixels.data(),pixels.size(),uint32_t(width),uint32_t(height),size_t(width)*4,
      PixelFormat::BGRA8,AlphaMode::Opaque,PixelOrigin::TopLeft};
    if (publisher.publishFrame(publisher.generation(),view,damage) != PublishResult::Published) throw std::runtime_error("Fixture publication failed");
    ViewUpdate update; subscription->take(update); return update.frame;
  }
};
}
TEST(FrameTileRenderer, SharedFiltersAndIdentityProduceExactPixels) {
  Source source;
  for (size_t i=0;i<source.pixels.size();i+=4) {
    source.pixels[i]=uint8_t(i/4%251); source.pixels[i+1]=uint8_t(i/16%239); source.pixels[i+2]=uint8_t(i/64%127);
  }
  auto frame=source.publish(); FrameTileRenderer renderer(256*256*4);
  for (auto q : {ScalingSettings::Nearest,ScalingSettings::Bilinear,ScalingSettings::Area}) {
    for (auto dimensions : {std::pair<int,int>{512,4},{700,9},{7,2},{100,8}}) {
      const core::Rect tile(0,0,std::min(256,dimensions.first),dimensions.second);
      std::vector<uint8_t> actual(tile.area()*4), expected(actual.size());
      EXPECT_FALSE(renderer.render(1,frame,0,{0,0,512,4},dimensions.first,dimensions.second,q,tile,actual.data(),actual.size()));
      resampleDesktop(frame->pixels.data(),512,4,512*4,expected.data(),tile.width()*4,
        dimensions.first,dimensions.second,tile,q);
      EXPECT_EQ(actual,expected);
      EXPECT_TRUE(renderer.render(1,frame,0,{0,0,512,4},dimensions.first,dimensions.second,q,tile,actual.data(),actual.size()));
    }
  }
}
TEST(FrameTileRenderer, PartialDamagePreservesOtherTilesAndGapsInvalidate) {
  Source source; auto first=source.publish(); FrameTileRenderer renderer(8192);
  std::array<uint8_t,4096> output{}; const core::Rect left(0,0,256,4),right(256,0,512,4);
  auto render=[&](const FrameLease& frame,uint64_t previous,Damage damage,const core::Rect& tile) {
    return renderer.render(1,frame,previous,damage,512,4,ScalingSettings::Nearest,tile,output.data(),output.size());
  };
  EXPECT_FALSE(render(first,0,{0,0,512,4},left)); EXPECT_FALSE(render(first,0,{0,0,512,4},right));
  source.pixels[0]=90; auto second=source.publish({0,0,1,1});
  EXPECT_TRUE(render(second,first->sequence,{0,0,1,1},right));
  EXPECT_FALSE(render(second,first->sequence,{0,0,1,1},left)); EXPECT_EQ(output[0],90);
  source.pixels[256*4]=99; auto skipped=source.publish({256,0,1,1});
  source.pixels[0]=60; auto latest=source.publish({0,0,1,1});
  EXPECT_FALSE(render(latest,skipped->sequence,{0,0,1,1},right)); EXPECT_EQ(output[0],99);
  EXPECT_TRUE(render(latest,skipped->sequence,{0,0,1,1},right));
  renderer.clear(); EXPECT_EQ(renderer.bytes(),0U);
  EXPECT_FALSE(render(latest,skipped->sequence,{0,0,1,1},right));
}
TEST(FrameTileRenderer, SourceGenerationResizeFilterAndBudgetAreIsolated) {
  Source first,second; auto a=first.publish(),b=second.publish();
  FrameTileRenderer renderer(4096); std::array<uint8_t,4096> output{};
  auto render=[&](uint64_t id,const FrameLease& frame,ScalingSettings::Quality quality = ScalingSettings::Nearest,int width=512) {
    return renderer.render(id,frame,frame->sequence,{},width,4,quality,{0,0,256,4},output.data(),output.size());
  };
  EXPECT_FALSE(render(1,a)); EXPECT_TRUE(render(1,a));
  EXPECT_FALSE(render(2,b)); EXPECT_FALSE(render(1,a)); // Same sequence/generation in different sessions.
  EXPECT_FALSE(render(1,a,ScalingSettings::Bilinear)); EXPECT_TRUE(render(1,a,ScalingSettings::Bilinear));
  EXPECT_FALSE(render(1,a,ScalingSettings::Bilinear,513));
  first.publisher.reset(2); auto c=first.publish(); EXPECT_FALSE(render(1,c));
  auto resized=first.publish({0,0,256,4},256,4); EXPECT_FALSE(render(1,resized));
  EXPECT_LE(renderer.bytes(),4096U);
  FrameTileRenderer disabled(0);
  EXPECT_FALSE(disabled.render(1,a,0,{},512,4,ScalingSettings::Nearest,{0,0,256,4},output.data(),output.size()));
  EXPECT_EQ(disabled.bytes(),0U);
  // The renderer owns no frame lease; cached pixels do not pin publication budgets.
  std::weak_ptr<const Frame> weak = a; a.reset(); EXPECT_TRUE(weak.expired());
}
TEST(FrameTileRenderer, InvalidArgumentsPreserveOutputAndCache) {
  Source source; auto frame=source.publish(); FrameTileRenderer renderer(4096);
  std::array<uint8_t,4096> output{};
  EXPECT_FALSE(renderer.render(1,frame,0,{},512,4,ScalingSettings::Nearest,{0,0,256,4},output.data(),output.size()));
  output.fill(77); const auto before=output;
  EXPECT_THROW(renderer.render(1,frame,0,{512,0,1,1},512,4,ScalingSettings::Nearest,{0,0,256,4},output.data(),output.size()),std::invalid_argument);
  EXPECT_THROW(renderer.render(1,frame,0,{},65536,4,ScalingSettings::Nearest,{0,0,256,4},output.data(),output.size()),std::invalid_argument);
  EXPECT_THROW(renderer.render(1,frame,0,{},512,4,ScalingSettings::Nearest,{0,0,257,4},output.data(),output.size()),std::invalid_argument);
  EXPECT_THROW(renderer.render(1,frame,0,{},512,4,ScalingSettings::Nearest,{0,0,256,4},output.data(),4095),std::invalid_argument);
  EXPECT_EQ(output,before); EXPECT_EQ(renderer.bytes(),4096U);
  EXPECT_TRUE(renderer.render(1,frame,0,{},512,4,ScalingSettings::Nearest,{0,0,256,4},output.data(),output.size()));
  EXPECT_THROW(FrameTileRenderer(32*1024*1024+1),std::invalid_argument);
}

extern "C" void abi_test_fail_after(unsigned);
TEST(FrameTileRenderer, CacheAllocationFailureReturnsPixelsAndDropsCache) {
#if defined(_MSC_VER) && defined(_ITERATOR_DEBUG_LEVEL) && _ITERATOR_DEBUG_LEVEL > 0
  GTEST_SKIP() << "Allocation injection needs _ITERATOR_DEBUG_LEVEL=0 (MSVC Release)";
#endif
  Source source; auto frame=source.publish(); FrameTileRenderer renderer(4096);
  std::array<uint8_t,4096> output{};
  for (unsigned allocation=1;allocation<=2;++allocation) {
    renderer.clear(); output.fill(99);
    abi_test_fail_after(allocation);
    const bool hit=renderer.render(1,frame,0,{},512,4,ScalingSettings::Nearest,{0,0,256,4},output.data(),output.size());
    abi_test_fail_after(0);
    EXPECT_FALSE(hit); EXPECT_EQ(renderer.bytes(),0U);
    for (size_t i=0;i<output.size();i+=4) {
      EXPECT_EQ(output[i],0); EXPECT_EQ(output[i+1],0); EXPECT_EQ(output[i+2],0); EXPECT_EQ(output[i+3],255);
    }
  }
  EXPECT_FALSE(renderer.render(1,frame,0,{},512,4,ScalingSettings::Nearest,{0,0,256,4},output.data(),output.size()));
  EXPECT_EQ(renderer.bytes(),4096U);
}
