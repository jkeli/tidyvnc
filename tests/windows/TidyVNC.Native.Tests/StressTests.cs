// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;

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
}
