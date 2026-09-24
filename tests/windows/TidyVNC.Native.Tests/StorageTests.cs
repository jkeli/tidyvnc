// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Store contract (plans/native-ui-winui TODO W4.1, SERVICES.md section 2):
/// round trips, revisions and conflicts, strict decoding, explicit recovery,
/// future schemas, owner-only DACLs, reparse refusal, the cross-handle writer
/// lock and crash leftovers. Every test works in its own temporary root.
/// </summary>
[TestClass]
public sealed class StorageTests
{
    private string root = "";
    private string State => Path.Combine(root, "state");

    [TestInitialize]
    public void Setup()
    {
        root = Path.Combine(Path.GetTempPath(), "tidyvnc-storage-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
    }

    [TestCleanup]
    public void Teardown()
    {
        foreach (var junction in Directory.EnumerateDirectories(root))
            if ((File.GetAttributes(junction) & FileAttributes.ReparsePoint) != 0) Directory.Delete(junction);
        Directory.Delete(root, recursive: true);
    }

    private static async Task<NativeStorageError> Failure(Func<Task> body)
    {
        try { await body(); }
        catch (NativeStorageException error) { return error.Error; }
        Assert.Fail("Expected a storage failure");
        return default;
    }

    private static NativeSettings Sample() => NativeSettings.Create(
        [new("SendClipboard", "0"), new("ScalingFactor", "150"), new("FullScreenMode", "Selected"), new("SecurityTypes", "VncAuth,TLSVnc")],
        ["0123456789abcdef", "fedcba9876543210"]);

    private void WriteRaw(string name, string json)
    {
        NativePrivateFiles.EnsureDirectory(State);
        File.WriteAllText(Path.Combine(State, name), json);
    }

    [TestMethod]
    public async Task AbsentRecordsReadAsEmptyWithoutCreatingAnything()
    {
        using var store = new NativePreferencesStore(State);
        var snapshot = await store.ReadAsync();
        Assert.IsFalse(snapshot.IsStored);
        Assert.AreEqual(NativeSettings.Empty, snapshot.Value.Settings);
        Assert.IsFalse(Directory.Exists(State));
    }

    [TestMethod]
    public async Task PreferencesRoundTripWithFreshRevisionsAndConflicts()
    {
        using var store = new NativePreferencesStore(State);
        var value = new NativePreferencesRecord(Sample(), NativeImportOrigin.Registry);
        var first = await store.CommitAsync(value, null);
        Assert.IsTrue(first.IsStored);
        using (var other = new NativePreferencesStore(State))
        {
            var read = await other.ReadAsync();
            Assert.AreEqual(first.Revision, read.Revision);
            Assert.AreEqual(value, read.Value);
        }
        var second = await store.CommitAsync(value with { ImportedFrom = NativeImportOrigin.None }, first.Revision);
        Assert.AreNotEqual(first.Revision, second.Revision);
        Assert.AreEqual(NativeStorageError.Conflict, await Failure(() => store.CommitAsync(value, first.Revision)));
        Assert.AreEqual(NativeStorageError.Conflict, await Failure(() => store.CommitAsync(value, null)));
        Assert.AreEqual(second.Revision, (await store.ReadAsync()).Revision);
        // Private: the directory and record pass the owner/DACL check and the DACL is protected.
        NativePrivateFiles.CheckPrivate(new DirectoryInfo(State));
        NativePrivateFiles.CheckPrivate(new FileInfo(store.Path));
        Assert.IsTrue(new DirectoryInfo(State).GetAccessControl().AreAccessRulesProtected);
    }

    [TestMethod]
    public void SettingsAreCanonicalAndLimitedToTheAllowList()
    {
        var yes = NativeSettings.Create([new("SendClipboard", "yes")]);
        Assert.AreNotEqual("yes", yes.Parameters["SendClipboard"]);
        foreach (var name in new[] { "via", "Log", "PasswordFile", "listen", "MaxCutText" })
            Assert.ThrowsExactly<ArgumentException>(() => NativeSettings.Create([new(name, "1")]));
        Assert.ThrowsExactly<ArgumentException>(() => NativeSettings.Create([new("Shared", "1"), new("Shared", "0")]));
        Assert.ThrowsExactly<ArgumentException>(() => NativeSettings.Create([], ["NOT-HEX"]));
        Assert.ThrowsExactly<ArgumentException>(() => NativeSettings.Create([], ["ab", "ab"]));
        Assert.ThrowsExactly<NativeConfigFailure>(() => NativeSettings.Create([new("ScalingFactor", "nonsense")]));
    }

    [TestMethod]
    public async Task StrictDecodingSeparatesCorruptUnsupportedAndFuture()
    {
        using var store = new NativePreferencesStore(State);
        var cases = new (string Json, NativeStorageError Error)[]
        {
            ("{", NativeStorageError.Corrupt),
            ("[]", NativeStorageError.Corrupt),
            ("{\"revision\":\"" + Guid.NewGuid() + "\"}", NativeStorageError.Corrupt),
            ("{\"schema\":1,\"revision\":\"x\"}", NativeStorageError.Corrupt),
            ("{\"schema\":1,\"revision\":\"" + Guid.NewGuid() + "\",\"extra\":1}", NativeStorageError.UnsupportedFields),
            ("{\"schema\":1,\"revision\":\"" + Guid.NewGuid() + "\",\"settings\":{\"parameters\":{\"Log\":\"*:stderr:100\"}}}", NativeStorageError.UnsupportedFields),
            ("{\"schema\":1,\"revision\":\"" + Guid.NewGuid() + "\",\"settings\":{\"parameters\":{\"SendClipboard\":\"yes\"}}}", NativeStorageError.Corrupt),
            ("{\"schema\":1,\"revision\":\"" + Guid.NewGuid() + "\",\"settings\":{\"parameters\":{\"SendClipboard\":1}}}", NativeStorageError.Corrupt),
            ("{\"schema\":1,\"revision\":\"" + Guid.NewGuid() + "\",\"importedFrom\":\"plist\"}", NativeStorageError.Corrupt),
            ("{\"schema\":2,\"revision\":\"" + Guid.NewGuid() + "\",\"whatever\":[]}", NativeStorageError.FutureSchema),
        };
        foreach (var (json, error) in cases)
        {
            WriteRaw("preferences.json", json);
            Assert.AreEqual(error, await Failure(() => store.ReadAsync()), json);
            Assert.AreEqual(error, await Failure(() => store.CommitAsync(new(NativeSettings.Empty, NativeImportOrigin.None), null)), json);
            Assert.AreEqual(json, File.ReadAllText(store.Path), "a failed commit leaves the record alone");
        }
    }

    [TestMethod]
    public async Task RecoveryReplacesOnlyDamagedRecordsAndNeverAFutureSchema()
    {
        using var store = new NativePreferencesStore(State);
        var value = new NativePreferencesRecord(Sample(), NativeImportOrigin.None);
        WriteRaw("preferences.json", "{\"schema\":1,\"revision\":\"" + Guid.NewGuid() + "\",\"surprise\":true}");
        var recovered = await store.ReplaceCorruptAsync(value);
        Assert.AreEqual(value, (await store.ReadAsync()).Value);
        Assert.AreEqual(NativeStorageError.Conflict, await Failure(() => store.ReplaceCorruptAsync(value)));
        Assert.AreEqual(recovered.Revision, (await store.ReadAsync()).Revision);
        WriteRaw("preferences.json", "not json");
        await store.ReplaceCorruptAsync(value);
        var future = "{\"schema\":7,\"revision\":\"" + Guid.NewGuid() + "\"}";
        WriteRaw("preferences.json", future);
        Assert.AreEqual(NativeStorageError.FutureSchema, await Failure(() => store.ReplaceCorruptAsync(value)));
        Assert.AreEqual(future, File.ReadAllText(store.Path));
    }

    [TestMethod]
    public async Task OversizedRecordsAreTooLarge()
    {
        using var store = new NativePreferencesStore(State);
        WriteRaw("preferences.json", "{\"schema\":1,\"revision\":\"" + Guid.NewGuid() + "\",\"pad\":\"" + new string('x', 1024 * 1024) + "\"}");
        Assert.AreEqual(NativeStorageError.TooLarge, await Failure(() => store.ReadAsync()));
    }

    [TestMethod]
    public async Task ForeignAccessAndOwnershipAreDenied()
    {
        using var store = new NativePreferencesStore(State);
        await store.CommitAsync(new(Sample(), NativeImportOrigin.None), null);
        var file = new FileInfo(store.Path);
        var security = file.GetAccessControl();
        var everyone = new SecurityIdentifier(WellKnownSidType.WorldSid, null);
        security.AddAccessRule(new FileSystemAccessRule(everyone, FileSystemRights.Read, AccessControlType.Allow));
        file.SetAccessControl(security);
        Assert.AreEqual(NativeStorageError.Denied, await Failure(() => store.ReadAsync()));
        Assert.AreEqual(NativeStorageError.Denied, await Failure(() => store.CommitAsync(new(NativeSettings.Empty, NativeImportOrigin.None), null)));
        // A deny entry is not a grant: removing the allow and adding a deny is private again.
        security.RemoveAccessRule(new FileSystemAccessRule(everyone, FileSystemRights.Read, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(everyone, FileSystemRights.Write, AccessControlType.Deny));
        file.SetAccessControl(security);
        Assert.IsTrue((await store.ReadAsync()).IsStored);

        // An existing directory with an inherited, shared DACL is refused rather than adopted.
        var shared = Path.Combine(root, "shared");
        Directory.CreateDirectory(shared);
        var info = new DirectoryInfo(shared);
        var directorySecurity = info.GetAccessControl();
        directorySecurity.AddAccessRule(new FileSystemAccessRule(everyone, FileSystemRights.ReadAndExecute, AccessControlType.Allow));
        info.SetAccessControl(directorySecurity);
        using var sharedStore = new NativePreferencesStore(shared);
        Assert.AreEqual(NativeStorageError.Denied, await Failure(() => sharedStore.ReadAsync()));
        Assert.AreEqual(NativeStorageError.Denied, await Failure(() => sharedStore.CommitAsync(new(NativeSettings.Empty, NativeImportOrigin.None), null)));
        Assert.IsFalse(File.Exists(sharedStore.Path));
    }

    [TestMethod]
    public async Task ReparsePointsAreRefused()
    {
        using (var store = new NativePreferencesStore(State)) await store.CommitAsync(new(Sample(), NativeImportOrigin.None), null);
        var junction = Path.Combine(root, "junction");
        using (var process = Process.Start(new ProcessStartInfo("cmd.exe", ["/d", "/c", "mklink", "/J", junction, State])
               { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true })!)
        {
            await process.WaitForExitAsync();
            Assert.AreEqual(0, process.ExitCode);
        }
        // Give the junction itself an owner-only DACL so only the reparse check can refuse it.
        var link = new DirectoryInfo(junction);
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { WindowsIdentity.GetCurrent().User!, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
            security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow));
        link.SetAccessControl(security);
        using var redirected = new NativePreferencesStore(junction);
        Assert.AreEqual(NativeStorageError.Denied, await Failure(() => redirected.ReadAsync()));
        Assert.AreEqual(NativeStorageError.Denied, await Failure(() => redirected.CommitAsync(new(NativeSettings.Empty, NativeImportOrigin.None), null)));
        // A directory where the record should be is not a record.
        using var store2 = new NativeWindowStateStore(Path.Combine(root, "dir"));
        await store2.CommitAsync(System.Collections.Immutable.ImmutableSortedDictionary<string, NativeWindowPlacement>.Empty, null);
        Directory.CreateDirectory(Path.Combine(root, "dir", "preferences.json"));
        using var misplaced = new NativePreferencesStore(Path.Combine(root, "dir"));
        Assert.AreEqual(NativeStorageError.Denied, await Failure(() => misplaced.ReadAsync()));
    }

    [TestMethod]
    public async Task WritersSerializeAcrossHandlesAndLoseNoUpdates()
    {
        const int writers = 4, increments = 15;
        var stores = Enumerable.Range(0, writers).Select(_ => new NativeWindowStateStore(State)).ToArray();
        try
        {
            var conflicts = 0;
            await Task.WhenAll(stores.Select(store => Task.Run(async () =>
            {
                for (var i = 0; i < increments; ++i)
                {
                    while (true)
                    {
                        var current = await store.ReadAsync();
                        var count = current.Value.TryGetValue("main", out var placement) ? placement.X : 0;
                        try
                        {
                            await store.CommitAsync(current.Value.SetItem("main", new NativeWindowPlacement(count + 1, 0, 640, 480, false, null)), current.Revision);
                            break;
                        }
                        catch (NativeStorageException error) when (error.Error == NativeStorageError.Conflict)
                        {
                            Interlocked.Increment(ref conflicts);
                        }
                    }
                }
            })));
            Assert.AreEqual(writers * increments, (await stores[0].ReadAsync()).Value["main"].X);
            Assert.IsFalse(Directory.EnumerateFiles(State, "*.tidyvnc-tmp").Any());
        }
        finally
        {
            foreach (var store in stores) store.Dispose();
        }
    }

    [TestMethod]
    public async Task HeldLockTimesOutAsUnavailable()
    {
        using var store = new NativePreferencesStore(State);
        await store.CommitAsync(new(Sample(), NativeImportOrigin.None), null);
        using var holder = new FileStream(store.Path + ".lock", FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete);
        holder.Lock(0, 1);
        var error = Assert.ThrowsExactly<NativeStorageException>(() => NativePrivateFiles.WithWriterLock(store.Path, TimeSpan.FromMilliseconds(100), () => true));
        Assert.AreEqual(NativeStorageError.Unavailable, error.Error);
        holder.Unlock(0, 1);
        Assert.IsTrue(NativePrivateFiles.WithWriterLock(store.Path, TimeSpan.FromMilliseconds(100), () => true));
    }

    [TestMethod]
    public async Task SharingViolationsAreRetriedThenReported()
    {
        using var store = new NativePreferencesStore(State);
        var saved = await store.CommitAsync(new(Sample(), NativeImportOrigin.None), null);
        // An antivirus-style exclusive handle released shortly: reads and replaces ride it out.
        var scanner = new FileStream(store.Path, FileMode.Open, FileAccess.Read, FileShare.None);
        _ = Task.Delay(150).ContinueWith(_ => scanner.Dispose(), TaskScheduler.Default);
        Assert.AreEqual(saved.Revision, (await store.ReadAsync()).Revision);
        scanner = new FileStream(store.Path, FileMode.Open, FileAccess.Read, FileShare.None);
        _ = Task.Delay(150).ContinueWith(_ => scanner.Dispose(), TaskScheduler.Default);
        saved = await store.CommitAsync(new(NativeSettings.Empty, NativeImportOrigin.None), saved.Revision);
        Assert.AreEqual(saved.Revision, (await store.ReadAsync()).Revision);
        // A handle that is never released is a typed IO failure, not a hang.
        using (new FileStream(store.Path, FileMode.Open, FileAccess.Read, FileShare.None))
            Assert.AreEqual(NativeStorageError.IOFailure, await Failure(() => store.ReadAsync()));
    }

    [TestMethod]
    public async Task CrashLeftoversAreRemovedOnTheNextWrite()
    {
        using var store = new NativePreferencesStore(State);
        await store.CommitAsync(new(Sample(), NativeImportOrigin.None), null);
        var stale = store.Path + "." + Guid.NewGuid().ToString("N") + ".tidyvnc-tmp";
        await File.WriteAllTextAsync(stale, "{\"half\":");
        var unrelated = Path.Combine(State, "profiles-history.json.1.tidyvnc-tmp");
        await File.WriteAllTextAsync(unrelated, "");
        Assert.IsTrue((await store.ReadAsync()).IsStored, "a leftover never affects reads");
        await store.CommitAsync(new(NativeSettings.Empty, NativeImportOrigin.None), (await store.ReadAsync()).Revision);
        Assert.IsFalse(File.Exists(stale));
        Assert.IsTrue(File.Exists(unrelated), "only this record's leftovers are removed");
    }

    [TestMethod]
    public async Task ClosedAndCancelledStoresRefuseWork()
    {
        var store = new NativePreferencesStore(State);
        using var cancelled = new CancellationTokenSource();
        await cancelled.CancelAsync();
        Assert.AreEqual(NativeStorageError.Cancelled, await Failure(() => store.CommitAsync(new(Sample(), NativeImportOrigin.None), null, cancelled.Token)));
        Assert.IsFalse(Directory.Exists(State));
        await store.CloseAsync();
        Assert.AreEqual(NativeStorageError.Closed, await Failure(() => store.ReadAsync()));
        store.Dispose();
    }

    [TestMethod]
    public async Task ProfilesAndHistoryRoundTripWithGatewaysAndCapacity()
    {
        using var store = new NativeProfileHistoryStore(State);
        var gateway = NativeSshGateway.Parse("ssh://alice@jump.example:2222");
        var profile = new NativeConnectionProfile(Guid.NewGuid(), "Office", "desk.example::5901", Sample(), gateway, Guid.NewGuid());
        var value = new NativeProfileHistory([profile, profile with { Id = Guid.NewGuid(), Name = "Lab", SshGateway = null, CredentialReference = null }],
            [new("desk.example::5901", gateway), new("desk.example::5901", null), new("[::1]:2", null)], NativeHistoryState.Native);
        var saved = await store.CommitAsync(value, null);
        var read = await store.ReadAsync();
        Assert.AreEqual(value, read.Value);
        Assert.AreEqual(gateway, read.Value.Profiles[0].SshGateway);
        Assert.IsFalse(read.Value.CanImportHistory);
        Assert.IsTrue(NativeProfileHistory.Empty.CanImportHistory);

        var full = value with { RecentConnections = [.. Enumerable.Range(1, 21).Select(n => new NativeConnectionDestination($"host{n}", null))] };
        Assert.AreEqual(NativeStorageError.ResourceLimit, await Failure(() => store.CommitAsync(full, saved.Revision)));
        Assert.AreEqual(saved.Revision, (await store.ReadAsync()).Revision);

        var id = Guid.NewGuid();
        foreach (var body in new[]
        {
            "\"profiles\":[{\"id\":\"" + id + "\",\"name\":\"a\",\"endpoint\":\"h\"},{\"id\":\"" + id + "\",\"name\":\"b\",\"endpoint\":\"h\"}]",
            "\"profiles\":[{\"id\":\"" + id + "\",\"name\":\"\",\"endpoint\":\"h\"}]",
            "\"profiles\":[{\"id\":\"" + id + "\",\"name\":\"a\",\"endpoint\":\"h\",\"sshGateway\":\"ssh-v1:abc\"}]",
            "\"profiles\":[{\"id\":\"" + id + "\",\"name\":\"a\",\"endpoint\":\"h\",\"sshGateway\":\"jump.example\"}]",
            "\"recentConnections\":[{\"endpoint\":\"h\"},{\"endpoint\":\"h\"}]",
            "\"historyState\":\"legacy\"",
        })
        {
            WriteRaw("profiles-history.json", "{\"schema\":1,\"revision\":\"" + Guid.NewGuid() + "\"," + body + "}");
            Assert.AreEqual(NativeStorageError.Corrupt, await Failure(() => store.ReadAsync()), body);
        }
        WriteRaw("profiles-history.json", "{\"schema\":1,\"revision\":\"" + Guid.NewGuid() + "\",\"recentConnections\":[{\"endpoint\":\"h\",\"password\":\"x\"}]}");
        Assert.AreEqual(NativeStorageError.UnsupportedFields, await Failure(() => store.ReadAsync()));
    }

    [TestMethod]
    public async Task WindowStateRoundTripsSeparatelyFromSettings()
    {
        using var store = new NativeWindowStateStore(State);
        var value = (await store.ReadAsync()).Value
            .SetItem("connection", new NativeWindowPlacement(-1200, 40, 800, 600, false, "00ff"))
            .SetItem("desktop", new NativeWindowPlacement(0, 0, 1920, 1080, true, null));
        await store.CommitAsync(value, null);
        CollectionAssert.AreEqual(value.ToList(), (await store.ReadAsync()).Value.ToList());
        WriteRaw("window-state.json", "{\"schema\":1,\"revision\":\"" + Guid.NewGuid() + "\",\"windows\":{\"a\":{\"x\":0,\"y\":0,\"width\":0,\"height\":5,\"maximized\":false}}}");
        Assert.AreEqual(NativeStorageError.Corrupt, await Failure(() => store.ReadAsync()));
    }

    [TestMethod]
    public void DebugStateRootHonoursTheOverride()
    {
        var previous = Environment.GetEnvironmentVariable("TIDYVNC_STATE_ROOT");
        try
        {
            Environment.SetEnvironmentVariable("TIDYVNC_STATE_ROOT", root);
            Assert.AreEqual(Path.GetFullPath(root), NativeStateRoot.Directory);
            Environment.SetEnvironmentVariable("TIDYVNC_STATE_ROOT", null);
            StringAssert.EndsWith(NativeStateRoot.Directory, Path.DirectorySeparatorChar + "TidyVNC");
        }
        finally
        {
            Environment.SetEnvironmentVariable("TIDYVNC_STATE_ROOT", previous);
        }
    }
}
