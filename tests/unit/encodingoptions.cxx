/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/core/EncodingOptions.h>
#include <rfb/Decoder.h>
#include <rfb/encodings.h>
#include <rfb/CConnection.h>
#include <gtest/gtest.h>
#include <future>
#include <limits>

using namespace viewer;

TEST(EncodingOptions, SchemaDefaultsAndCanonicalRoundTrip)
{
  EncodingOptions defaults;
  EXPECT_EQ(encodingSchema().size(), size_t(EncodingOption::Count));
  OptionPatch serialized;
  for (const auto& entry : encodingSchema()) {
    EXPECT_EQ(defaults.value(entry.id), entry.defaultValue);
    EXPECT_EQ(defaults.source(entry.id), OptionSource::Compiled);
    EXPECT_TRUE(entry.live); EXPECT_TRUE(entry.persistent);
    serialized.push_back({entry.name, defaults.value(entry.id)});
  }
  const auto restored = defaults.withPatch(serialized, OptionSource::Profile);
  for (const auto& entry : encodingSchema()) {
    EXPECT_EQ(restored.value(entry.id), defaults.value(entry.id));
    EXPECT_EQ(restored.source(entry.id), OptionSource::Profile);
  }
  EXPECT_TRUE(defaults.autoSelect()); EXPECT_TRUE(defaults.fullColor());
  EXPECT_EQ(defaults.lowColorLevel(), 2);
  EXPECT_EQ(defaults.preferredEncoding(), rfb::encodingTight);
  EXPECT_FALSE(defaults.customCompressLevel());
  EXPECT_EQ(defaults.compressLevel(), 2); EXPECT_EQ(defaults.qualityLevel(), 8);
  EXPECT_TRUE(defaults.jpegAllowed()); EXPECT_EQ(defaults.selectedCompression(), -1);
}

TEST(EncodingOptions, LayerPrecedenceAndAliasProvenance)
{
  const auto options = EncodingOptions::resolve(
    {{"QualityLevel", "1"}, {"FullColour", "off"}},
    {{"QualityLevel", "2"}, {"LowColourLevel", "1"}},
    {{"QualityLevel", "3"}, {"PreferredEncoding", "Raw"}},
    {{"qualityLEVEL", "4"}});
  EXPECT_EQ(options.qualityLevel(), 4);
  EXPECT_EQ(options.source(EncodingOption::QualityLevel), OptionSource::CommandLine);
  EXPECT_FALSE(options.fullColor());
  EXPECT_EQ(options.source(EncodingOption::FullColor), OptionSource::AppDefaults);
  EXPECT_EQ(options.lowColorLevel(), 1);
  EXPECT_EQ(options.source(EncodingOption::LowColorLevel), OptionSource::Profile);
  EXPECT_EQ(options.preferredEncoding(), rfb::encodingRaw);
  EXPECT_EQ(options.source(EncodingOption::PreferredEncoding), OptionSource::Session);
  EXPECT_EQ(options.source(EncodingOption::AutoSelect), OptionSource::Compiled);
  const auto aliased = options.withPatch({{"FullColour", "on"}, {"FULLCOLOR", "off"}}, OptionSource::Session);
  EXPECT_FALSE(aliased.fullColor());
}

TEST(EncodingOptions, InvalidPatchIsAtomicAndDoesNotHideBadLowerLayer)
{
  const EncodingOptions original;
  EXPECT_THROW(original.withPatch({{"QualityLevel", "3"}, {"FullColour", "bad"}},
                                  OptionSource::Session), OptionError);
  EXPECT_EQ(original.qualityLevel(), 8);
  EXPECT_EQ(original.source(EncodingOption::QualityLevel), OptionSource::Compiled);
  EXPECT_THROW(EncodingOptions::resolve({{"QualityLevel", "99"}}, {}, {},
                                       {{"QualityLevel", "8"}}), OptionError);
}

