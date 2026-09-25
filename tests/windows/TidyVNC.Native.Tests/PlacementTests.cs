// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Immutable;
using TidyVNC.Native.Platform;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Window placement (plans/native-ui-winui TODO W5.8, PARITY D01 and D12;
/// DESKTOP.md section 8): -geometry and Maximize land on the right display at
/// its scale and within its work area, and saved placements return only onto
/// displays that still exist.
/// </summary>
[TestClass]
public sealed class PlacementTests
{
    private static NativeDisplayInfo Display(string id, double x, double y, double width, double height, double scale = 1, bool primary = false) =>
        new(id, "Display " + id, new NativeDisplayRectangle(x, y, width, height), new NativeDisplayRectangle(x, y, width, height - 48), scale,
            primary, false, 0);

    private static readonly NativeDisplaySnapshot Displays = new(1,
        [Display("A", 0, 0, 1920, 1080, 1.5, primary: true), Display("B", 1920, 0, 2560, 1440)], null);

    [TestMethod]
    public void StartupGeometryUsesTheTargetDisplay()
    {
        Assert.AreEqual((150, 75), NativeWindowPlacements.Position(NativeWindowGeometry.Parse("+100+50"), Displays), "positions use the primary display's scale");
        Assert.IsNull(NativeWindowPlacements.Position(NativeWindowGeometry.Parse("800x600"), Displays));
        Assert.AreEqual("B", NativeWindowPlacements.Target(Displays, (1920, 0), null)!.Id, "a boundary belongs to the display on the right");
        Assert.AreEqual("B", NativeWindowPlacements.Target(Displays, null, "B")!.Id);
        Assert.AreEqual("A", NativeWindowPlacements.Target(Displays, (-500, -500), "gone")!.Id, "otherwise the primary");

        var frame = new NativeWindowFrame(100, 100, 1014, 807);
        var borders = new NativeInsets(7, 0, 7, 7);
        var b = Displays.Find("B")!;
        var a = Displays.Find("A")!;
        var policy = new NativeWindowStartupPolicy(NativeWindowGeometry.Parse("800x600+2000+100"));
        Assert.AreEqual(new NativeWindowFrame(1993, 100, 814, 607), NativeWindowPlacements.Startup(policy, frame, borders, b, (640, 420), (2000, 100)));
        var scaled = new NativeWindowStartupPolicy(NativeWindowGeometry.Parse("800x600"));
        Assert.AreEqual(new NativeWindowFrame(100, 100, 1214, 907), NativeWindowPlacements.Startup(scaled, frame, borders, a, (960, 630), null),
            "a size is effective pixels on the target display; the client's top-left stays");
        var huge = new NativeWindowStartupPolicy(NativeWindowGeometry.Parse("5000x5000"));
        Assert.AreEqual(new NativeWindowFrame(100, 100, 1920, 1032), NativeWindowPlacements.Startup(huge, frame, borders, a, (960, 630), null), "clamped to the work area");
        var tiny = new NativeWindowStartupPolicy(NativeWindowGeometry.Parse("10x10"));
        Assert.AreEqual(new NativeWindowFrame(100, 100, 974, 637), NativeWindowPlacements.Startup(tiny, frame, borders, a, (960, 630), null), "and to the minimum");
        var maximize = new NativeWindowStartupPolicy(Maximize: true);
        Assert.IsTrue(maximize.HasPlacement);
        Assert.AreEqual(frame, NativeWindowPlacements.Startup(maximize, frame, borders, a, (960, 630), null), "Maximize keeps the restored frame");
    }

    [TestMethod]
    public void SavedPlacementsReturnOnlyToDisplaysThatExist()
    {
        Assert.IsNull(NativeWindowPlacements.Restore(new NativeWindowPlacement(10, 10, 800, 600, false, "gone"), Displays, (640, 420)));
        Assert.IsNull(NativeWindowPlacements.Restore(new NativeWindowPlacement(10, 10, 800, 600, false, null), Displays, (640, 420)));
        Assert.IsNull(NativeWindowPlacements.Restore(new NativeWindowPlacement(10, 10, 800, 600, false, "A"), Displays with { Error = NativeDisplayError.Unavailable }, (640, 420)));
        Assert.AreEqual(new NativeWindowFrame(2000, 40, 800, 600),
            NativeWindowPlacements.Restore(new NativeWindowPlacement(2000, 40, 800, 600, true, "B"), Displays, (640, 420)));
        Assert.AreEqual(new NativeWindowFrame(3680, 792, 800, 600),
            NativeWindowPlacements.Restore(new NativeWindowPlacement(4000, 1000, 800, 600, false, "B"), Displays, (640, 420)), "moved into the work area");
        Assert.AreEqual(new NativeWindowFrame(0, 0, 1920, 1032),
            NativeWindowPlacements.Restore(new NativeWindowPlacement(-50, -50, 3000, 3000, false, "A"), Displays, (640, 420)), "shrunk to the work area");

        var placement = NativeWindowPlacements.Capture(new NativeWindowFrame(1800, 100, 800, 600), true, Displays);
        Assert.AreEqual(new NativeWindowPlacement(1800, 100, 800, 600, true, "B"), placement, "the display holding most of the window");
        Assert.IsNull(NativeWindowPlacements.Capture(new NativeWindowFrame(-5000, 0, 10, 10), false, Displays).Display);
    }

    [TestMethod]
    public async Task PlacementMemorySavesAndNeverOverwritesAnUnreadableRecord()
    {
        var root = Path.Combine(Path.GetTempPath(), "tidyvnc-placement-" + Guid.NewGuid().ToString("N"), "state");
        try
        {
            using (var store = new NativeWindowStateStore(root))
            {
                var memory = await NativeWindowPlacementMemory.LoadAsync(store);
                Assert.IsNull(memory.Get("connection"));
                var saved = new NativeWindowPlacement(10, 20, 800, 600, false, "A");
                memory.Remember("connection", saved);
                memory.Remember("connection", saved with { Maximized = true });
                await memory.FlushAsync();
                Assert.AreEqual(saved with { Maximized = true }, (await store.ReadAsync()).Value.Windows["connection"]);

                // Another process's entry survives this process's save.
                var current = await store.ReadAsync();
                await store.CommitAsync(current.Value with { Windows = current.Value.Windows.SetItem("listener", saved) }, current.Revision);
                memory.Remember("connection", saved);
                await memory.FlushAsync();
                var both = (await store.ReadAsync()).Value;
                CollectionAssert.AreEqual(new[] { "connection", "listener" }, both.Windows.Keys.ToArray());

                // The status bar choice merges the same way and keeps the placements.
                Assert.IsTrue(memory.StatusBarVisible, "shown by default");
                memory.StatusBarVisible = false;
                await memory.FlushAsync();
                var hidden = (await store.ReadAsync()).Value;
                Assert.IsTrue(hidden.StatusBarHidden);
                CollectionAssert.AreEqual(new[] { "connection", "listener" }, hidden.Windows.Keys.ToArray());
                using var other = new NativeWindowStateStore(root);
                Assert.IsFalse((await NativeWindowPlacementMemory.LoadAsync(other)).StatusBarVisible, "read back at the next start");
            }

            File.WriteAllText(Path.Combine(root, "window-state.json"), "{\"schema\":1,\"revision\":\"x\"}");
            using (var store = new NativeWindowStateStore(root))
            {
                var memory = await NativeWindowPlacementMemory.LoadAsync(store);
                memory.Remember("connection", new NativeWindowPlacement(0, 0, 640, 480, false, "A"));
                await memory.FlushAsync();
                Assert.AreEqual("{\"schema\":1,\"revision\":\"x\"}", File.ReadAllText(Path.Combine(root, "window-state.json")), "a corrupt record is left alone");
            }
        }
        finally
        {
            try { Directory.Delete(Path.GetDirectoryName(root)!, true); } catch (IOException) { }
        }
    }
}
