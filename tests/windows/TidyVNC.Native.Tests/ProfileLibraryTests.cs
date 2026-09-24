// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Saved profiles (plans/native-ui-winui TODO W5.10, PARITY P07, P08, C10;
/// macOS NativeProfileLibraryTests): profile settings inherit the app
/// defaults, a profile saves only with a name, a valid address and a usable
/// gateway, edits block selection until saved or cancelled, and a stale
/// revision is a conflict rather than an overwrite.
/// </summary>
[TestClass]
public sealed class ProfileLibraryTests
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

    [TestMethod]
    public async Task ProfilesSaveInheritAndRefuseStaleRevisions()
    {
        using var ui = new SingleThreadDispatcher();
        var root = Path.Combine(Path.GetTempPath(), "tidyvnc-profiles-" + Guid.NewGuid().ToString("N"), "state");
        try
        {
            await ui.InvokeAsync(async () =>
            {
                using var store = new NativeProfileHistoryStore(root);
                using var other = new NativeProfileHistoryStore(root);
                using var preferences = new NativePreferencesStore(root);
                var saved = await preferences.ReadAsync();
                await preferences.CommitAsync(saved.Value with { Settings = NativeSettings.Create([new("Shared", "on")]) }, saved.Revision);

                var library = new NativeProfileLibrary(store, preferences);
                library.Reload();
                await Until(() => !library.IsBusy, "read");
                Assert.IsTrue(library.HasLoaded);
                Assert.AreEqual(0, library.Profiles.Length);
                Assert.AreEqual(("on", NativeOptionSource.AppDefaults), library.Inherited("Shared"), "profiles inherit the app defaults");
                Assert.AreEqual((NativePreferencesDraft.BuiltIn["ScalingFactor"], NativeOptionSource.Compiled), library.Inherited("ScalingFactor"));

                library.NewProfile();
                Assert.IsNotNull(library.Draft);
                Assert.IsFalse(library.CanSave, "a name and an address are needed");
                library.SetName("  Lab  ");
                library.SetEndpoint("[::1");
                Assert.IsNotNull(library.EndpointIssue);
                Assert.IsFalse(library.CanSave);
                library.SetEndpoint("127.0.0.1::5901");
                library.GatewayText = "ssh://";
                Assert.IsNotNull(library.GatewayIssue);
                library.GatewayText = "user@gateway.example";
                Assert.IsNull(library.GatewayIssue);
                Assert.IsTrue(library.Set("Shared", "off"));
                Assert.AreEqual(NativeOptionSource.Profile, library.Source("Shared"));
                Assert.IsTrue(library.CanSave);
                Assert.IsFalse(library.CanUse, "unsaved edits cannot be opened");
                library.Save();
                await Until(() => !library.IsBusy, "save");
                Assert.IsNull(library.Error);
                var profile = library.Profiles.Single();
                Assert.AreEqual(("Lab", "127.0.0.1::5901", "off"), (profile.Name, profile.Endpoint, profile.Settings.Parameters["Shared"]), "the name is trimmed");
                Assert.AreEqual("ssh://user@gateway.example", profile.SshGateway?.CanonicalUri);
                Assert.IsTrue(library.CanUse);
                Assert.IsFalse(library.HasChanges);

                // A Unix socket cannot go through a gateway.
                library.SetEndpoint("/tmp/vnc.sock");
                Assert.IsNotNull(library.GatewayIssue);
                library.CancelEdits();
                Assert.AreEqual("127.0.0.1::5901", library.Draft!.Endpoint);

                // Another writer's change makes the next save a conflict.
                var current = await other.ReadAsync();
                await other.RecordRecentAsync(new NativeConnectionDestination("host:1", null), current.Revision);
                library.SetName("Lab 2");
                library.Save();
                await Until(() => !library.IsBusy, "conflict");
                Assert.AreEqual((NativeStorageError.Conflict, true), (library.Error, library.NeedsReload));
                Assert.AreEqual("Lab", (await other.ReadAsync()).Value.Profiles.Single().Name);
                library.Reload();
                await Until(() => !library.IsBusy, "reload");
                Assert.AreEqual(("Lab", false), (library.Draft!.Name, library.NeedsReload), "the selection survives the reload");

                library.DeleteSelected();
                await Until(() => !library.IsBusy, "delete");
                Assert.AreEqual(0, library.Profiles.Length);
                Assert.AreEqual(1, (await other.ReadAsync()).Value.RecentConnections.Length, "history is kept");
                await library.CloseAsync();
                return 0;
            });
        }
        finally
        {
            try { Directory.Delete(Path.GetDirectoryName(root)!, true); } catch (IOException) { }
        }
    }
}
