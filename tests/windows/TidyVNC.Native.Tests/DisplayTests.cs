// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native.Platform;

namespace TidyVNC.Native.Tests;

/// <summary>
/// The display service (plans/native-ui-winui TODO W4.7, SERVICES.md
/// section 7): snapshot validation and generations, saved-choice resolution,
/// change notifications, and the real topology.
/// </summary>
[TestClass]
public sealed class DisplayTests
{
    private static async Task Until(Func<bool> condition, int seconds = 10)
    {
        var deadline = Stopwatch.StartNew();
        while (!condition())
        {
            if (deadline.Elapsed > TimeSpan.FromSeconds(seconds)) Assert.Fail("Condition not reached in time");
            await Task.Delay(5);
        }
    }

    private sealed class ScriptedSource : INativeDisplaySource
    {
        public IReadOnlyList<NativeDisplayInfo> Displays { get; set; } = [];
        public Exception? Failure { get; set; }
        public int Reads { get; private set; }

        public IReadOnlyList<NativeDisplayInfo> Read()
        {
            Reads++;
            return Failure is { } failure ? throw failure : Displays;
        }
    }

    private static NativeDisplayInfo Display(string id, double x, bool primary = false, double scale = 1.0, nint monitor = 1, string? name = null)
        => new(id, name ?? $"Monitor {id}", new(x, 0, 1920, 1080), new(x, 0, 1920, 1040), scale, primary, false, monitor);

    [TestMethod]
    public void SavedChoicesResolveWithoutRewritingThem()
    {
        var a = Display("aaaa", 0, primary: true);
        var b = Display("bbbb", 1920);
        var snapshot = new NativeDisplaySnapshot(3, [a, b], null);
        var both = snapshot.Resolve(["bbbb", "gone", "aaaa", "bbbb"]);
        CollectionAssert.AreEqual(new[] { b, a }, both.Displays.ToArray(), "requested order, duplicates once");
        CollectionAssert.AreEqual(new[] { "gone" }, both.Missing.ToArray());
        Assert.IsFalse(both.UsedFallback);
        var one = snapshot.Resolve(["gone", "bbbb"]);
        CollectionAssert.AreEqual(new[] { b }, one.Displays.ToArray(), "a single survivor is kept, not replaced by the primary");
        Assert.IsFalse(one.UsedFallback);
        var none = snapshot.Resolve(["gone"], current: "bbbb");
        CollectionAssert.AreEqual(new[] { b }, none.Displays.ToArray(), "fallback to the current display");
        Assert.IsTrue(none.UsedFallback);
        Assert.AreEqual(a, snapshot.Resolve(["gone"]).Displays.Single(), "then the primary");
        Assert.AreEqual(0, new NativeDisplaySnapshot(1, [], NativeDisplayError.Unavailable).Resolve(["aaaa"]).Displays.Length);
    }

    [TestMethod]
    public async Task GenerationsAdvanceOnlyForRealTopologyChanges()
    {
        using var ui = new SingleThreadDispatcher();
        await ui.InvokeAsync(() =>
        {
            var source = new ScriptedSource { Displays = [Display("bbbb", 1920), Display("aaaa", 0, primary: true)] };
            using var service = new NativeDisplayService(ui, source);
            var first = service.Snapshot;
            Assert.AreEqual(1ul, first.Generation);
            CollectionAssert.AreEqual(new[] { "aaaa", "bbbb" }, first.Displays.Select(d => d.Id).ToArray(), "stable order");

            source.Displays = [Display("aaaa", 0, primary: true), Display("bbbb", 1920)];
            service.Refresh();
            Assert.AreEqual(1ul, service.Snapshot.Generation, "order alone is not a change");
            source.Displays = [Display("aaaa", 0, primary: true, monitor: 7), Display("bbbb", 1920, monitor: 8)];
            service.Refresh();
            Assert.AreEqual(1ul, service.Snapshot.Generation, "new monitor handles alone are not a change");
            Assert.AreEqual((nint)7, service.Snapshot.Find("aaaa")!.Monitor, "but the handles are current");

            source.Displays = [Display("aaaa", 0, primary: true, scale: 1.5), Display("bbbb", 1920)];
            service.Refresh();
            Assert.AreEqual(2ul, service.Snapshot.Generation, "a scale change is a change");
            Assert.AreEqual(1280, service.Snapshot.Find("aaaa")!.LogicalBounds.Width);

            source.Failure = new NativeDisplayException(NativeDisplayError.Unavailable);
            service.Refresh();
            Assert.AreEqual(3ul, service.Snapshot.Generation);
            Assert.AreEqual(NativeDisplayError.Unavailable, service.Snapshot.Error);
            Assert.AreEqual(0, service.Snapshot.Displays.Length, "no stale geometry after a failure");
            service.Refresh();
            Assert.AreEqual(3ul, service.Snapshot.Generation, "a repeated failure is not a change");
            source.Failure = null;
            service.Refresh();
            Assert.AreEqual(4ul, service.Snapshot.Generation);
            Assert.IsNull(service.Snapshot.Error);
        });
    }

