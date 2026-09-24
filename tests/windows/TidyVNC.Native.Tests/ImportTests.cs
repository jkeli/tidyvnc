// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using Microsoft.Win32;
using TidyVNC.Native.Platform;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Importing defaults and recent connections from the FLTK viewer's registry
/// (plans/native-ui-winui TODO W5.13, PARITY F09-F14; macOS
/// NativeDefaultsImportStateTests): the review shows exactly what will be
/// written, omissions need acknowledging, monitor numbers become display IDs,
/// the record is marked as imported, history imports only once, and the
/// registry is never written. Disposable keys under HKCU\Software\TidyVNC-test-*.
/// </summary>
[TestClass]
public sealed class ImportTests
{
    private string path = "";
    private RegistryKey root = null!;
    private string state = "";

    [TestInitialize]
    public void Setup()
    {
        path = @"Software\TidyVNC-test-" + Guid.NewGuid().ToString("N");
        root = Registry.CurrentUser.CreateSubKey(path, writable: true);
        state = Path.Combine(Path.GetTempPath(), "tidyvnc-import-" + Guid.NewGuid().ToString("N"), "state");
    }

    [TestCleanup]
    public void Teardown()
    {
        root.Dispose();
        Registry.CurrentUser.DeleteSubKeyTree(path, throwOnMissingSubKey: false);
        try { Directory.Delete(Path.GetDirectoryName(state)!, true); } catch (IOException) { }
    }

    private RegistryKey Viewer(string vendor) => root.CreateSubKey($@"Software\{vendor}\vncviewer", writable: true);

    private static async Task Until(Func<bool> condition, string label)
    {
        var clock = Stopwatch.StartNew();
        while (!condition())
        {
            if (clock.Elapsed > TimeSpan.FromSeconds(10)) Assert.Fail($"Timed out: {label}");
            await Task.Delay(2);
        }
    }

    private static NativeDisplaySnapshot Displays() => new(1,
    [
        new("bbbbbbbbbbbbbbbb", "Right", new(1920, 0, 1920, 1080), new(1920, 0, 1920, 1040), 1, false, false, 1),
        new("aaaaaaaaaaaaaaaa", "Left", new(0, 0, 1920, 1080), new(0, 0, 1920, 1040), 1, true, false, 2),
    ], null);

    [TestMethod]
    public async Task DefaultsAreReviewedAcknowledgedAndMarked()
    {
        using (var key = Viewer("TigerVNC"))
        {
            key.SetValue("Shared", 1, RegistryValueKind.DWord);
            key.SetValue("QualityLevel", 7, RegistryValueKind.DWord);
            key.SetValue("PasswordFile", @"C:\\secret\\passwd", RegistryValueKind.String);
            key.SetValue("FullScreenSelectedMonitors", "2,3", RegistryValueKind.String);
        }
        var before = Viewer("TigerVNC").GetValueNames().Order().ToArray();
        using var ui = new SingleThreadDispatcher();
        await ui.InvokeAsync(async () =>
        {
            using var store = new NativePreferencesStore(state);
            var import = new NativeDefaultsImport(store, Displays, root);
            Assert.AreEqual(NativeRegistrySource.TigerVnc, import.Sources.Single().Source);
            import.Begin(NativeRegistrySource.TigerVnc);
            await Until(() => !import.IsBusy, "the review");
            var review = import.Review!;
            Assert.AreEqual(("on", "7"), (review.Settings.Parameters["Shared"], review.Settings.Parameters["QualityLevel"]));
            Assert.IsTrue(review.Notices.Any(n => n.Name == "PasswordFile"), "excluded values are listed");
            // Monitor 2 is the right-hand display in the retained numbering; monitor 3 does not exist.
            CollectionAssert.AreEqual(new[] { new NativeImportedMonitor(2, "bbbbbbbbbbbbbbbb"), new NativeImportedMonitor(3, null) }, review.Monitors.ToArray());
            CollectionAssert.AreEqual(new[] { "bbbbbbbbbbbbbbbb" }, review.Settings.FullscreenDisplays.ToArray());
            Assert.IsFalse(review.ReplacesExisting);

            import.Approve(review.Id, acknowledged: false);
            Assert.AreEqual(NativeImportIssue.AcknowledgementRequired, import.Issue);
            Assert.IsFalse((await store.ReadAsync()).IsStored, "nothing written without the acknowledgement");
            import.Approve(review.Id, acknowledged: true);
            await Until(() => !import.IsBusy, "the write");
            Assert.IsTrue(import.Imported);
            var saved = (await store.ReadAsync()).Value;
            Assert.AreEqual((NativeImportOrigin.Registry, "on"), (saved.ImportedFrom, saved.Settings.Parameters["Shared"]));

            // A review read before another save is refused rather than replacing it.
            import.Begin(NativeRegistrySource.TigerVnc);
            await Until(() => !import.IsBusy, "a second review");
            Assert.IsTrue(import.Review!.ReplacesExisting);
            var current = await store.ReadAsync();
            await store.CommitAsync(current.Value with { Settings = NativeSettings.Create([new("ViewOnly", "on")]) }, current.Revision);
            import.Approve(import.Review.Id, acknowledged: true);
            await Until(() => !import.IsBusy, "the refused write");
            Assert.AreEqual(NativeImportIssue.Changed, import.Issue);
            Assert.AreEqual("on", (await store.ReadAsync()).Value.Settings.Parameters["ViewOnly"]);
            await import.CloseAsync();
            return 0;
        });
        CollectionAssert.AreEqual(before, Viewer("TigerVNC").GetValueNames().Order().ToArray(), "the registry is never written");
    }

