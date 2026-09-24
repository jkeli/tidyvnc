// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Platform;

namespace TidyVNC.Native.Tests;

/// <summary>
/// The suite runs unattended: an abort() or failed assert in a Debug native DLL
/// reports on standard error and ends the run instead of opening the Debug C
/// runtime's Abort/Retry/Ignore dialog on the desktop and waiting for a click.
/// </summary>
[TestClass]
public static class Unattended
{
    [AssemblyInitialize]
    public static void QuietNativeReports(TestContext context) => NativeUnattended.QuietCrtReports();
}