TEST(EncodingOptions, BooleanSpellingsMatchLegacy)
{
  for (const auto* text : {"", "1", "true", "TRUE", "Yes", "ON"})
    EXPECT_TRUE(EncodingOptions().withPatch({{"AutoSelect", text}}, OptionSource::Session).autoSelect());
  for (const auto* text : {"0", "false", "FALSE", "No", "OFF"})
    EXPECT_FALSE(EncodingOptions().withPatch({{"AutoSelect", text}}, OptionSource::Session).autoSelect());
  for (const auto* text : {"2", "true ", " on", "-1"})
    EXPECT_THROW(EncodingOptions().withPatch({{"AutoSelect", text}}, OptionSource::Session), OptionError);
}

TEST(EncodingOptions, IntegerBasesRangesAndMalformedValues)
{
  for (const auto* text : {"8", "0x8", "010", " +8"})
    EXPECT_EQ(EncodingOptions().withPatch({{"QualityLevel", text}}, OptionSource::Session).qualityLevel(), 8);
  EXPECT_EQ(EncodingOptions().withPatch({{"QualityLevel", "-0"}}, OptionSource::Session).qualityLevel(), 0);
  for (const auto* text : {"", " ", "0x", "08", "8 ", "+", "-1", "10", "0xA", "9999999999999999999999"})
    EXPECT_THROW(EncodingOptions().withPatch({{"QualityLevel", text}}, OptionSource::Session), OptionError);
  EXPECT_THROW(EncodingOptions().withPatch({{"LowColorLevel", "3"}}, OptionSource::Session), OptionError);
  EXPECT_EQ(EncodingOptions().withPatch({{"CompressLevel", "9"}}, OptionSource::Session).compressLevel(), 9);
}

TEST(EncodingOptions, CompiledChoicesAndTypedErrors)
{
  for (const auto& choice : encodingChoices()) {
    EXPECT_EQ(choice.available, rfb::Decoder::supported(choice.wireEncoding));
    try {
      const auto options = EncodingOptions().withPatch({{"PreferredEncoding", choice.name}}, OptionSource::Profile);
      EXPECT_TRUE(choice.available);
      EXPECT_EQ(options.preferredEncoding(), choice.wireEncoding);
    } catch (const OptionError& error) {
      EXPECT_FALSE(choice.available);
      EXPECT_EQ(error.id, EncodingOption::PreferredEncoding);
      EXPECT_EQ(error.code, OptionErrorCode::Unsupported);
    }
  }
  EXPECT_EQ(EncodingOptions().withPatch({{"preferredencoding", "jPeG"}}, OptionSource::Session).preferredEncoding(),
            rfb::encodingJPEG);
  try {
    EncodingOptions().withPatch({{"password-pasted-here", "secret"}}, OptionSource::Session);
    FAIL();
  } catch (const OptionError& error) {
    EXPECT_EQ(error.id, EncodingOption::Count);
    EXPECT_EQ(error.code, OptionErrorCode::UnknownOption);
    EXPECT_STREQ(error.what(), "Invalid encoding option");
  }
  EXPECT_THROW(EncodingOptions().value(EncodingOption::Count), OptionError);
  EXPECT_THROW(EncodingOptions().source(static_cast<EncodingOption>(-1)), OptionError);
}

TEST(EncodingOptions, BoundedInputAndNoNulTruncation)
{
  EXPECT_THROW(EncodingOptions().withPatch(OptionPatch(257, {"NoJPEG", "on"}), OptionSource::Session), OptionError);
  EXPECT_THROW(EncodingOptions().withPatch({{std::string(129, 'x'), "on"}}, OptionSource::Session), OptionError);
  EXPECT_THROW(EncodingOptions().withPatch({{"NoJPEG", std::string(129, 'x')}}, OptionSource::Session), OptionError);
  EXPECT_THROW(EncodingOptions().withPatch({{"QualityLevel", std::string("1\0x", 3)}}, OptionSource::Session), OptionError);
  EXPECT_THROW(EncodingOptions().withPatch({{std::string("NoJPEG\0x", 8), "on"}}, OptionSource::Session), OptionError);
}

