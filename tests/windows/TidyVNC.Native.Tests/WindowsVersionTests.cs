// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Platform;

namespace TidyVNC.Native.Tests;

/// <summary>Windows 11 only (plans/native-ui-winui D6, W5.21/W7.7): the start-up check both executables share.</summary>
[TestClass]
public sealed class WindowsVersionTests
{
    [TestMethod]
    public void Windows11IsTheFirstSupportedBuild()
    {
        Assert.IsFalse(NativeWindowsVersion.IsSupported(19045), "Windows 10 22H2");
        Assert.IsFalse(NativeWindowsVersion.IsSupported(21999));
        Assert.IsTrue(NativeWindowsVersion.IsSupported(22000), "Windows 11 21H2");
        Assert.IsTrue(NativeWindowsVersion.IsSupported(26100), "Windows 11 24H2");
        if (Environment.GetEnvironmentVariable(NativeWindowsVersion.TestOverride) is null)
            Assert.AreEqual(Environment.OSVersion.Version.Build, NativeWindowsVersion.CurrentBuild, "the real build without the test override");
        StringAssert.Contains(NativeWindowsVersion.RefusalText, "Windows 11");
    }
}
