/* Copyright (C) 2002-2005 RealVNC Ltd.  All Rights Reserved.
 * Copyright (C) 2011 D. R. Commander.  All Rights Reserved.
 * Copyright 2009-2014 Pierre Ossman for Cendio AB
 *
 * This is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this software; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307,
 * USA.
 */

/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/core/EncodingOptions.h>
#include <core/ParameterValue.h>
#include <rfb/Decoder.h>
#include <rfb/encodings.h>
#include <algorithm>

namespace viewer {
namespace {
bool equal(const std::string& value, const char* expected)
{
  if (!expected || value.size() != std::char_traits<char>::length(expected)) return false;
  for (size_t i = 0; i < value.size(); ++i) {
    char a = value[i], b = expected[i];
    if (a >= 'A' && a <= 'Z') a += 'a' - 'A';
    if (b >= 'A' && b <= 'Z') b += 'a' - 'A';
    if (a != b) return false;
  }
  return true;
}
bool boolean(const std::string& value, EncodingOption id)
{
  bool result;
  if (core::parseBooleanValue(value,result)) return result;
  throw OptionError(OptionErrorCode::InvalidValue, id);
}
int integer(const std::string& value, const EncodingOptionSchema& schema)
{
  // Preserve legacy base-0 decimal/octal/hex and leading whitespace/sign, but
  // reject empty input rather than accidentally accepting it as zero.
  size_t offset = value.find_first_not_of(" \t\r\n\f\v");
  if (offset == std::string::npos)
    throw OptionError(OptionErrorCode::InvalidValue, schema.id);
  const bool negative = value[offset] == '-';
  if (negative || value[offset] == '+') ++offset;
  int base = 10;
  if (offset < value.size() && value[offset] == '0') {
    base = 8;
    if (offset + 1 < value.size() && (value[offset + 1] == 'x' || value[offset + 1] == 'X')) {
      base = 16; offset += 2;
    }
  }
  if (offset == value.size()) throw OptionError(OptionErrorCode::InvalidValue, schema.id);
  int number = 0;
  for (; offset < value.size(); ++offset) {
    const char digit = value[offset];
    const int part = digit >= '0' && digit <= '9' ? digit - '0' :
                    digit >= 'a' && digit <= 'f' ? digit - 'a' + 10 :
                    digit >= 'A' && digit <= 'F' ? digit - 'A' + 10 : -1;
    if (part < 0 || part >= base || number > (schema.maximum - part) / base)
      throw OptionError(OptionErrorCode::InvalidValue, schema.id);
    number = number * base + part;
    if (number > schema.maximum) throw OptionError(OptionErrorCode::InvalidValue, schema.id);
  }
  if (negative) number = -number;
  if (number < schema.minimum) throw OptionError(OptionErrorCode::InvalidValue, schema.id);
  return number;
}
size_t index(EncodingOption id)
{
  const auto result = static_cast<size_t>(id);
  if (result >= static_cast<size_t>(EncodingOption::Count))
    throw OptionError(OptionErrorCode::UnknownOption, EncodingOption::Count);
  return result;
}
}

const std::vector<EncodingOptionSchema>& encodingSchema()
{
  static const std::vector<EncodingOptionSchema> schema = {
    {EncodingOption::AutoSelect, "AutoSelect", nullptr, OptionType::Boolean, "on", 0, 1, true, true},
    {EncodingOption::FullColor, "FullColor", "FullColour", OptionType::Boolean, "on", 0, 1, true, true},
    {EncodingOption::LowColorLevel, "LowColorLevel", "LowColourLevel", OptionType::Integer, "2", 0, 2, true, true},
    {EncodingOption::PreferredEncoding, "PreferredEncoding", nullptr, OptionType::Enumeration, "Tight", 0, 0, true, true},
    {EncodingOption::CustomCompressLevel, "CustomCompressLevel", nullptr, OptionType::Boolean, "off", 0, 1, true, true},
    {EncodingOption::CompressLevel, "CompressLevel", nullptr, OptionType::Integer, "2", 0, 9, true, true},
    {EncodingOption::NoJPEG, "NoJPEG", nullptr, OptionType::Boolean, "off", 0, 1, true, true},
    {EncodingOption::QualityLevel, "QualityLevel", nullptr, OptionType::Integer, "8", 0, 9, true, true}
  };
  return schema;
}
const EncodingOptionSchema& encodingSchema(EncodingOption id)
{
  return encodingSchema()[index(id)];
}
const std::vector<EncodingChoice>& encodingChoices()
{
  static const std::vector<EncodingChoice> choices = {
    {"Tight", rfb::encodingTight, rfb::Decoder::supported(rfb::encodingTight)},
    {"JPEG", rfb::encodingJPEG, rfb::Decoder::supported(rfb::encodingJPEG)},
    {"ZRLE", rfb::encodingZRLE, rfb::Decoder::supported(rfb::encodingZRLE)},
    {"Hextile", rfb::encodingHextile, rfb::Decoder::supported(rfb::encodingHextile)},
    {"H.264", rfb::encodingH264, rfb::Decoder::supported(rfb::encodingH264)},
    {"Raw", rfb::encodingRaw, rfb::Decoder::supported(rfb::encodingRaw)}
  };
  return choices;
}
EncodingOptions::EncodingOptions()
{
  sources.fill(OptionSource::Compiled);
  // Apply schema defaults through the same validation path as all overrides.
  // withPatch copies this initialized value; it does not construct defaults.
  OptionPatch defaults;
  for (const auto& entry : encodingSchema()) defaults.push_back({entry.name, entry.defaultValue});
  *this = withPatch(defaults, OptionSource::Compiled);
}
EncodingOptions EncodingOptions::withPatch(const OptionPatch& patch, OptionSource origin) const
{
  if (origin < OptionSource::Compiled || origin > OptionSource::Document)
    throw OptionError(OptionErrorCode::InvalidValue, EncodingOption::Count);
  if (patch.size() > 256)
    throw OptionError(OptionErrorCode::TooLong, EncodingOption::Count);
  EncodingOptions next = *this;
  for (const auto& assignment : patch) {
    if (assignment.name.size() > 128 || assignment.value.size() > 128)
      throw OptionError(OptionErrorCode::TooLong, EncodingOption::Count);
    const auto& schema = encodingSchema();
    const auto found = std::find_if(schema.begin(), schema.end(), [&](const EncodingOptionSchema& entry) {
      return equal(assignment.name, entry.name) || equal(assignment.name, entry.alias);
    });
    if (found == schema.end())
      throw OptionError(OptionErrorCode::UnknownOption, EncodingOption::Count);
    const auto id = found->id;
    if (assignment.value.find('\0') != std::string::npos)
      throw OptionError(OptionErrorCode::InvalidValue, id);
    const auto& value = assignment.value;
    switch (id) {
    case EncodingOption::AutoSelect: next.automatic = boolean(value, id); break;
    case EncodingOption::FullColor: next.full = boolean(value, id); break;
    case EncodingOption::LowColorLevel: next.low = integer(value, *found); break;
    case EncodingOption::CustomCompressLevel: next.custom = boolean(value, id); break;
    case EncodingOption::CompressLevel: next.compression = integer(value, *found); break;
    case EncodingOption::NoJPEG: next.jpeg = !boolean(value, id); break;
    case EncodingOption::QualityLevel: next.quality = integer(value, *found); break;
    case EncodingOption::PreferredEncoding: {
      const auto& choices = encodingChoices();
      const auto choice = std::find_if(choices.begin(), choices.end(), [&](const EncodingChoice& entry) {
        return equal(value, entry.name);
      });
      if (choice == choices.end()) throw OptionError(OptionErrorCode::InvalidValue, id);
      if (!choice->available) throw OptionError(OptionErrorCode::Unsupported, id);
      next.preferred = choice->wireEncoding;
      break;
    }
    case EncodingOption::Count: break;
    }
    next.sources[index(id)] = origin;
  }
  return next;
}
EncodingOptions EncodingOptions::resolve(const OptionPatch& defaults,
  const OptionPatch& profile, const OptionPatch& session, const OptionPatch& commandLine)
{
  return EncodingOptions().withPatch(defaults, OptionSource::AppDefaults)
    .withPatch(profile, OptionSource::Profile).withPatch(session, OptionSource::Session)
    .withPatch(commandLine, OptionSource::CommandLine);
}
std::string EncodingOptions::value(EncodingOption id) const
{
  switch (id) {
  case EncodingOption::AutoSelect: return automatic ? "on" : "off";
  case EncodingOption::FullColor: return full ? "on" : "off";
  case EncodingOption::LowColorLevel: return std::to_string(low);
  case EncodingOption::CustomCompressLevel: return custom ? "on" : "off";
  case EncodingOption::CompressLevel: return std::to_string(compression);
  case EncodingOption::NoJPEG: return jpeg ? "off" : "on";
  case EncodingOption::QualityLevel: return std::to_string(quality);
  case EncodingOption::PreferredEncoding:
    for (const auto& choice : encodingChoices())
      if (choice.wireEncoding == preferred) return choice.name;
    break;
  case EncodingOption::Count: break;
  }
  throw OptionError(OptionErrorCode::UnknownOption, EncodingOption::Count);
}
OptionSource EncodingOptions::source(EncodingOption id) const { return sources[index(id)]; }
int EncodingOptions::selectedEncoding() const { return automatic ? rfb::encodingTight : preferred; }
int EncodingOptions::selectedCompression() const { return custom ? compression : -1; }
int EncodingOptions::selectedQuality(uint64_t bitsPerSecond) const
{
  return automatic ? (bitsPerSecond > 16000000 ? 8 : 6) : quality;
}
rfb::PixelFormat EncodingOptions::selectedFormat(uint64_t bitsPerSecond,
  const rfb::PixelFormat& fullFormat) const
{
  if (automatic ? bitsPerSecond > 256000 : full) return fullFormat;
  if (low == 0) return rfb::PixelFormat(8, 3, false, true, 1, 1, 1, 2, 1, 0);
  if (low == 1) return rfb::PixelFormat(8, 6, false, true, 3, 3, 3, 4, 2, 0);
  return rfb::PixelFormat(8, 8, false, true, 7, 7, 3, 5, 2, 0);
}
void BandwidthEstimate::observe(uint64_t bytes, uint64_t elapsedMicroseconds)
{
  const uint64_t elapsed = std::max<uint64_t>(elapsedMicroseconds, 1);
  // A 1 Tbit/s ceiling bounds integer arithmetic even for hostile stream counts.
  const long double rate = static_cast<long double>(bytes) * 8000000 / elapsed;
  const uint64_t sample = static_cast<uint64_t>(std::min<long double>(rate, 1000000000000ULL));
  const uint64_t weight = std::min<uint64_t>(elapsed, 200000);
  estimate = (estimate * (1000000 - weight) + sample * weight) / 1000000;
}
}
