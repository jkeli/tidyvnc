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

        Assert.IsFalse(NativeCursorPolicy.NeedsSoftware(32, 32, 2, 2, 1024, 1024), "64 pixels: an HCURSOR");
        Assert.IsFalse(NativeCursorPolicy.NeedsSoftware(128, 128, 8, 8, 1024, 1024), "exactly the limit: an HCURSOR");
        Assert.IsTrue(NativeCursorPolicy.NeedsSoftware(128, 64, 8.01, 1, 1024, 1024), "wider than the limit: software");
        Assert.IsTrue(NativeCursorPolicy.NeedsSoftware(16, 256, 1, 4.5, 1024, 1024), "taller than the limit: software");
    }

    [TestMethod]
    public void SoftwareCursorsSitOnTheDevicePixelGridAndClipToTheDesktop()
    {
        // The hotspot lands on the device pixel under the pointer (macOS NativeCursorRenderer).
        Assert.AreEqual((90.0, 40.0), NativeCursorPolicy.SoftwareOrigin(100.4, 50.9, 1.0, 10, 10));
        var (x, y) = NativeCursorPolicy.SoftwareOrigin(100.4, 50.9, 1.5, 3, 0);
        Assert.AreEqual(((150 - 3) / 1.5, 76 / 1.5), (x, y));

        // Fully inside: the whole cursor.
        Assert.AreEqual(new NativePixelRect(0, 0, 2000, 1500),
            NativeCursorPolicy.VisibleRegion(2000, 1500, (10, 10), 1.0, (0, 0, 4000, 4000)));
        // Clipped by the desktop's right and bottom edges, at 2x: device pixels, rounded outwards.
        Assert.AreEqual(new NativePixelRect(0, 0, 181, 80),
            NativeCursorPolicy.VisibleRegion(2000, 2000, (100, 200), 2.0, (0, 0, 190.25, 240)));
        // Clipped on the left and top (the pointer near the desktop's origin).
        Assert.AreEqual(new NativePixelRect(50, 20, 1950, 1980),
            NativeCursorPolicy.VisibleRegion(2000, 2000, (-50, -20), 1.0, (0, 0, 3000, 3000)));
        // In the letterbox, or on a zero-sized desktop: nothing.
        Assert.AreEqual(0u, NativeCursorPolicy.VisibleRegion(2000, 2000, (500, 0), 1.0, (0, 0, 400, 400)).Width);
        Assert.AreEqual(0u, NativeCursorPolicy.VisibleRegion(2000, 2000, (0, 0), 1.0, (0, 0, 0, 0)).Width);
    }

    [TestMethod]
    public async Task LargeCursorsRenderOnlyVisibleTilesAndReuseThemWhileThePointerMoves()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer(width: 32, height: 32);
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1] });
            try
            {
                await session.ConnectAsync(peer.Endpoint);
                await Until(() => session.HasFrame, "the first frame");
                await peer.CursorAsync(4, 4, 1, 2);
                await Until(() => session.Cursor is { Width: 4 }, "the cursor");
                var cursor = session.Cursor!;
                Assert.IsTrue(NativeCursorPolicy.NeedsSoftware(4, 4, 300, 300, 1024, 1024));

                using var tiles = new NativeCursorTiles(cursor, 300, 300, NativeScalingFilter.Nearest);
                Assert.AreEqual((1200u, 1200u), (tiles.Width, tiles.Height));
                Assert.IsTrue(tiles.Samples(cursor, 300, 300, NativeScalingFilter.Nearest));
                Assert.IsFalse(tiles.Samples(cursor, 300, 300, NativeScalingFilter.Bilinear));

                // A small visible region needs one tile of the 256-pixel grid.
                var (first, reused) = tiles.Render(new NativePixelRect(300, 300, 10, 10));
                Assert.AreEqual(1, first.Count);
                Assert.AreEqual(new NativePixelRect(256, 256, 256, 256), first[0].Rect);
                Assert.AreEqual(0, reused);

                // Moving so the region spans four tiles renders three and keeps the one already drawn.
                (var moved, reused) = tiles.Render(new NativePixelRect(250, 250, 20, 20));
                Assert.AreEqual(4, moved.Count);
                Assert.AreEqual(1, reused);
                Assert.IsTrue(moved.Any(tile => ReferenceEquals(tile, first[0])), "the drawn tile is reused");

                // The edge tiles are cut to the cursor, and nothing visible means no tiles.
                var (edge, _) = tiles.Render(new NativePixelRect(1100, 1100, 500, 500));
                Assert.AreEqual(new NativePixelRect(1024, 1024, 176, 176), edge.Single().Rect);
                Assert.AreEqual(0, tiles.Render(new NativePixelRect(0, 0, 0, 0)).Tiles.Count);

                // The tiles are the same pixels as the whole cursor sampled at once.
                var whole = NativeCursorSampler.Sample(cursor, 300, 300, NativeScalingFilter.Nearest);
                var (all, _) = tiles.Render(new NativePixelRect(0, 0, 1200, 1200));
                Assert.AreEqual(25, all.Count);
                foreach (var tile in all)
                    for (var row = 0; row < tile.Rect.Height; row++)
                        CollectionAssert.AreEqual(
                            whole.Rgba.AsSpan((int)(((tile.Rect.Y + row) * 1200 + tile.Rect.X) * 4), (int)tile.Rect.Width * 4).ToArray(),
                            tile.Rgba.AsSpan(row * (int)tile.Rect.Width * 4, (int)tile.Rect.Width * 4).ToArray(),
                            $"tile {tile.Rect} row {row}");
                Assert.AreEqual((whole.HotspotX, whole.HotspotY), (tiles.HotspotX, tiles.HotspotY));
            }
            finally
            {
                await session.CloseAsync();
                await runtime.ShutdownAsync();
            }
        });
    }

    [TestMethod]
    public void TilesBecomePremultipliedBgraForBitmaps()
    {
        var tile = new NativeCursorTile(new NativePixelRect(0, 0, 2, 1), [200, 100, 50, 255, 200, 100, 50, 128]);
        CollectionAssert.AreEqual(new byte[] { 50, 100, 200, 255, 25, 50, 100, 128 }, tile.PremultipliedBgra());
    }
}
