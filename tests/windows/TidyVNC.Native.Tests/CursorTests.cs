// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native.Desktop;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Remote cursors (plans/native-ui-winui TODO W6.3, D13; DESKTOP.md section 3):
/// the server's cursor is sampled by the shared cursor sampler at the view's
/// scale with its hotspot, blank cursors are detected, and the retained rules
/// choose between the remote cursor, the dot, the system arrow and none.
/// </summary>
[TestClass]
public sealed class CursorTests
{
    private static async Task Until(Func<bool> condition, string what)
    {
        var clock = Stopwatch.StartNew();
        while (!condition())
        {
            if (clock.Elapsed > TimeSpan.FromSeconds(10)) Assert.Fail($"Timed out: {what}");
            await Task.Delay(5);
        }
    }

    [TestMethod]
    public async Task ServerCursorsAreSampledAtTheViewScale()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer(width: 32, height: 32);
        var (scaled, blank) = await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1] });
            try
            {
                await session.ConnectAsync(peer.Endpoint);
                await Until(() => session.HasFrame, "the first frame");
                await peer.CursorAsync(4, 4, 1, 2);
                await Until(() => session.Cursor is { Width: 4 }, "the cursor");
                var shape = NativeCursorSampler.Sample(session.Cursor!, 1.5, 1.5, NativeScalingFilter.Nearest);
                var previous = session.Cursor;
                await peer.CursorAsync(4, 4, 0, 0, visible: false);
                await Until(() => !ReferenceEquals(session.Cursor, previous) && session.Cursor is not null, "the blank cursor");
                var empty = NativeCursorSampler.Sample(session.Cursor!, 1.0, 1.0, NativeScalingFilter.Bilinear);
                return (shape, empty);
            }
            finally
            {
                await session.CloseAsync();
                await runtime.ShutdownAsync();
            }
        });
        Assert.AreEqual((6u, 6u), (scaled.Width, scaled.Height), "4x4 at 1.5x");
        Assert.IsFalse(scaled.Blank);
        Assert.IsTrue(scaled.HotspotX is >= 1 and <= 2 && scaled.HotspotY == 3, $"hotspot ({scaled.HotspotX},{scaled.HotspotY}) follows the scale");
        Assert.AreEqual(200, scaled.Rgba[0], "straight RGBA: red first");
        Assert.AreEqual(255, scaled.Rgba[3]);
        Assert.IsTrue(blank.Blank, "an all-clear mask is a blank cursor");
    }

    [TestMethod]
    public void RetainedRulesChooseTheShownCursor()
    {
        Assert.AreEqual(NativeCursorChoice.System, NativeCursorPolicy.Choose(viewOnly: true, blank: false, NativeCursorFallback.Dot), "view-only: arrow");
        Assert.AreEqual(NativeCursorChoice.Remote, NativeCursorPolicy.Choose(false, false, NativeCursorFallback.Hidden));
        Assert.AreEqual(NativeCursorChoice.Hidden, NativeCursorPolicy.Choose(false, true, NativeCursorFallback.Hidden));
        Assert.AreEqual(NativeCursorChoice.Dot, NativeCursorPolicy.Choose(false, true, NativeCursorFallback.Dot));
        Assert.AreEqual(NativeCursorChoice.System, NativeCursorPolicy.Choose(false, true, NativeCursorFallback.System));

        var dot = NativeCursorPolicy.Dot(1.0);
        Assert.AreEqual((5u, 5u, 2u, 2u), (dot.Width, dot.Height, dot.HotspotX, dot.HotspotY));
        Assert.AreEqual(255, dot.Rgba[0], "white border");
        Assert.AreEqual(0, dot.Rgba[(2 * 5 + 2) * 4], "black centre");
        var large = NativeCursorPolicy.Dot(2.0);
        Assert.AreEqual((10u, 5u), (large.Width, large.HotspotX));

        Assert.AreEqual((2.0, 2.0), NativeCursorPolicy.FitScale(32, 32, 2, 2, 256, 256), "fits: unchanged");
        var (x, y) = NativeCursorPolicy.FitScale(128, 64, 4, 4, 256, 256);
        Assert.IsTrue(128 * x <= 256 && 64 * y <= 256 && Math.Abs(x - 2) < 1e-9, "too large: shrunk to the limit");
    }
}
