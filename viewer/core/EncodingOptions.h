/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_ENCODING_OPTIONS_H
#define TIDYVNC_ENCODING_OPTIONS_H

#include <rfb/PixelFormat.h>
#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace viewer {
enum class EncodingOption {
  AutoSelect, FullColor, LowColorLevel, PreferredEncoding,
  CustomCompressLevel, CompressLevel, NoJPEG, QualityLevel, Count
};
enum class OptionSource { Compiled, AppDefaults, Profile, Session, CommandLine, Document };
enum class OptionType { Boolean, Integer, Enumeration };
enum class OptionErrorCode { UnknownOption, InvalidValue, Unsupported, TooLong };
class OptionError : public std::invalid_argument {
public:
  OptionError(OptionErrorCode reason, EncodingOption option)
    : std::invalid_argument("Invalid encoding option"), code(reason), id(option) {}
  const OptionErrorCode code;
  const EncodingOption id; // Count for an unknown option; no user data in error.
};
struct OptionAssignment { std::string name, value; };
using OptionPatch = std::vector<OptionAssignment>;
struct EncodingChoice {
  const char* name;
  int wireEncoding;
  bool available; // false means the decoder was not compiled into this build.
};
struct EncodingOptionSchema {
  EncodingOption id;
  const char* name;
  const char* alias;
  OptionType type;
  const char* defaultValue;
  int minimum, maximum;
  // These settings are all persisted in defaults/profiles and can be changed
  // live. Servers before RFB 3.8 cannot safely change pixel format.
  bool persistent, live;
};
const std::vector<EncodingOptionSchema>& encodingSchema();
const EncodingOptionSchema& encodingSchema(EncodingOption id);
const std::vector<EncodingChoice>& encodingChoices();

// Immutable validated snapshot, with source metadata per canonical setting.
// Parsing never consults or mutates the legacy process parameter registry.
class EncodingOptions {
public:
  EncodingOptions();
  // Transactional: validation failure leaves the original snapshot unchanged.
  // Names, aliases and enums are ASCII case-insensitive; duplicate keys within
  // a patch use the final assignment. A patch is limited to 256 assignments,
  // each name/value to 128 bytes. No embedded NUL or input-bearing diagnostics.
  EncodingOptions withPatch(const OptionPatch& patch, OptionSource source) const;
  static EncodingOptions resolve(const OptionPatch& defaults,
                                 const OptionPatch& profile,
                                 const OptionPatch& session,
                                 const OptionPatch& commandLine);
  std::string value(EncodingOption id) const;
  OptionSource source(EncodingOption id) const;
  bool autoSelect() const { return automatic; }
  bool fullColor() const { return full; }
  int lowColorLevel() const { return low; }
  int preferredEncoding() const { return preferred; }
  bool customCompressLevel() const { return custom; }
  int compressLevel() const { return compression; }
  bool jpegAllowed() const { return jpeg; }
  int qualityLevel() const { return quality; }

  // Effective protocol policy. The framebuffer format is independent of this
  // requested wire format; the RFB decoders convert as needed.
  int selectedEncoding() const;
  int selectedCompression() const;
  int selectedQuality(uint64_t bitsPerSecond) const;
  rfb::PixelFormat selectedFormat(uint64_t bitsPerSecond,
                                  const rfb::PixelFormat& fullFormat) const;
private:
  bool automatic = true, full = true, custom = false, jpeg = true;
  int low = 2, preferred = 0, compression = 2, quality = 8;
  std::array<OptionSource, static_cast<size_t>(EncodingOption::Count)> sources;
};

// Same one-second weighting/20% cap as the retained viewer, with bounded
// arithmetic and caller-supplied monotonic elapsed microseconds. No timers or IO.
class BandwidthEstimate {
public:
  uint64_t bitsPerSecond() const { return estimate; }
  void observe(uint64_t bytes, uint64_t elapsedMicroseconds);
private:
  uint64_t estimate = 20000000;
};
}
#endif