    [TestMethod]
    public async Task HistoryImportsOnceOrIsSkipped()
    {
        using (var key = Viewer("TidyVNC"))
        using (var history = key.CreateSubKey("history"))
        {
            history.SetValue("0", "newest.example", RegistryValueKind.String);
            history.SetValue("1", "older.example::5902", RegistryValueKind.String);
        }
        using var ui = new SingleThreadDispatcher();
        await ui.InvokeAsync(async () =>
        {
            using var store = new NativeProfileHistoryStore(state);
            var import = new NativeHistoryImport(store, root);
            Assert.AreEqual(NativeRegistrySource.TidyVnc, import.Sources.Single().Source);
            import.Begin(NativeRegistrySource.TidyVnc);
            await Until(() => !import.IsBusy, "the review");
            CollectionAssert.AreEqual(new[] { "newest.example", "older.example::5902" }, import.Review!.Endpoints.ToArray());
            import.Complete(import.Review.Id, import: true);
            await Until(() => !import.IsBusy, "the import");
            Assert.IsTrue(import.Finished);
            var saved = (await store.ReadAsync()).Value;
            Assert.AreEqual(NativeHistoryState.Registry, saved.HistoryState);
            CollectionAssert.AreEqual(new[] { "newest.example", "older.example::5902" }, saved.RecentConnections.Select(d => d.Endpoint).ToArray());

            // Once native history exists, the import is not offered again.
            var again = new NativeHistoryImport(store, root);
            again.Begin(NativeRegistrySource.TidyVnc);
            await Until(() => !again.IsBusy, "the refusal");
            Assert.AreEqual(NativeImportIssue.Changed, again.Issue);
            await import.CloseAsync();
            await again.CloseAsync();
            return 0;
        });

        // Skipping starts empty native history.
        Directory.Delete(Path.GetDirectoryName(state)!, true);
        await ui.InvokeAsync(async () =>
        {
            using var store = new NativeProfileHistoryStore(state);
            var import = new NativeHistoryImport(store, root);
            import.Begin(NativeRegistrySource.TidyVnc);
            await Until(() => !import.IsBusy, "the review");
            import.Complete(import.Review!.Id, import: false);
            await Until(() => !import.IsBusy, "the skip");
            var saved = (await store.ReadAsync()).Value;
            Assert.AreEqual((NativeHistoryState.Native, 0), (saved.HistoryState, saved.RecentConnections.Length));
            await import.CloseAsync();
            return 0;
        });
    }
}
