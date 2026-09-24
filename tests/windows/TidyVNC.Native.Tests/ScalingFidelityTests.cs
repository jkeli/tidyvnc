// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native.Desktop;
using TidyVNC.Native.Interop;
using TidyVNC.Native.Platform;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Scaling fidelity (plans/native-ui-winui TODO W6.2, PARITY W05; DESKTOP.md
/// sections 1-2). At 100, 125, 150 and 175% scale, for every scaling mode, filter
/// and unit, the pixels the Windows presenter shows are exactly the shared
/// renderer's output for that transform (no Direct3D resampling, black
/// letterboxing), and the inverse input mapping sends each remote pixel's
/// centre back to that pixel.
/// </summary>
[TestClass]
public sealed class ScalingFidelityTests
{
    private static readonly double[] Scales = [1.0, 1.25, 1.5, 1.75];
    private static readonly string[] Modes = ["100", "Auto", "FixedRatio", "FitWidth", "FitHeight", "41x29", "137.5", "125%x80%"];
    private static readonly NativeScalingFilter[] Filters = [NativeScalingFilter.Nearest, NativeScalingFilter.Bilinear, NativeScalingFilter.Area];
    private const ushort RemoteWidth = 64, RemoteHeight = 48;
    private const double ViewWidth = 160, ViewHeight = 100;

    public TestContext TestContext { get; set; } = null!;

    /// <summary>The shared renderer's full backing image for a geometry (the golden output).</summary>
    private static unsafe byte[] Golden(NativeImage image, NativeGeometry geometry, NativeScalingFilter filter)
    {
        ulong raw;
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_renderer_create(16u << 20, &raw, &error), &error);
        using var renderer = NativeHandle.Adopt(raw);
        int width = (int)geometry.BackingWidth, height = (int)geometry.BackingHeight;
        var output = new byte[width * height * 4];
        var tile = new byte[256 * 256 * 4];
        var options = Abi.Init<tidyvnc_tile_options>();
        options.width = geometry.BackingWidth; options.height = geometry.BackingHeight; options.quality = (uint)filter;
        options.damage_width = image.Width; options.damage_height = image.Height;
        for (var y = 0; y < height; y += 256)
            for (var x = 0; x < width; x += 256)
            {
                int w = Math.Min(256, width - x), h = Math.Min(256, height - y);
                options.x = (uint)x; options.y = (uint)y; options.tile_width = (uint)w; options.tile_height = (uint)h;
                var result = Abi.Init<tidyvnc_tile_result>();
                fixed (byte* p = tile)
                {
                    var span = new tidyvnc_mutable_bytes { data = p, length = (ulong)tile.Length };
                    Abi.Check(NativeMethods.tidyvnc_renderer_render(renderer.Raw, image.Handle.Raw, &options, span, &result, &error), &error);
                }
                for (var row = 0; row < h; row++)
                    Array.Copy(tile, row * w * 4, output, ((y + row) * width + x) * 4, w * 4);
            }
        return output;
    }

    /// <summary>Whether the frame holds more than black: the peer's pattern has been drawn into it.</summary>
    private static bool Painted(NativeImage image)
    {
        var pixels = Golden(image, new NativeGeometry(image.Width, image.Height, image.Width, image.Height, 1.0, "100"), NativeScalingFilter.Nearest);
        for (var i = 0; i < pixels.Length; i += 4)
            if (pixels[i] != 0 || pixels[i + 1] != 0 || pixels[i + 2] != 0) return true;
        return false;
    }

    /// <summary>The expected surface: the golden image at its placement, opaque black elsewhere.</summary>
    private static byte[] Expected(NativeImage image, NativeGeometry geometry, NativeScalingFilter filter, int surfaceWidth, int surfaceHeight, double scale)
    {
        var golden = Golden(image, geometry, filter);
        var expected = new byte[surfaceWidth * surfaceHeight * 4];
        for (var i = 3; i < expected.Length; i += 4) expected[i] = 0xff;
        int offsetX = (int)Math.Round(geometry.X * scale), offsetY = (int)Math.Round(geometry.Y * scale);
        for (var y = 0; y < geometry.BackingHeight; y++)
        {
            var sy = y + offsetY;
            if (sy < 0 || sy >= surfaceHeight) continue;
            for (var x = 0; x < geometry.BackingWidth; x++)
            {
                var sx = x + offsetX;
                if (sx < 0 || sx >= surfaceWidth) continue;
                Array.Copy(golden, (y * (int)geometry.BackingWidth + x) * 4, expected, (sy * surfaceWidth + sx) * 4, 4);
            }
        }
        return expected;
    }

    [TestMethod]
    [Timeout(600_000)]
    public async Task PresentedPixelsEqualTheSharedRendererAtFractionalScales()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer(width: RemoteWidth, height: RemoteHeight, pattern: true);
        var (cases, failures) = await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1] });
            using var renderer = new DesktopRenderer(ui, _ => { });
            Exception? failure = null;
            renderer.Failed += error => failure = error;
            session.FrameUpdated += renderer.Submit;
            var failed = new List<string>();
            var count = 0;
            try
            {
                await session.ConnectAsync(peer.Endpoint);
                // The framebuffer exists (blank) before the patterned update fills it; compare against the pattern.
                var clock = Stopwatch.StartNew();
                while (!(session.Frame is { } frame && Painted(frame)) && clock.Elapsed < TimeSpan.FromSeconds(10)) await Task.Delay(5);
                using var image = session.Frame!.Clone();
                Assert.IsTrue(Painted(image), "the patterned frame arrived");
                foreach (var scale in Scales)
                    foreach (var mode in Modes)
                        foreach (var filter in Filters)
                            foreach (var device in new[] { false, true })
                            {
                                count++;
                                int width = (int)Math.Ceiling(ViewWidth * scale), height = (int)Math.Ceiling(ViewHeight * scale);
                                renderer.Resize(new DesktopViewport((uint)width, (uint)height, ViewWidth, ViewHeight, scale, mode, filter, device));
                                var geometry = new NativeGeometry(image.Width, image.Height, ViewWidth, ViewHeight, scale, mode, device);
                                var expected = Expected(image, geometry, filter, width, height, scale);
                                // The worker presents asynchronously; wait for the surface to match (or time out).
                                var wait = Stopwatch.StartNew();
                                byte[] shown = [];
                                while (wait.Elapsed < TimeSpan.FromSeconds(5))
                                {
                                    if (renderer.Presenter.Width == width && renderer.Presenter.Height == height)
                                    {
                                        shown = renderer.Presenter.Read(new TvwRect(0, 0, width, height));
                                        if (shown.AsSpan().SequenceEqual(expected)) break;
                                    }
                                    await Task.Delay(10);
                                }
                                if (!shown.AsSpan().SequenceEqual(expected))
                                {
                                    var differ = shown.Length != expected.Length ? -1
                                        : Enumerable.Range(0, expected.Length / 4).Count(i => !shown.AsSpan(i * 4, 4).SequenceEqual(expected.AsSpan(i * 4, 4)));
                                    var first = shown.Length != expected.Length ? -1
                                        : Enumerable.Range(0, expected.Length / 4).First(i => !shown.AsSpan(i * 4, 4).SequenceEqual(expected.AsSpan(i * 4, 4)));
                                    var sample = first < 0 ? "" : $"; first at {first % width},{first / width}: shown " +
                                        Convert.ToHexString(shown, first * 4, 4) + " expected " + Convert.ToHexString(expected, first * 4, 4);
                                    failed.Add($"scale {scale} mode {mode} {filter} {(device ? "device" : "logical")}: {differ} pixels differ " +
                                               $"(presenter {renderer.Presenter.Width}x{renderer.Presenter.Height}, wanted {width}x{height}){sample}");
                                }
                                // A failed renderer or a presenter that stopped following resizes fails at once, with the
                                // cases so far, rather than waiting out every remaining case.
                                if (failure is not null || failed.Count >= 5) throw new AbortComparison();
                            }
            }
            catch (AbortComparison)
            {
                failed.Add($"stopped after {count} of 192 transforms");
            }
            finally
            {
                session.FrameUpdated -= renderer.Submit;
                await session.CloseAsync();
                await runtime.ShutdownAsync();
            }
            if (failure is not null) failed.Add("renderer failed: " + failure.Message);
            return (count, failed);
        });
        TestContext.WriteLine($"{cases} transforms compared pixel for pixel");
        Assert.AreEqual(0, failures.Count, string.Join(Environment.NewLine, failures.Take(20)));
    }

    [TestMethod]
    public void RemotePixelCentresMapBackToThemselves()
    {
        var failures = new List<string>();
        foreach (var scale in Scales)
            foreach (var mode in Modes)
                foreach (var device in new[] { false, true })
                {
                    var geometry = new NativeGeometry(RemoteWidth, RemoteHeight, ViewWidth, ViewHeight, scale, mode, device);
                    for (var ry = 0; ry < RemoteHeight; ry += 7)
                        for (var rx = 0; rx < RemoteWidth; rx += 5)
                        {
                            // The centre of remote pixel (rx, ry) in the view's logical coordinates.
                            var x = geometry.X + (rx + 0.5) * geometry.Width / RemoteWidth;
                            var y = geometry.Y + (ry + 0.5) * geometry.Height / RemoteHeight;
                            if (x < 0 || y < 0 || x >= ViewWidth || y >= ViewHeight) continue; // Off the view (100% of a larger desktop).
                            var (px, py) = geometry.RemotePoint(x, y);
                            if ((px, py) != (rx, ry))
                                failures.Add($"scale {scale} {mode} {(device ? "device" : "logical")}: ({rx},{ry}) -> ({px},{py})");
                        }
                }
        Assert.AreEqual(0, failures.Count, string.Join(Environment.NewLine, failures.Take(20)));
    }

    private sealed class AbortComparison : Exception;
}
