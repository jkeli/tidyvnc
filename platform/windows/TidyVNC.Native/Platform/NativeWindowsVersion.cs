// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Globalization;

namespace TidyVNC.Native.Platform;

/// <summary>
/// Windows 11 only (DECISIONS.md D6, PACKAGING.md section 4): TidyVNC.exe and
/// vncviewer.exe refuse older Windows at start-up, as the MSI does, so a
/// copied folder on Windows 10 exits with a message instead of failing
/// unpredictably. TIDYVNC_TEST_WINDOWS_BUILD simulates another build for tests.
/// </summary>
public static class NativeWindowsVersion
{
    /// <summary>Windows 11's first build.</summary>
    public const int FirstSupportedBuild = 22000;

    public const string TestOverride = "TIDYVNC_TEST_WINDOWS_BUILD";

    /// <summary>The console launcher's message (fixed English, like its other errors).</summary>
    public const string RefusalText =
        "This version of TidyVNC requires Windows 11. On earlier versions of Windows, use the classic TidyVNC viewer (vncviewer) instead.";

    public static int CurrentBuild =>
        int.TryParse(Environment.GetEnvironmentVariable(TestOverride), NumberStyles.None, CultureInfo.InvariantCulture, out var build)
            ? build : Environment.OSVersion.Version.Build;

    public static bool IsSupported(int build) => build >= FirstSupportedBuild;
}
