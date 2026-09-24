/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Unattended runs: the process's CRT reports asserts and abort() on standard
// error instead of modal dialogs (common/compat/msvc/crt_reports.h).
#include "tidyvnc_windows.h"
#include "crt_reports.h"

extern "C" void tvw_quiet_crt_reports(void)
{
  tidyvnc::quietCrtReports();
}