    [TestMethod]
    public async Task InvalidTopologiesAreRefusedWhole()
    {
        using var ui = new SingleThreadDispatcher();
        await ui.InvokeAsync(() =>
        {
            var source = new ScriptedSource();
            using var service = new NativeDisplayService(ui, source);
            void Expect(NativeDisplayError error, params NativeDisplayInfo[] displays)
            {
                source.Displays = displays;
                service.Refresh();
                Assert.AreEqual(error, service.Snapshot.Error);
                Assert.AreEqual(0, service.Snapshot.Displays.Length);
            }
            Expect(NativeDisplayError.InvalidSnapshot, Display("aaaa", 0, primary: true), Display("aaaa", 1920));
            Expect(NativeDisplayError.InvalidSnapshot, Display("aaaa", 0, primary: true), Display("bbbb", 1920, primary: true));
            Expect(NativeDisplayError.InvalidSnapshot, Display("aaaa", 0));
            Expect(NativeDisplayError.InvalidSnapshot, Display("aaaa", 0, primary: true, scale: 0));
            Expect(NativeDisplayError.InvalidSnapshot, Display("aaaa", 0, primary: true, name: ""));
            Expect(NativeDisplayError.InvalidSnapshot, Display("aaaa", 0, primary: true) with { WorkArea = new(0, 0, 2000, 1000) });
            Expect(NativeDisplayError.TooManyDisplays, [.. Enumerable.Range(0, 65).Select(n => Display($"{n:x4}", n * 1920, primary: n == 0))]);
        });
    }

    [TestMethod]
    public async Task ChangeNotificationsRefreshOnTheUiThread()
    {
        using var ui = new SingleThreadDispatcher();
        using var listener = new NativeDisplayChangeListener();
        var source = new ScriptedSource { Displays = [Display("aaaa", 0, primary: true)] };
        var service = await ui.InvokeAsync(() => new NativeDisplayService(ui, source, listener));
        foreach (var (message, wParam) in new (uint, nuint)[] { (0x007E, 32), (0x001A, 47), (0x02E0, 0), (0x0218, 0x8013) })
        {
            var reads = source.Reads;
            source.Displays = [Display("aaaa", 0, primary: true, scale: 1 + reads / 4.0)];
            listener.Deliver(message, wParam);
            await Until(() => source.Reads > reads);
            await Until(() => ui.InvokeAsync(() => service.Snapshot.Displays[0].Scale).Result == 1 + reads / 4.0);
        }
        var before = source.Reads;
        listener.Deliver(0x0218, 0x000A); // PBT_APMRESUMESUSPEND is not a topology message.
        await Task.Delay(100);
        Assert.AreEqual(before, source.Reads);
        await ui.InvokeAsync(service.Dispose);
    }

    [TestMethod]
    public async Task TheRealTopologyIsValidOrTypedUnavailable()
    {
        using var ui = new SingleThreadDispatcher();
        var snapshot = await ui.InvokeAsync(() =>
        {
            using var service = new NativeDisplayService(ui);
            return service.Snapshot;
        });
        Assert.AreEqual(1ul, snapshot.Generation);
        if (snapshot.Error is { } error)
        {
            // Every display powered off (QueryDisplayConfig fails): typed, empty, never stale.
            Assert.AreEqual(NativeDisplayError.Unavailable, error);
            Assert.AreEqual(0, snapshot.Displays.Length);
            return;
        }
        Assert.IsTrue(snapshot.Displays.Length > 0);
        Assert.AreEqual(1, snapshot.Displays.Count(d => d.IsPrimary));
        foreach (var display in snapshot.Displays)
        {
            Assert.AreEqual(16, display.Id.Length);
            Assert.IsTrue(display.Id.All(char.IsAsciiHexDigitLower));
            Assert.IsFalse(string.IsNullOrWhiteSpace(display.Name));
        }
    }
}
