// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native.Desktop;
using TidyVNC.Native.Platform;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Windows.DS: the helper DLL through TidyVNC.Native, and the desktop renderer
/// drawing a real session's frames into a presenter (TODO W3.4, W3.6). The
/// presenter is not attached to a panel; its surface is read back.
/// </summary>
[TestClass]
public sealed class DesktopTests
{
    public TestContext TestContext { get; set; } = null!;

    private static async Task Until(Func<bool> condition, int seconds = 10)
    {
        var deadline = Stopwatch.StartNew();
        while (!condition())
        {
            if (deadline.Elapsed > TimeSpan.FromSeconds(seconds)) Assert.Fail("Condition not reached in time");
            await Task.Delay(5);
        }
    }

    private static uint Pixel(NativePresenter presenter, int x, int y)
    {
        var bgra = presenter.Read(new TvwRect(x, y, 1, 1));
        return BitConverter.ToUInt32(bgra);
    }

    [TestMethod]
    public void PresenterRoundTripsPixels()
    {
        using var presenter = new NativePresenter();
        presenter.Resize(64, 32, 1.25f, 1.25f);
        var tile = new byte[16 * 16 * 4];
        for (var i = 0; i < tile.Length; i += 4) { tile[i] = 30; tile[i + 1] = 20; tile[i + 2] = 10; tile[i + 3] = 255; }
        presenter.Upload(tile, 16 * 4, new TvwRect(8, 8, 16, 16));
        presenter.Present([]);
        Assert.AreEqual(0xff0a141eu, Pixel(presenter, 8, 8));
        Assert.AreEqual(0xff000000u, Pixel(presenter, 7, 8));
        presenter.Clear(new TvwRect(0, 0, 64, 32));
        Assert.AreEqual(0xff000000u, Pixel(presenter, 8, 8));
        Assert.ThrowsExactly<ArgumentException>(() => presenter.Upload(tile.AsSpan(0, 10), 64, new TvwRect(0, 0, 16, 16)));
        presenter.Dispose();
        Assert.ThrowsExactly<ObjectDisposedException>(() => presenter.Present([]));
    }

    [TestMethod]
    public void KeyboardDisplaysAndCursorsThroughTheBridge()
    {
        using var keyboard = new NativeKeyboard();
        var escape = new TvwKeyMessage { Message = 0x0100, WParam = 0x1b, LParam = 1 | (0x01 << 16), Time = 10 };
        var result = keyboard.Translate(escape);
        Assert.IsTrue(result.Consumed);
        Assert.HasCount(1, result.Events);
        Assert.AreEqual(new NativeKeyEvent(true, 0x01, 0x01, 0xff1b), result.Events[0]);
        Assert.IsNull(result.TimerDelay);
        Assert.AreEqual(0xff1bu, keyboard.KeySyms(0x01)[0]);
        Assert.AreEqual(0u, NativeKeyboard.LedState & ~7u);

        var displays = NativeDisplays.Query();
        if (displays.Count > 0)
        {
            Assert.AreEqual(1, displays.Count(d => d.Primary));
            Assert.AreEqual(displays.Count, displays.Select(d => d.Id).Distinct().Count());
            TestContext.WriteLine(string.Join("; ", displays.Select(d => $"{d.Name} {d.Bounds} {d.DpiX}dpi")));
        }

        var rgba = new byte[8 * 8 * 4];
        using var cursor = new NativeCursorHandle(rgba, 8, 8, 1, 1);
        Assert.AreNotEqual(IntPtr.Zero, cursor.Handle);
    }

