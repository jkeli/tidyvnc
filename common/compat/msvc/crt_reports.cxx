/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Linked into every MSVC test and benchmark executable (tests/CMakeLists.txt):
// reports go to standard error instead of dialogs from process start.
#include "crt_reports.h"

namespace {
struct QuietCrtReports {
  QuietCrtReports() noexcept { tidyvnc::quietCrtReports(); }
};
const QuietCrtReports quiet;
}
