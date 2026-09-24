// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using TidyVNC.Native.Storage;
using TidyVNC.Native.Trust;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Trust (plans/native-ui-winui TODO W4.3, SERVICES.md section 5): saved
/// decision stores, the read-only legacy x509_known_hosts files, CA/CRL path
/// rules, and the prompt controller end to end against a VeNCrypt X509 peer.
/// </summary>
[TestClass]
public sealed class TrustTests
{
    // An RSA-AES server key identity (tests/macos/support/TrustFixtures.swift).
    private static readonly byte[] HostKey = Convert.FromBase64String(
        "AAAIALPCaG8etCO1wAkR0nHCHz4wAnDAHd97EpB1HuS9IgGCaLhfT+D9i5JP0qfN5oTImqTxWqRfk9wV6jbY53WWoRLPx2rrKhSsgDeaJBUgCVL1eQXBWu/FFrxJsSqLSrKQflJkU96xis857YNdTrrSacCZ5EcRgKelAh/2CALM98u+aYcghKJHOFz+qBqR89j8WEh7nFYD+YJTOLH/6U2/z0UA8k5ZCB3XOdMaucsf7HnH/QpjiXCAMzeZS94LGhDIlrrtTfhSyxJTgx43JoqmmzQn7qBxTjKwmth3oXrlJQZGmav7bNULpulDhe1DoQCQkkNxcOyQI9ZDtAL/8CtygWMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAB");
    private const uint Overridable = 66;  // Unknown signer and invalid: the legacy exception set.
    private const uint Revoked = 1u << 5; // Never overridable.

    private string root = "";
    private string State => Path.Combine(root, "state");

    [TestInitialize]
    public void Setup()
    {
        root = Path.Combine(Path.GetTempPath(), "tidyvnc-trust-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
    }

    [TestCleanup]
    public void Teardown() => Directory.Delete(root, recursive: true);

    private static byte[] Certificate(out byte[] spki)
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=trust-test", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(30));
        spki = key.ExportSubjectPublicKeyInfo();
        return certificate.RawData;
    }

    private static async Task<NativeStorageError> Failure(Func<Task> body)
    {
        try { await body(); }
        catch (NativeStorageException error) { return error.Error; }
        Assert.Fail("Expected a storage failure");
        return default;
    }

    private static async Task Until(Func<bool> condition, int seconds = 15)
    {
        var deadline = Stopwatch.StartNew();
        while (!condition())
        {
            if (deadline.Elapsed > TimeSpan.FromSeconds(seconds)) Assert.Fail("Condition not reached in time");
            await Task.Delay(5);
        }
    }

    // ---- Saved decisions -------------------------------------------------------------------