TEST(EncodingOptions, AutomaticThresholdsAndManualColorFormats)
{
  const rfb::PixelFormat full(32, 24, false, true, 255, 255, 255, 16, 8, 0);
  EncodingOptions automatic;
  EXPECT_EQ(automatic.selectedQuality(16000000), 6);
  EXPECT_EQ(automatic.selectedQuality(16000001), 8);
  EXPECT_EQ(automatic.selectedFormat(256001, full), full);
  EXPECT_EQ(automatic.selectedFormat(256000, full).depth, 8);
  for (int level = 0; level <= 2; ++level) {
    const auto manual = automatic.withPatch({{"AutoSelect", "off"}, {"FullColour", "off"},
      {"LowColourLevel", std::to_string(level)}, {"QualityLevel", "3"},
      {"PreferredEncoding", "Raw"}, {"CustomCompressLevel", "on"}, {"CompressLevel", "9"}}, OptionSource::Session);
    EXPECT_EQ(manual.selectedEncoding(), rfb::encodingRaw);
    EXPECT_EQ(manual.selectedCompression(), 9);
    EXPECT_EQ(manual.selectedQuality(0), 3);
    EXPECT_EQ(manual.selectedQuality(100000000), 3);
    const auto format = manual.selectedFormat(100000000, full);
    EXPECT_EQ(format.bpp, 8);
    EXPECT_EQ(format.depth, level == 0 ? 3 : level == 1 ? 6 : 8);
    EXPECT_EQ(format.pixelFromRGB(uint8_t(255), uint8_t(0), uint8_t(0)),
              level == 0 ? 4u : level == 1 ? 48u : 224u);
  }
}

TEST(EncodingOptions, NativePolicyNeverReadsLegacyJpegParameter)
{
  const bool saved = rfb::CConnection::noJpeg;
  rfb::CConnection::noJpeg.setParam(true);
  EXPECT_TRUE(EncodingOptions().jpegAllowed());
  rfb::CConnection::noJpeg.setParam(saved);
}

TEST(EncodingOptions, ConcurrentSnapshotsRemainIndependent)
{
  const EncodingOptions base;
  auto worker = [&base](int quality) {
    for (int i = 0; i < 100; ++i) {
      const auto next = base.withPatch({{"QualityLevel", std::to_string(quality)}}, OptionSource::Session);
      EXPECT_EQ(next.qualityLevel(), quality);
      EXPECT_EQ(base.qualityLevel(), 8);
    }
  };
  auto one = std::async(std::launch::async, worker, 1);
  auto two = std::async(std::launch::async, worker, 9);
  one.get(); two.get();
}

TEST(EncodingOptions, MonotonicBandwidthWeightAndArithmeticBounds)
{
  BandwidthEstimate estimate;
  EXPECT_EQ(estimate.bitsPerSecond(), 20000000u);
  estimate.observe(0, 1000000); // Long samples contribute at most 20%.
  EXPECT_EQ(estimate.bitsPerSecond(), 16000000u);
  estimate.observe(200000, 100000); // 16 Mbps, unchanged.
  EXPECT_EQ(estimate.bitsPerSecond(), 16000000u);
  estimate.observe(std::numeric_limits<uint64_t>::max(), 0);
  EXPECT_LE(estimate.bitsPerSecond(), 1000000000000ULL);
  for (int i = 0; i < 100; ++i) estimate.observe(std::numeric_limits<uint64_t>::max(), 1);
  EXPECT_LE(estimate.bitsPerSecond(), 1000000000000ULL);
  estimate.observe(0, std::numeric_limits<uint64_t>::max());
  EXPECT_LE(estimate.bitsPerSecond(), 1000000000000ULL);
}
