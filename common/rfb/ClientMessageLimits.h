/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */

#ifndef RFB_CLIENT_MESSAGE_LIMITS_H
#define RFB_CLIENT_MESSAGE_LIMITS_H

#include <climits>
#include <cstdint>
#include <stdexcept>

namespace rfb {

  constexpr uint32_t defaultMaxCutText = 256 * 1024;

  // Value-only incoming message policy. The clipboard limit applies to plain
  // text, the extended wire payload, and each decompressed format separately.
  // It is not a total transport-buffer or aggregate decompression budget.
  struct ClientMessageLimits {
    uint32_t maxCutText = defaultMaxCutText;

    void validate() const {
      if (maxCutText > INT_MAX)
        throw std::invalid_argument("Clipboard limit exceeds INT_MAX");
    }
  };

}

#endif
