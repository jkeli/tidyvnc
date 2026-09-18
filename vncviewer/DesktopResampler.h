/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_DESKTOP_RESAMPLER_H
#define TIDYVNC_DESKTOP_RESAMPLER_H
#include "DesktopTransform.h"
#include <cstddef>
#include <cstdint>

// Four byte pixels, in the caller's channel order. Alpha, when present, must
// already be premultiplied. All strides are bytes; output tiles are <=256x256.
// Tile coordinates are relative to the full destination raster, not the view.
void resampleDesktop(const uint8_t* source, int sw, int sh, size_t sourceStride,
                     uint8_t* output, size_t outputStride,
                     int dw, int dh, const core::Rect& tile,
                     ScalingSettings::Quality quality, bool alpha = false);
#endif
