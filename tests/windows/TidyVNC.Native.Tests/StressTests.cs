// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native.Desktop;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Long reconnect, resize and attach cycles without leaks (plans/native-ui-winui
/// TODO W6.11). Each cycle connects to a fresh loopback server, receives frames,
/// takes a server-side resize and a burst of updates, disconnects, and
/// reconnects the same session; every fifth cycle closes the session and
/// attaches a new one. After warm-up, handles, threads and memory must stay
/// bounded. TIDYVNC_STRESS_CYCLES raises the cycle count for a soak run.
/// </summary>
[TestClass]
public sealed class StressTests
{
    public TestContext TestContext { get; set; } = null!;

    private static async Task Until(Func<bool> condition, string what, int seconds = 15)
    {
        var deadline = Stopwatch.StartNew();
        while (!condition())
        {
            if (deadline.Elapsed > TimeSpan.FromSeconds(seconds)) Assert.Fail($"Timed out: {what}");
            await Task.Delay(5);
        }
    }

    private readonly record struct Usage(int Handles, int Threads, long Managed, long Private);

    private static Usage Measure()
    {
        for (var i = 0; i < 3; i++)
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
        }
        using var process = Process.GetCurrentProcess();
        return new Usage(process.HandleCount, process.Threads.Count, GC.GetTotalMemory(true), process.PrivateMemorySize64);
    }

    [TestMethod]
    [Timeout(600_000)]
    public async Task ReconnectResizeAndAttachCyclesDoNotLeak()
    {
        var cycles = int.TryParse(Environment.GetEnvironmentVariable("TIDYVNC_STRESS_CYCLES"), out var requested) && requested > 20 ? requested : 60;
        const int warmUp = 15;
        using var ui = new SingleThreadDispatcher();
        Usage? baseline = null;
        var result = await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1], PointerEventIntervalMilliseconds = 0 });
            try
            {
                for (var cycle = 0; cycle < cycles; cycle++)
                {
                    await using (var peer = new LoopbackPeer(width: 64, height: 48))
                    {
                        await session.ConnectAsync(peer.Endpoint);
                        await Until(() => peer.Established && session.Snapshot.State == NativeSessionState.Connected && session.HasFrame,
                                    $"cycle {cycle} connected");
                        var frames = session.Snapshot.Frames;
                        // A server-side resize (ExtendedDesktopSize, reason 0) and a burst of updates.
                        var size = (ushort)(48 + cycle % 5 * 4);
                        await peer.LayoutAsync(0, 0, 64, size, LoopbackPeer.Screen(1, 0, 0, 64, size));
                        await peer.FloodAsync(5);
                        await Until(() => session.Snapshot.Height == size && session.Snapshot.Frames > frames, $"cycle {cycle} resized");
                        session.SetFocused(true);
                        session.SendPointer(1, 1, 1);
                        session.SendPointer(1, 1, 0);
                        await session.DisconnectAsync();
                        await Until(() => session.Snapshot.State is NativeSessionState.Closed or NativeSessionState.Failed, $"cycle {cycle} closed");
                    }
                    if (cycle % 5 == 4)
                    {
                        // Attach cycle: a closed session is replaced by a new one.
                        await session.CloseAsync();
                        session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1], PointerEventIntervalMilliseconds = 0 });
                    }
                    if (cycle == warmUp - 1) baseline = Measure();
                    if (cycles > 200 && cycle % 250 == 249)
                    {
                        var sample = Measure();
                        Console.WriteLine($"cycle {cycle + 1}: handles {sample.Handles}, threads {sample.Threads}, managed {sample.Managed / 1024} KiB, " +
                                          $"private {sample.Private / 1048576} MiB");
                    }
                }
                return Measure();
            }
            finally
            {
                await session.CloseAsync();
                await runtime.ShutdownAsync();
            }
        });
        var before = baseline!.Value;
        TestContext.WriteLine($"{cycles} cycles: handles {before.Handles} -> {result.Handles}, threads {before.Threads} -> {result.Threads}, " +
                              $"managed {before.Managed / 1024} KiB -> {result.Managed / 1024} KiB, private {before.Private / 1048576} MiB -> {result.Private / 1048576} MiB");
        // A leak grows with every cycle; the thread pool adding a few workers (with their handles) and the
        // native heap settling are one-off steps. Growth passes if it stays within a fixed allowance or
        // within a small per-cycle rate (a 4000-cycle soak showed one +8 thread step and a plateau).
        var measured = cycles - warmUp;
        bool Bounded(long growth, long allowance, double perCycle) => growth <= allowance || growth <= perCycle * measured;
        Assert.IsTrue(Bounded(result.Handles - before.Handles, 40, 0.25), $"handles grew {before.Handles} -> {result.Handles}");
        Assert.IsTrue(result.Threads - before.Threads <= 16, $"threads grew {before.Threads} -> {result.Threads}");
        Assert.IsTrue(Bounded(result.Managed - before.Managed, 8L << 20, 2048), $"managed memory grew {before.Managed} -> {result.Managed}");
        Assert.IsTrue(Bounded(result.Private - before.Private, 64L << 20, 16384), $"private bytes grew {before.Private} -> {result.Private}");
    }

    /// <summary>
    /// The presenter side of attach cycles: a desktop view detaching and reattaching, or moving to a
    /// full-screen surface on another display, is a new DesktopRenderer (Direct3D device, composition swap
    /// chain and render thread) attached to the same session at a new size and scale, then disposed. Every
    /// fourth cycle also loses and recreates its device. Handles, threads and memory must stay bounded.
    /// </summary>
    [TestMethod]
    [Timeout(600_000)]
    public async Task PresenterAttachCyclesDoNotLeak()
    {
        var cycles = int.TryParse(Environment.GetEnvironmentVariable("TIDYVNC_STRESS_CYCLES"), out var requested) && requested > 20 ? requested : 60;
        const int warmUp = 10;
        (uint Width, uint Height, double Scale)[] surfaces = [(320, 200, 1.0), (480, 300, 1.5), (640, 400, 2.0), (400, 250, 1.25)];
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer(width: 160, height: 100);
        Usage? baseline = null;
        (Usage result, long resets) = await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1] });
            var resets = 0L;
            try
            {
                await session.ConnectAsync(peer.Endpoint);
                await Until(() => session.HasFrame, "the first frame");
                for (var cycle = 0; cycle < cycles; cycle++)
                {
                    var (width, height, scale) = surfaces[cycle % surfaces.Length];
                    using (var renderer = new DesktopRenderer(ui, _ => { }))
                    {
                        Exception? failure = null;
                        renderer.Failed += error => failure = error;
                        session.FrameUpdated += renderer.Submit;
                        renderer.Resize(new DesktopViewport(width, height, width / scale, height / scale, scale));
                        renderer.Submit(session.Frame);
                        await Until(() => renderer.Statistics.Frames >= 1 && renderer.Presenter.Width == width, $"cycle {cycle} presented");
                        if (cycle % 4 == 3)
                        {
                            var presenter = renderer.Presenter;
                            renderer.SimulateDeviceLoss();
                            await Until(() => renderer.Statistics.DeviceResets == 1 && !ReferenceEquals(renderer.Presenter, presenter), $"cycle {cycle} recovered");
                            resets += renderer.Statistics.DeviceResets;
                        }
                        await peer.FloodAsync(2);
                        session.FrameUpdated -= renderer.Submit;
                        Assert.IsNull(failure, $"cycle {cycle}: {failure?.Message}");
                    }
                    if (cycle == warmUp - 1) baseline = Measure();
                }
                return (Measure(), resets);
            }
            finally
            {
                await session.CloseAsync();
                await runtime.ShutdownAsync();
            }
        });
        var before = baseline!.Value;
        TestContext.WriteLine($"{cycles} presenter cycles ({resets} device resets): handles {before.Handles} -> {result.Handles}, threads {before.Threads} -> {result.Threads}, " +
                              $"managed {before.Managed / 1024} KiB -> {result.Managed / 1024} KiB, private {before.Private / 1048576} MiB -> {result.Private / 1048576} MiB");
        var measured = cycles - warmUp;
        bool Bounded(long growth, long allowance, double perCycle) => growth <= allowance || growth <= perCycle * measured;
        Assert.IsTrue(Bounded(result.Handles - before.Handles, 40, 0.25), $"handles grew {before.Handles} -> {result.Handles}");
        Assert.IsTrue(result.Threads - before.Threads <= 16, $"threads grew {before.Threads} -> {result.Threads}");
        Assert.IsTrue(Bounded(result.Managed - before.Managed, 8L << 20, 2048), $"managed memory grew {before.Managed} -> {result.Managed}");
        Assert.IsTrue(Bounded(result.Private - before.Private, 64L << 20, 16384), $"private bytes grew {before.Private} -> {result.Private}");
    }
}
