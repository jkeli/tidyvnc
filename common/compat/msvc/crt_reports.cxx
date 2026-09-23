/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Linked into every MSVC test and benchmark executable (tests/CMakeLists.txt).
// Debug CRT asserts, abort() and unhandled-exception reports go to standard
// error instead of modal dialogs, so unattended test runs fail and exit
// rather than waiting for someone to click Abort/Retry/Ignore.
#include <windows.h>
#include <crtdbg.h>
#include <cstdlib>

namespace {
struct QuietCrtReports {
  QuietCrtReports() noexcept {
    ::SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
    // Macros that compile away without the Debug CRT, so no loop variable.
    _CrtSetReportMode(_CRT_WARN, _CRTDBG_MODE_FILE | _CRTDBG_MODE_DEBUG);
    _CrtSetReportFile(_CRT_WARN, _CRTDBG_FILE_STDERR);
    _CrtSetReportMode(_CRT_ERROR, _CRTDBG_MODE_FILE | _CRTDBG_MODE_DEBUG);
    _CrtSetReportFile(_CRT_ERROR, _CRTDBG_FILE_STDERR);
    _CrtSetReportMode(_CRT_ASSERT, _CRTDBG_MODE_FILE | _CRTDBG_MODE_DEBUG);
    _CrtSetReportFile(_CRT_ASSERT, _CRTDBG_FILE_STDERR);
  }
};
const QuietCrtReports quiet;
}
