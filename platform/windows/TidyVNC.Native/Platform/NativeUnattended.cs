// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Storage;

namespace TidyVNC.Native.Platform;

/// <summary>
/// Unattended runs never stop on a dialog. The Debug C runtime's
/// Abort/Retry/Ignore box for abort() and failed asserts in the native DLLs
/// would otherwise block a test host or a test-launched app until someone
/// clicked it; with this they report on standard error and the process ends.
/// </summary>
public static class NativeUnattended
{
    /// <summary>Routes the native DLLs' CRT reports to standard error for this process.</summary>
    public static void QuietCrtReports() => WindowsMethods.tvw_quiet_crt_reports();

    /// <summary>
    /// Quiets the CRT reports when this process runs against an isolated test root
    /// (TIDYVNC_STATE_ROOT in Debug and measurement builds): the UI tests, smokes and
    /// measurements. Interactive runs keep the dialog, which offers the debugger.
    /// </summary>
    public static void ApplyForTestRuns()
    {
        if (!NativeStateRoot.IsIsolated) return;
        try { QuietCrtReports(); }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException)
        {
            System.Diagnostics.Trace.TraceWarning($"CRT reports not redirected: {error.Message}");
        }
    }
}