    [TestMethod]
    public async Task CertificateDecisionsAreDestinationScopedAndRevisioned()
    {
        using var store = new NativeTrustStore(NativeTrustKind.Certificate, State);
        var certificate = Certificate(out var spki);
        var other = Certificate(out _);
        var scope = NativeTrustScope.Create("desk.example::5901");
        var elsewhere = NativeTrustScope.Create("desk.example::5902");
        Assert.AreEqual(scope, NativeTrustScope.Create("desk.example::5901"));
        Assert.AreNotEqual(scope, NativeTrustScope.Create("desk.example::5901", "", NativeTrustKind.HostKey));
        Assert.AreEqual("NativeTrustScope(<redacted>)", scope.ToString());

        var absent = await store.InspectAsync(scope, certificate);
        Assert.AreEqual(NativeSavedTrustState.Absent, absent.State);
        Assert.AreEqual(NativeTrustFingerprint.Of(spki), absent.ReceivedFingerprint);
        Assert.AreEqual(NativeStorageError.Denied, await Failure(() => store.SaveAsync(scope, certificate, Revoked, false, null)));
        Assert.AreEqual(NativeStorageError.Denied, await Failure(() => store.SaveAsync(scope, certificate, Overridable | Revoked, false, null)));
        Assert.AreEqual(NativeStorageError.Conflict, await Failure(() => store.SaveAsync(scope, certificate, Overridable, true, null)),
            "replacing needs a saved key");
        var saved = await store.SaveAsync(scope, certificate, Overridable, false, absent.Revision);
        CollectionAssert.AreEqual(spki, saved.Entries.Single().Identity!.Value.ToArray(), "only the SPKI is stored");

        var match = await store.InspectAsync(scope, certificate);
        Assert.AreEqual(NativeSavedTrustState.Match, match.State);
        Assert.AreEqual(NativeSavedTrustState.Absent, (await store.InspectAsync(elsewhere, certificate)).State);
        var changed = await store.InspectAsync(scope, other);
        Assert.AreEqual(NativeSavedTrustState.Changed, changed.State);
        Assert.AreEqual(NativeTrustFingerprint.Of(spki), changed.SavedFingerprint);
        Assert.AreEqual(NativeStorageError.Conflict, await Failure(() => store.SaveAsync(scope, other, Overridable, false, changed.Revision)),
            "a changed key is only replaced knowingly");
        Assert.AreEqual(NativeStorageError.Conflict, await Failure(() => store.SaveAsync(scope, other, Overridable, true, absent.Revision)),
            "a stale revision is a conflict");
        await store.SaveAsync(scope, other, Overridable, true, changed.Revision);
        Assert.AreEqual(NativeSavedTrustState.Match, (await store.InspectAsync(scope, other)).State);

        var forgotten = await store.ForgetAsync(scope, (await store.ReadSnapshotAsync()).Revision);
        Assert.IsTrue(forgotten.Entries.Single().IsForgotten);
        Assert.AreEqual(NativeSavedTrustState.Forgotten, (await store.InspectAsync(scope, other)).State);
        var afterForget = await store.InspectAsync(scope, other);
        await store.SaveAsync(scope, other, Overridable, false, afterForget.Revision);
        Assert.AreEqual(NativeSavedTrustState.Match, (await store.InspectAsync(scope, other)).State);
        Assert.IsTrue(File.Exists(Path.Combine(State, "trust", "certificates.json")));
        NativePrivateFiles.CheckPrivate(new DirectoryInfo(Path.Combine(State, "trust")));
    }

    [TestMethod]
    public async Task ServerKeyDecisionsUseTheirOwnRecord()
    {
        using var store = new NativeTrustStore(NativeTrustKind.HostKey, State);
        var scope = NativeTrustScope.Create("desk.example::5901", "", NativeTrustKind.HostKey);
        var otherKey = (byte[])HostKey.Clone();
        otherKey[259] ^= 2;
        var absent = await store.InspectHostKeyAsync(scope, HostKey);
        await store.SaveHostKeyAsync(scope, HostKey, false, absent.Revision);
        Assert.AreEqual(NativeSavedTrustState.Match, (await store.InspectHostKeyAsync(scope, HostKey)).State);
        Assert.AreEqual(NativeSavedTrustState.Changed, (await store.InspectHostKeyAsync(scope, otherKey)).State);
        Assert.AreEqual(NativeStorageError.Corrupt, await Failure(() => store.InspectHostKeyAsync(scope, [1, 2, 3])));
        Assert.AreEqual(NativeStorageError.UnsupportedFields, await Failure(() => store.InspectAsync(scope, Certificate(out _))),
            "a server-key store never holds certificates");
        Assert.IsTrue(File.Exists(Path.Combine(State, "trust", "server-keys.json")));
        Assert.IsFalse(File.Exists(Path.Combine(State, "trust", "certificates.json")));
    }

