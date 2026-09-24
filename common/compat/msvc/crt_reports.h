/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Debug CRT asserts, abort() and unhandled-exception reports on standard error
// instead of modal dialogs, so unattended runs fail and exit rather than wait
// for someone to click Abort/Retry/Ignore. The settings belong to the process's
// CRT (ucrtbase/ucrtbased), so every module linked to the same CRT follows them.
// Used by every MSVC test executable (crt_reports.cxx) and exported by the WinUI
// helper as tvw_quiet_crt_reports for .NET test hosts and isolated app runs.
#ifndef TIDYVNC_COMPAT_MSVC_CRT_REPORTS_H
#define TIDYVNC_COMPAT_MSVC_CRT_REPORTS_H

#include <windows.h>
#include <crtdbg.h>
#include <cstdlib>

namespace tidyvnc {

inline void quietCrtReports() noexcept
{
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

}

#endif
