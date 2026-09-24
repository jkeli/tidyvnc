// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Desktop;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Pan desktop (plans/native-ui-winui TODO W5.11, PARITY M12; macOS
/// NativeGeometry pan tests): steps of 80% of the view within the desktop,
/// nothing to pan when the desktop fits, and device units scale the steps.
/// </summary>
[TestClass]
public sealed class PanTests
{
    [TestMethod]
    public void PanningStaysWithinTheDesktop()
    {
        var unscaled = new NativeGeometry(1920, 1080, 800, 600, 1, "100");
        Assert.AreEqual((1120.0, 480.0), unscaled.PanLimit);
        Assert.AreEqual((640.0, 0.0), unscaled.Panned(NativeDesktopPan.Right));
        Assert.AreEqual((0.0, 0.0), unscaled.Panned(NativeDesktopPan.Left), "never before the top left");

        var right = new NativeGeometry(1920, 1080, 800, 600, 1, "100", panX: 1000, panY: 480);
        Assert.AreEqual((1000.0, 480.0), right.PanPosition);
        Assert.AreEqual((1120.0, 480.0), right.Panned(NativeDesktopPan.Right), "clamped to the limit");
        Assert.AreEqual((1000.0, 0.0), right.Panned(NativeDesktopPan.Up));
        Assert.AreEqual((0.0, 0.0), right.Panned(NativeDesktopPan.Origin));
        var beyond = new NativeGeometry(1920, 1080, 800, 600, 1, "100", panX: 5000, panY: 5000);
        Assert.AreEqual((1120.0, 480.0), beyond.PanPosition, "a stale pan is clamped");

        var fitted = new NativeGeometry(1920, 1080, 800, 600, 1, "FixedRatio");
        Assert.AreEqual((0.0, 0.0), fitted.PanLimit, "a fitted desktop has nothing to pan");

        // Device units at 200%: the limit and steps are in device pixels.
        var device = new NativeGeometry(1920, 1080, 800, 600, 2, "100", devicePixels: true);
        Assert.AreEqual((320.0, 0.0), device.PanLimit);
        Assert.AreEqual((320.0, 0.0), device.Panned(NativeDesktopPan.Right));
    }

    /// <summary>W5.19 / V02: the desktop view's UI Automation Scroll pattern is the pan in percent.</summary>
    [TestMethod]
    public void ScrollPercentagesFollowThePan()
    {
        var geometry = new NativeGeometry(1920, 1080, 800, 600, 1, "100", panX: 560, panY: 480);
        Assert.AreEqual((50.0, 100.0), geometry.ScrollPercent);
        Assert.AreEqual(800.0 / 1920 * 100, geometry.ViewPercent.X, 1e-9);
        Assert.AreEqual(600.0 / 1080 * 100, geometry.ViewPercent.Y, 1e-9);
        Assert.AreEqual((1120.0, 480.0), geometry.PannedTo(100, -1), "-1 keeps the vertical position");
        Assert.AreEqual((0.0, 240.0), geometry.PannedTo(0, 50));

        var fitted = new NativeGeometry(1920, 1080, 800, 600, 1, "FixedRatio");
        Assert.AreEqual((-1.0, -1.0), fitted.ScrollPercent, "nothing to scroll (UIA_ScrollPatternNoScroll)");
        Assert.AreEqual((100.0, 100.0), fitted.ViewPercent);
        Assert.AreEqual((0.0, 0.0), fitted.PannedTo(40, 40));
    }
}