    [TestMethod]
    public async Task StoredRecordsAreRevalidated()
    {
        using var store = new NativeTrustStore(NativeTrustKind.Certificate, State);
        var scope = NativeTrustScope.Create("desk.example::5901");
        await store.SaveAsync(scope, Certificate(out _), Overridable, false, null);
        var path = Path.Combine(State, "trust", "certificates.json");
        var original = await File.ReadAllTextAsync(path);
        async Task<NativeStorageError> Edited(string from, string to)
        {
            Assert.IsTrue(original.Contains(from, StringComparison.Ordinal), from);
            await File.WriteAllTextAsync(path, original.Replace(from, to, StringComparison.Ordinal));
            return await Failure(() => store.ReadSnapshotAsync());
        }
        Assert.AreEqual(NativeStorageError.Corrupt, await Edited("desk.example::5901", "desk.example::5902"), "scopes are rederived");
        Assert.AreEqual(NativeStorageError.UnsupportedFields, await Edited("\"accept\"", "\"maybe\""));
        Assert.AreEqual(NativeStorageError.UnsupportedFields, await Edited("\"x509-spki\"", "\"rsa-aes\""));
        Assert.AreEqual(NativeStorageError.UnsupportedFields, await Edited("\"route\"", "\"label\": 1, \"route\""));
        Assert.AreEqual(NativeStorageError.Corrupt, await Edited("\"decision\": \"accept\"", "\"decision\": \"forget\""), "a forget carries no key");

        var entries = string.Join(",", Enumerable.Range(0, NativeTrustStore.Capacity + 1).Select(n =>
        {
            var s = NativeTrustScope.Create($"h{n}::1");
            return $"{{\"scope\":\"{s.Id}\",\"endpoint\":\"h{n}::1\",\"route\":\"\",\"decision\":\"forget\"}}";
        }));
        await File.WriteAllTextAsync(path, $"{{\"schema\":1,\"revision\":\"{Guid.NewGuid()}\",\"kind\":\"x509-spki\",\"entries\":[{entries}]}}");
        Assert.AreEqual(NativeStorageError.ResourceLimit, await Failure(() => store.ReadSnapshotAsync()));
    }

    // ---- Legacy files and CA/CRL paths ------------------------------------------------------

    private string LegacyFile(string name, string contents)
    {
        var directory = Path.Combine(root, "legacy");
        NativePrivateFiles.EnsureDirectory(directory);
        var path = Path.Combine(directory, name);
        File.WriteAllText(path, contents);
        return path;
    }

    private static string Record(string host, byte[] spki) => $"|g0|{host}|*|0|{Convert.ToBase64String(spki)}\n";