    /// <summary>
    /// A 2x2 desktop in a 100x50 viewport (FixedRatio) becomes a 50x50 square
    /// centred at x=25 with black bars; a flood of updates is rendered from the
    /// core's tiles and merged when the renderer falls behind.
    /// </summary>
    [TestMethod]
    public async Task RendererDrawsSessionFramesWithLetterboxAndFollowsUpdates()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer();
        var outcome = await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1] });
            using var renderer = new DesktopRenderer(ui, _ => { });
            DesktopRenderStatistics latest = default;
            renderer.Presented += statistics => latest = statistics;
            Exception? failure = null;
            renderer.Failed += error => failure = error;
            session.FrameUpdated += renderer.Submit;
            renderer.Resize(new DesktopViewport(100, 50, 100, 50, 1.0, Filter: NativeScalingFilter.Nearest));
            await session.ConnectAsync(peer.Endpoint);
            await Until(() => latest.Frames >= 1 && session.HasFrame);
            await Until(() => Pixel(renderer.Presenter, 50, 25) == 0xff0a141e);
            var inside = Pixel(renderer.Presenter, 26, 1);
            var leftBar = Pixel(renderer.Presenter, 24, 25);
            var rightBar = Pixel(renderer.Presenter, 75, 25);

            // A second scale: the surface doubles, the desktop is re-rendered.
            renderer.Resize(new DesktopViewport(200, 100, 100, 50, 2.0, Filter: NativeScalingFilter.Nearest));
            await Until(() => renderer.Presenter.Width == 200 && Pixel(renderer.Presenter, 100, 50) == 0xff0a141e);
            var scaledLeftBar = Pixel(renderer.Presenter, 49, 50);

            await peer.FloodAsync(40);
            var last = unchecked((byte)(39 * 7));
            await Until(() => (Pixel(renderer.Presenter, 100, 50) & 0xff0000) >> 16 == last);
            session.FrameUpdated -= renderer.Submit;
            await runtime.ShutdownAsync();
            return (inside, leftBar, rightBar, scaledLeftBar, latest, failure);
        });
        Assert.IsNull(outcome.failure);
        Assert.AreEqual(0xff0a141eu, outcome.inside);
        Assert.AreEqual(0xff000000u, outcome.leftBar);
        Assert.AreEqual(0xff000000u, outcome.rightBar);
        Assert.AreEqual(0xff000000u, outcome.scaledLeftBar);
        TestContext.WriteLine($"Frames {outcome.latest.Frames}, tiles {outcome.latest.TilesRendered}, cached {outcome.latest.TilesCached}, " +
                              $"full {outcome.latest.FullRedraws}, worst {outcome.latest.WorstFrame.TotalMilliseconds:F2} ms");
    }

    /// <summary>W0.5 measurement: 30 full 1080p updates rendered at identity and at 1.5x.</summary>
    [TestMethod]
    [DataRow(1.0)]
    [DataRow(1.5)]
    public async Task RendererKeepsUpWithFullHdUpdates(double scale)
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer(width: 1920, height: 1080);
        uint width = (uint)(1920 * scale), height = (uint)(1080 * scale);
        var (statistics, elapsed) = await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1] });
            using var renderer = new DesktopRenderer(ui, _ => { });
            session.FrameUpdated += renderer.Submit;
            renderer.Resize(new DesktopViewport(width, height, 1920, 1080, scale));
            await session.ConnectAsync(peer.Endpoint);
            await Until(() => renderer.Statistics.Frames >= 1);
            var clock = Stopwatch.StartNew();
            await peer.FloodAsync(30);
            var last = unchecked((byte)(29 * 7));
            await Until(() => (Pixel(renderer.Presenter, (int)width / 2, (int)height / 2) & 0xff0000) >> 16 == last, 60);
            var result = (renderer.Statistics, clock.Elapsed);
            session.FrameUpdated -= renderer.Submit;
            await runtime.ShutdownAsync();
            return result;
        });
        TestContext.WriteLine($"{width}x{height} at {scale}x: 30 updates in {elapsed.TotalMilliseconds:F0} ms; " +
                              $"{statistics.Frames} frames presented, {statistics.TilesRendered} tiles, " +
                              $"worst {statistics.WorstFrame.TotalMilliseconds:F1} ms, last {statistics.LastFrame.TotalMilliseconds:F1} ms");
        Assert.IsGreaterThan(1L, statistics.Frames);
    }
}
