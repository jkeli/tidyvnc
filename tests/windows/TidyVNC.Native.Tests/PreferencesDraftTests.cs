// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native.Tests;

/// <summary>
/// The Settings window's defaults draft (plans/native-ui-winui TODO W5.9,
/// PARITY P02-P05 and P09; macOS NativePreferencesDraftTests): edits are
/// canonical or refused, Apply commits against the revision it read, another
/// writer's save is a conflict that needs a reload, and unreadable records
/// are never overwritten.
/// </summary>
[TestClass]
public sealed class PreferencesDraftTests
{
    private static async Task Until(Func<bool> condition, string label)
    {
        var clock = Stopwatch.StartNew();
        while (!condition())
        {
            if (clock.Elapsed > TimeSpan.FromSeconds(10)) Assert.Fail($"Timed out: {label}");
            await Task.Delay(2);
        }
    }

    private static string NewRoot() => Path.Combine(Path.GetTempPath(), "tidyvnc-preferences-" + Guid.NewGuid().ToString("N"), "state");

    private static void Remove(string root)
    {
        try { Directory.Delete(Path.GetDirectoryName(root)!, true); }
        catch (IOException) { }
    }

    [TestMethod]
    public void BuiltInDefaultsCoverEveryStoredSetting()
    {
        var builtIn = NativePreferencesDraft.BuiltIn;
        CollectionAssert.IsSubsetOf(new[] { "Shared", "SendClipboard", "AcceptClipboard", "ScalingFactor", "ViewOnly", "SecurityTypes" }, builtIn.Keys.ToArray());
        Assert.AreEqual(NativeScaling.BuiltIn.Canonical, builtIn["ScalingFactor"]);
        CollectionAssert.AreEquivalent(NativeSettings.Allowed.ToArray(), builtIn.Keys.ToArray(), "every stored setting has a built-in value");
        // Each built-in value is the core's own canonical text.
        foreach (var (name, value) in builtIn.Where(p => p.Value.Length != 0))
            Assert.AreEqual(value, NativeSettings.Create([new(name, value)]).Parameters[name], name);
    }

    [TestMethod]
    public async Task EditsApplyAgainstTheRevisionTheyRead()
    {
        using var ui = new SingleThreadDispatcher();
        var root = NewRoot();
        try
        {
            await ui.InvokeAsync(async () =>
            {
                using var store = new NativePreferencesStore(root);
                using var other = new NativePreferencesStore(root);
                var draft = new NativePreferencesDraft(store);
                Assert.IsFalse(draft.Set("Shared", "on"), "nothing to edit before a read");
                draft.Reload();
                await Until(() => !draft.IsBusy, "read");
                Assert.IsNotNull(draft.Snapshot);
                Assert.IsNull(draft.Get("Shared"));
                Assert.AreEqual(NativePreferencesDraft.BuiltIn["Shared"], draft.Effective("Shared"));

                Assert.IsTrue(draft.Set("ScalingFactor", "50%"));
                Assert.AreEqual("50", draft.Get("ScalingFactor"), "values are canonical");
                Assert.IsFalse(draft.Set("ScalingFactor", "fifty"));
                Assert.AreEqual(NativePreferencesProblem.InvalidValue, draft.Problem);
                Assert.AreEqual("50", draft.Get("ScalingFactor"), "a refused value changes nothing");
                Assert.IsTrue(draft.Set(("Shared", "on"), ("ViewOnly", "on")));
                Assert.IsTrue(draft.SetFullscreenDisplays(["00000000000000bb", "00000000000000aa"]));
                Assert.IsFalse(draft.SetFullscreenDisplays(["not-an-id"]));
                Assert.IsTrue(draft.HasChanges && draft.CanApply);

                // Cancel returns to what was read; Restore is only a draft.
                draft.Cancel();
                Assert.IsFalse(draft.HasChanges);
                draft.Set(("Shared", "on"), ("ScalingFactor", "50"));
                draft.SetFullscreenDisplays(["00000000000000aa"]);
                draft.Apply();
                await Until(() => !draft.IsBusy, "apply");
                Assert.IsTrue(draft.DidApply);
                Assert.IsFalse(draft.HasChanges);
                var saved = (await other.ReadAsync()).Value.Settings;
                Assert.AreEqual(("on", "50"), (saved.Parameters["Shared"], saved.Parameters["ScalingFactor"]));
                CollectionAssert.AreEqual(new[] { "00000000000000aa" }, saved.FullscreenDisplays.ToArray());

                draft.RestoreBuiltInDefaults();
                Assert.AreEqual(0, draft.Values.Parameters.Count);
                Assert.IsTrue(draft.HasChanges, "restoring is a draft until Apply");
                draft.Cancel();

                // Another process saves meanwhile: Apply is a conflict and nothing is overwritten.
                var current = await other.ReadAsync();
                await other.CommitAsync(current.Value with { Settings = NativeSettings.Create([new("AcceptClipboard", "off")]) }, current.Revision);
                draft.Set("ViewOnly", "on");
                draft.Apply();
                await Until(() => !draft.IsBusy, "conflict");
                Assert.AreEqual((NativeStorageError.Conflict, true, false), (draft.Error, draft.NeedsReload, draft.CanEdit));
                Assert.IsFalse((await other.ReadAsync()).Value.Settings.Parameters.ContainsKey("ViewOnly"));
                draft.Reload();
                await Until(() => !draft.IsBusy, "reload");
                Assert.AreEqual(("off", false), (draft.Get("AcceptClipboard"), draft.NeedsReload));

                // The core's GnuTLS preflight refuses an invalid priority as it is entered.
                Assert.IsFalse(draft.Set("GnuTLSPriority", "NORMAL:+NOT-A-CIPHER"));
                Assert.AreEqual(NativePreferencesProblem.InvalidPriority, draft.Problem);
                Assert.IsTrue(draft.Set("GnuTLSPriority", "NORMAL"));
                Assert.IsNull(draft.Problem);
                await draft.CloseAsync();
                return 0;
            });

            // An unreadable record is reported and never replaced.
            File.WriteAllText(Path.Combine(root, "preferences.json"), "{\"schema\":1,\"revision\":\"x\"}");
            await ui.InvokeAsync(async () =>
            {
                using var store = new NativePreferencesStore(root);
                var draft = new NativePreferencesDraft(store);
                draft.Reload();
                await Until(() => !draft.IsBusy, "read");
                Assert.AreEqual((NativeStorageError.Corrupt, true, false), (draft.Error, draft.NeedsReload, draft.CanEdit));
                Assert.IsFalse(draft.Set("Shared", "on"));
                return 0;
            });
            Assert.AreEqual("{\"schema\":1,\"revision\":\"x\"}", File.ReadAllText(Path.Combine(root, "preferences.json")));
        }
        finally
        {
            Remove(root);
        }
    }
}