    [TestMethod]
    public async Task LegacyFilesAreReadOnlyAndCombined()
    {
        var certificate = Certificate(out var spki);
        Certificate(out var otherSpki);
        var missing = Path.Combine(root, "legacy-missing", "x509_known_hosts");
        var changed = LegacyFile("changed", Record("127.0.0.1", otherSpki));
        var matching = LegacyFile("matching", Record("127.0.0.1", spki));
        var before = File.GetLastWriteTimeUtc(matching);

        Assert.AreEqual(NativeKnownHostsState.Missing, (await new NativeLegacyTrustFiles([missing]).LookupAsync("127.0.0.1", certificate)).State);
        Assert.AreEqual(NativeKnownHostsState.Changed, (await new NativeLegacyTrustFiles([missing, changed]).LookupAsync("127.0.0.1", certificate)).State);
        Assert.AreEqual(NativeKnownHostsState.Match, (await new NativeLegacyTrustFiles([changed, matching]).LookupAsync("127.0.0.1", certificate)).State);
        Assert.AreEqual(NativeKnownHostsState.Missing, (await new NativeLegacyTrustFiles([matching]).LookupAsync("localhost", certificate)).State);
        Assert.AreEqual(before, File.GetLastWriteTimeUtc(matching), "lookups never write");

        var defaults = NativeLegacyTrustFiles.Default().Paths;
        StringAssert.EndsWith(defaults[0], @"\TidyVNC\x509_known_hosts");
        StringAssert.EndsWith(defaults[1], @"\TigerVNC\x509_known_hosts");

        async Task<NativeLegacyTrustError> Refused(string path)
        {
            try { await new NativeLegacyTrustFiles([path]).LookupAsync("127.0.0.1", certificate); }
            catch (NativeLegacyTrustException error) { return error.Error; }
            Assert.Fail("Expected a legacy trust failure");
            return default;
        }
        Assert.AreEqual(NativeLegacyTrustError.UnsupportedFormat, await Refused(LegacyFile("format", "|x9|127.0.0.1|*|0|AA==\n")));
        Assert.AreEqual(NativeLegacyTrustError.Corrupt, await Refused(LegacyFile("corrupt", "|g0|127.0.0.1|*|0|not base64\n")));

        // A file others can modify is not trusted, even if it matches.
        var shared = LegacyFile("shared", Record("127.0.0.1", spki));
        var info = new FileInfo(shared);
        var security = info.GetAccessControl();
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null), FileSystemRights.Modify, AccessControlType.Allow));
        info.SetAccessControl(security);
        Assert.AreEqual(NativeLegacyTrustError.UnsafeFile, await Refused(shared));

        var linked = Path.Combine(root, "legacy", "linked");
        using (var mklink = Process.Start(new ProcessStartInfo("cmd.exe", ["/d", "/c", "mklink", "/H", linked, matching])
               { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true })!)
            await mklink.WaitForExitAsync();
        Assert.AreEqual(NativeLegacyTrustError.UnsafeFile, await Refused(linked), "hard-linked files are refused");
        Assert.AreEqual(NativeLegacyTrustError.UnsafeFile, await Refused(Path.Combine(root, "legacy")), "directories are refused");
    }

    [TestMethod]
    public void CaAndCrlPathsFollowWindowsRules()
    {
        Assert.IsTrue(NativeTrustFiles.IsValidPath(""));
        Assert.IsTrue(NativeTrustFiles.IsValidPath(@"C:\certs\ca.pem"));
        Assert.IsTrue(NativeTrustFiles.IsValidPath(@"\\server\share\ca.pem"));
        Assert.IsFalse(NativeTrustFiles.IsValidPath("ca.pem"));
        Assert.IsFalse(NativeTrustFiles.IsValidPath(@"C:ca.pem"));
        Assert.IsFalse(NativeTrustFiles.IsValidPath(@"\ca.pem"));
        Assert.IsFalse(NativeTrustFiles.IsValidPath("C:\\a\0b"));
        Assert.AreEqual(@"D:\docs\certs\ca.pem", NativeTrustFiles.ResolveRelative(@"certs\ca.pem", @"D:\docs"));
        Assert.AreEqual(@"C:\ca.pem", NativeTrustFiles.ResolveRelative(@"C:\ca.pem", @"D:\docs"));
        Assert.AreEqual("", NativeTrustFiles.ResolveRelative("", @"D:\docs"));
        Assert.IsNull(NativeTrustFiles.ResolveRelative(@"\ca.pem", @"D:\docs"));
        Assert.IsNull(NativeTrustFiles.ResolveRelative(@"C:ca.pem", @"D:\docs"));
        var configuration = new NativeSessionConfiguration { CaFile = "keep", CrlFile = "keep" };
        new NativeTrustFiles(CaFile: @"C:\ca.pem").ApplyTo(configuration);
        Assert.AreEqual(@"C:\ca.pem", configuration.CaFile);
        Assert.AreEqual("keep", configuration.CrlFile, "null inherits");
        new NativeTrustFiles(CrlFile: "").ApplyTo(configuration);
        Assert.AreEqual("", configuration.CrlFile, "empty selects no file");
        Assert.ThrowsExactly<ArgumentException>(() => new NativeTrustFiles(CaFile: "relative").ApplyTo(configuration));
    }

    // ---- The prompt controller -----------------------------------------------------------------

    private sealed record Scenario(SingleThreadDispatcher Ui, TlsPeer Peer, NativeSession Session, NativeCertificateTrust Trust,
                                   NativeTrustStore Store)
    {
        public List<NativePrompt> Prompts { get; } = [];
        public List<NativeSavedTrustState> SavedStates { get; } = [];
        public List<NativeKnownHostsState> LegacyStates { get; } = [];

        public void Record() => Trust.PropertyChanged += (_, change) =>
        {
            if (change.PropertyName == nameof(NativeCertificateTrust.SavedInspection) && Trust.SavedInspection is { } saved) SavedStates.Add(saved.State);
            if (change.PropertyName == nameof(NativeCertificateTrust.Inspection) && Trust.Inspection is { } legacy) LegacyStates.Add(legacy.State);
        };

        public async Task<NativeSnapshot> Attempt(Action<NativePrompt>? answer = null)
        {
            void Handler(object? sender, System.ComponentModel.PropertyChangedEventArgs change)
            {
                if (change.PropertyName != nameof(NativeSession.Prompt) || Session.Prompt is not { Kind: NativePrompt.PromptKind.Certificate } prompt) return;
                Prompts.Add(prompt);
                answer?.Invoke(prompt);
            }
            Session.PropertyChanged += Handler;
            try
            {
                Trust.BeginAttempt(Peer.Endpoint);
                var connect = Session.ConnectAsync(Peer.Endpoint);
                try { await connect; } catch (NativeCommandFailure) { }
                await Until(() => Session.Snapshot.State is NativeSessionState.Connected or NativeSessionState.Closed or NativeSessionState.Failed);
                return Session.Snapshot;
            }
            finally { Session.PropertyChanged -= Handler; }
        }

        public async Task Disconnect()
        {
            await Session.DisconnectAsync();
            await Until(() => Session.Snapshot.State is NativeSessionState.Closed or NativeSessionState.Failed);
        }
    }

    private async Task Run(Func<Scenario, Task> body, Func<TlsPeer, NativeLegacyTrustFiles?>? legacy = null)
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new TlsPeer();
        using var store = new NativeTrustStore(NativeTrustKind.Certificate, State);
        var files = legacy?.Invoke(peer) ?? new NativeLegacyTrustFiles([Path.Combine(root, "none", "x509_known_hosts")]);
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [260], PromptTimeoutMilliseconds = 20_000 });
            var trust = new NativeCertificateTrust(ui, files, store);
            trust.Bind(session);
            var scenario = new Scenario(ui, peer, session, trust, store);
            scenario.Record();
            try { await body(scenario); }
            finally
            {
                await trust.CloseAsync();
                await session.CloseAsync();
                await runtime.ShutdownAsync();
            }
        });
    }

    [TestMethod]
    public Task SavedExceptionsAnswerLaterPromptsForTheSameDestination() => Run(async s =>
    {
        var first = await s.Attempt(prompt => _ = WaitThenSave(s, prompt));
        Assert.AreEqual(NativeSessionState.Connected, first.State);
        Assert.AreEqual(1, s.Prompts.Count);
        var snapshot = await s.Store.ReadSnapshotAsync();
        CollectionAssert.AreEqual(s.Peer.Spki, snapshot.Entries.Single().Identity!.Value.ToArray());
        await s.Disconnect();

        // A saved match answers without any user action.
        Assert.AreEqual(NativeSessionState.Connected, (await s.Attempt()).State);
        Assert.AreEqual(NativeSavedTrustState.Match, s.SavedStates[^1]);
        Assert.AreEqual(2, s.Prompts.Count, "the core still asked; the saved decision answered");
        Assert.AreEqual(2, s.Peer.Established);
    });

    private static async Task WaitThenSave(Scenario s, NativePrompt prompt)
    {
        await Until(() => s.Trust.CanSave(prompt));
        Assert.AreEqual(NativeSavedTrustState.Absent, s.Trust.SavedInspection?.State);
        Assert.AreEqual(NativeKnownHostsState.Missing, s.Trust.Inspection?.State);
        Assert.IsFalse(s.Trust.ReplacesSavedKey);
        s.Trust.SaveAndConnect(prompt);
    }

    [TestMethod]
    public Task ConnectOnceSavesNothingAndCancelLeavesThePromptToTheCore() => Run(async s =>
    {
        var once = await s.Attempt(prompt => _ = WaitThenConnectOnce(s, prompt));
        Assert.AreEqual(NativeSessionState.Connected, once.State);
        Assert.IsFalse((await s.Store.ReadSnapshotAsync()).Revision.HasValue, "connect once never writes");
        await s.Disconnect();

        NativePrompt? pending = null;
        var attempt = s.Attempt(prompt => pending = prompt);
        await Until(() => pending is not null && s.Trust.CanSave(pending));
        s.Trust.Cancel();
        Assert.IsFalse(s.Trust.CanConnectOnce(pending!));
        s.Session.ReplyTrust(pending!, false);
        Assert.AreNotEqual(NativeSessionState.Connected, (await attempt).State);
    });

    private static async Task WaitThenConnectOnce(Scenario s, NativePrompt prompt)
    {
        await Until(() => s.Trust.CanConnectOnce(prompt));
        s.Trust.ConnectOnce(prompt);
    }

    [TestMethod]
    public Task ALegacyExceptionIsUsedOnlyWithoutADestinationDecision() => Run(async s =>
    {
        Assert.AreEqual(NativeSessionState.Connected, (await s.Attempt()).State, "the legacy match answers");
        Assert.AreEqual(NativeKnownHostsState.Match, s.LegacyStates[^1]);
        await s.Disconnect();

        await s.Store.ForgetAsync(NativeTrustScope.Create(s.Peer.Endpoint), null);
        NativePrompt? pending = null;
        var attempt = s.Attempt(prompt => pending = prompt);
        await Until(() => pending is not null && s.Trust.SavedInspection is not null && !s.Trust.IsWorking);
        Assert.AreEqual(NativeSavedTrustState.Forgotten, s.Trust.SavedInspection!.State);
        Assert.IsNull(s.Trust.Inspection, "a forget suppresses the legacy fallback");
        Assert.IsNotNull(s.Session.Prompt);
        s.Trust.SaveAndConnect(pending!);
        Assert.AreEqual(NativeSessionState.Connected, (await attempt).State);
    }, peer => new NativeLegacyTrustFiles([LegacyFile("x509_known_hosts", Record("127.0.0.1", peer.Spki))]));

    [TestMethod]
    public Task AChangedKeyIsReportedAndReplacedOnlyOnRequest() => Run(async s =>
    {
        var scope = NativeTrustScope.Create(s.Peer.Endpoint);
        await s.Store.SaveAsync(scope, Certificate(out var oldSpki), Overridable, false, null);
        NativePrompt? pending = null;
        var attempt = s.Attempt(prompt => pending = prompt);
        await Until(() => pending is not null && s.Trust.CanSave(pending));
        Assert.AreEqual(NativeSavedTrustState.Changed, s.Trust.SavedInspection!.State);
        Assert.AreEqual(NativeTrustFingerprint.Of(oldSpki), s.Trust.SavedInspection.SavedFingerprint);
        Assert.IsTrue(s.Trust.ReplacesSavedKey);
        Assert.IsNull(s.Trust.Inspection, "a changed saved key does not consult legacy files");
        s.Trust.SaveAndConnect(pending!);
        Assert.AreEqual(NativeSessionState.Connected, (await attempt).State);
        CollectionAssert.AreEqual(s.Peer.Spki, (await s.Store.ReadSnapshotAsync()).Entries.Single().Identity!.Value.ToArray());
    });

    [TestMethod]
    public Task TheLibraryListsAndForgetsDecisions() => Run(async s =>
    {
        var library = new NativeTrustLibrary(s.Ui, s.Store);
        var scope = NativeTrustScope.Create("desk.example::5901");
        await s.Store.SaveAsync(scope, Certificate(out _), Overridable, false, null);
        library.Reload();
        await library.Work;
        Assert.AreEqual(1, library.Entries.Count);
        Assert.AreEqual("desk.example::5901", library.Entries[0].Scope.Endpoint);
        await s.Store.ForgetAsync(NativeTrustScope.Create("other.example::1"), (await s.Store.ReadSnapshotAsync()).Revision);
        library.Forget(library.Entries[0].Id);
        await library.Work;
        Assert.AreEqual(NativeStorageError.Conflict, library.Issue, "a stale view never overwrites");
        Assert.IsTrue(library.NeedsReload);
        library.Reload();
        await library.Work;
        library.Forget(library.Entries.First(e => !e.IsForgotten).Id);
        await library.Work;
        Assert.IsTrue(library.Forgot);
        Assert.IsTrue(library.Entries.All(e => e.IsForgotten));
        await library.CloseAsync();
    });
}
