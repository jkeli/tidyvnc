// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using TidyVNC.Native.Credentials;
using TidyVNC.Testing;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Credentials (plans/native-ui-winui TODO W4.2, SERVICES.md section 3, D15):
/// Credential Manager entries under a disposable prefix, result mapping, the
/// async store's admission rules, secrets, launch inputs and the password
/// file reader, and the retention controller end to end against a VncAuth
/// peer.
/// </summary>
[TestClass]
public sealed partial class CredentialTests
{
    private static readonly string Prefix = $"TidyVNC-test-{Guid.NewGuid():N}/credentials.v1/";

    private static async Task Until(Func<bool> condition, int seconds = 10)
    {
        var deadline = Stopwatch.StartNew();
        while (!condition())
        {
            if (deadline.Elapsed > TimeSpan.FromSeconds(seconds)) Assert.Fail("Condition not reached in time");
            await Task.Delay(5);
        }
    }

    private static NativeCredentialKey Key(string endpoint = "desk.example::5901", uint securityType = 2, bool usernameRequired = false, string user = "")
        => NativeCredentialKey.Create(endpoint, "", securityType, usernameRequired, user);

    private static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text);

    private static string Text(NativeCredentialSecret secret)
    {
        var bytes = secret.CopyBytes();
        try { return Encoding.UTF8.GetString(bytes); }
        finally { Array.Clear(bytes); }
    }

    private static NativeCredentialError Failure(Action body)
    {
        try { body(); }
        catch (NativeCredentialException error) { return error.Error; }
        Assert.Fail("Expected a credential failure");
        return default;
    }

    private static async Task<NativeCredentialError> FailureAsync(Func<Task> body)
    {
        try { await body(); }
        catch (NativeCredentialException error) { return error.Error; }
        Assert.Fail("Expected a credential failure");
        return default;
    }

    // ---- Credential Manager ---------------------------------------------------------------

    [LibraryImport("advapi32.dll", EntryPoint = "CredReadW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [LibraryImport("advapi32.dll", EntryPoint = "CredFree")]
    private static partial void CredFree(IntPtr buffer);

    [TestMethod]
    public void CredentialManagerEntriesFollowTheDocumentedShape()
    {
        var backing = new NativeCredentialManagerBacking(Prefix);
        var key = Key(endpoint: Guid.NewGuid().ToString("N") + ".example");
        var other = Key(endpoint: Guid.NewGuid().ToString("N") + ".example");
        try
        {
            Assert.AreEqual(NativeCredentialError.NotFound, Failure(() => backing.Lookup(key)));
            Assert.AreEqual(0, backing.List(10).Entries.Count);
            using (var secret = NativeCredentialSecret.Consume(Utf8("pässword")))
                backing.Save(key, secret, NativeCredentialSaveMode.Create);
            using (var read = backing.Lookup(key)) Assert.AreEqual("pässword", Text(read));
            using (var again = NativeCredentialSecret.Consume(Utf8("other")))
            {
                Assert.AreEqual(NativeCredentialError.Duplicate, Failure(() => backing.Save(key, again, NativeCredentialSaveMode.Create)));
                backing.Save(key, again, NativeCredentialSaveMode.Replace);
                backing.Save(other, again, NativeCredentialSaveMode.Create);
            }
            using (var read = backing.Lookup(key)) Assert.AreEqual("other", Text(read));

            // The raw entry: generic, local-machine persistence, no user name, fixed comment, UTF-8 blob.
            Assert.IsTrue(CredRead(Prefix + key.Digest, 1, 0, out var raw));
            try
            {
                Assert.AreEqual(1, Marshal.ReadInt32(raw, 4)); // Type: CRED_TYPE_GENERIC
                var persist = Marshal.ReadInt32(raw, IntPtr.Size == 8 ? 48 : 32);
                Assert.AreEqual(2, persist); // CRED_PERSIST_LOCAL_MACHINE
                var comment = Marshal.PtrToStringUni(Marshal.ReadIntPtr(raw, IntPtr.Size == 8 ? 16 : 12));
                Assert.AreEqual(NativeCredentialManagerBacking.Comment, comment);
                var user = Marshal.ReadIntPtr(raw, IntPtr.Size == 8 ? 72 : 48);
                Assert.IsTrue(user == IntPtr.Zero || Marshal.PtrToStringUni(user) == "");
            }
            finally { CredFree(raw); }

            var page = backing.List(10);
            CollectionAssert.AreEquivalent(new[] { key, other }, page.Entries.Select(e => e.Key).ToArray());
            Assert.IsFalse(page.HasMore);
            Assert.IsTrue(page.Entries.All(e => e.Modified is { } when && Math.Abs((DateTimeOffset.Now - when).TotalMinutes) < 5));
            var first = backing.List(1);
            Assert.AreEqual(1, first.Entries.Count);
            Assert.IsTrue(first.HasMore);

            using (var large = NativeCredentialSecret.Consume(new byte[NativeCredentialManagerBacking.MaximumBlobBytes + 1]))
                Assert.AreEqual(NativeCredentialError.Invalid, Failure(() => backing.Save(key, large, NativeCredentialSaveMode.Replace)));
            using (var read = backing.Lookup(key)) Assert.AreEqual("other", Text(read));

            backing.Delete(key);
            Assert.AreEqual(NativeCredentialError.NotFound, Failure(() => backing.Delete(key)));
            Assert.AreEqual(NativeCredentialError.NotFound, Failure(() => backing.Lookup(key)));
            // Deleting one entry (as Control Panel can) leaves the others listed.
            CollectionAssert.AreEqual(new[] { other }, backing.List(10).Entries.Select(e => e.Key).ToArray());
        }
        finally
        {
            foreach (var entry in new[] { key, other })
                try { backing.Delete(entry); } catch (NativeCredentialException) { }
        }
        Assert.AreEqual(0, backing.List(10).Entries.Count);
    }

    [TestMethod]
    public void Win32ResultsMapToServiceResults()
    {
        Assert.AreEqual(NativeCredentialError.NotFound, NativeCredentialManagerBacking.Classify(1168));
        Assert.AreEqual(NativeCredentialError.Unavailable, NativeCredentialManagerBacking.Classify(1312));
        Assert.AreEqual(NativeCredentialError.Invalid, NativeCredentialManagerBacking.Classify(87));
        Assert.AreEqual(NativeCredentialError.Invalid, NativeCredentialManagerBacking.Classify(1004));
        Assert.AreEqual(NativeCredentialError.Invalid, NativeCredentialManagerBacking.Classify(2202));
        Assert.AreEqual(NativeCredentialError.Denied, NativeCredentialManagerBacking.Classify(5));
        Assert.AreEqual(NativeCredentialError.IOFailure, NativeCredentialManagerBacking.Classify(31));
    }

    [TestMethod]
    public void KeysAreDigestsOfTheNegotiatedMethodAndUser()
    {
        Assert.AreEqual(Key(), Key());
        StringAssert.StartsWith(Key().Account, "v1:");
        Assert.AreEqual(64, Key().Digest.Length);
        Assert.AreNotEqual(Key(), Key(securityType: 30));
        Assert.AreNotEqual(Key(usernameRequired: true, user: "alice"), Key(usernameRequired: true, user: "bob"));
        Assert.AreNotEqual(Key(), Key(usernameRequired: true));
        Assert.AreEqual(Key(), NativeCredentialKey.Create("desk.example::5901", "", 2, false, "ignored for password-only"));
        Assert.IsFalse(Key().ToString().Contains("desk", StringComparison.Ordinal));
        Assert.IsNull(NativeCredentialKey.FromDigest("XYZ"));
        Assert.AreEqual(Key(), NativeCredentialKey.FromDigest(Key().Digest));
        foreach (var wrapper in new uint[] { 0, 1, 19 })
            Assert.ThrowsExactly<NativeIdentityFailure>(() => Key(securityType: wrapper));
    }

    // ---- Secrets and the async store ------------------------------------------------------

    [TestMethod]
    public void SecretsConsumeTheirInputAndClear()
    {
        var input = Utf8("hunter2");
        var secret = NativeCredentialSecret.Consume(input);
        Assert.IsTrue(input.All(b => b == 0));
        Assert.AreEqual("hunter2", Text(secret));
        Assert.AreEqual("NativeCredentialSecret(<redacted>)", secret.ToString());
        secret.Clear();
        Assert.IsTrue(secret.IsCleared);
        Assert.AreEqual(NativeCredentialError.SecretCleared, Failure(() => secret.CopyBytes()));
        var large = new byte[NativeCredentialSecret.MaximumBytes + 1];
        large[0] = 7;
        Assert.AreEqual(NativeCredentialError.TooLarge, Failure(() => NativeCredentialSecret.Consume(large)));
        Assert.AreEqual(0, large[0]);
        using var empty = NativeCredentialSecret.Consume([]);
        Assert.AreEqual(0, empty.CopyBytes().Length);
    }

    private sealed class MemoryBacking : INativeCredentialBacking
    {
        public ConcurrentDictionary<NativeCredentialKey, string> Entries { get; } = new();
        public SemaphoreSlim? Hold { get; set; }
        public int Started;

        private void Enter()
        {
            Interlocked.Increment(ref Started);
            Hold?.Wait();
        }

        public NativeCredentialSecret Lookup(NativeCredentialKey key)
        {
            Enter();
            return Entries.TryGetValue(key, out var value) ? NativeCredentialSecret.Consume(Utf8(value))
                                                           : throw new NativeCredentialException(NativeCredentialError.NotFound);
        }

        public void Save(NativeCredentialKey key, NativeCredentialSecret secret, NativeCredentialSaveMode mode)
        {
            Enter();
            if (mode == NativeCredentialSaveMode.Create && Entries.ContainsKey(key)) throw new NativeCredentialException(NativeCredentialError.Duplicate);
            Entries[key] = Text(secret);
        }

        public void Delete(NativeCredentialKey key)
        {
            Enter();
            if (!Entries.TryRemove(key, out _)) throw new NativeCredentialException(NativeCredentialError.NotFound);
        }

        public NativeCredentialMetadataPage List(int limit)
        {
            Enter();
            return new([.. Entries.Keys.Take(limit).Select(k => new NativeCredentialMetadata(k, null))], Entries.Count > limit);
        }
    }

    [TestMethod]
    public async Task StoreAdmissionIsBoundedCancellableAndDrainsOnClose()
    {
        var memory = new MemoryBacking { Hold = new SemaphoreSlim(0) };
        var store = new NativeCredentialStore(memory);
        var first = store.LookupAsync(Key());
        await Until(() => memory.Started == 1);
        using var cancel = new CancellationTokenSource();
        var queued = store.DeleteAsync(Key(), cancel.Token);
        var others = Enumerable.Range(0, NativeCredentialStore.MaximumPending - 2).Select(_ => store.ListAsync()).ToList();
        Assert.AreEqual(NativeCredentialError.Busy, await FailureAsync(() => store.ListAsync().WaitAsync(TimeSpan.FromSeconds(5))));
        await cancel.CancelAsync();
        Assert.AreEqual(NativeCredentialError.Cancelled, await FailureAsync(() => queued.WaitAsync(TimeSpan.FromSeconds(5))));
        Assert.AreEqual(NativeCredentialError.Cancelled, await FailureAsync(() => store.ListAsync(cancellation: cancel.Token)));
        Assert.AreEqual(NativeCredentialError.TooLarge, await FailureAsync(() => store.ListAsync(257)));

        var closing = store.CloseAsync();
        Assert.IsFalse(closing.IsCompleted, "close waits for the admitted lookup");
        Assert.AreEqual(NativeCredentialError.Closed, await FailureAsync(() => store.ListAsync().WaitAsync(TimeSpan.FromSeconds(5))));
        memory.Hold.Release(100);
        // The admitted operation reports its own outcome; queued ones are cancelled by close.
        Assert.AreEqual(NativeCredentialError.NotFound, await FailureAsync(() => first));
        foreach (var other in others) Assert.AreEqual(NativeCredentialError.Cancelled, await FailureAsync(() => other));
        await closing;
        Assert.AreEqual(1, memory.Started);
        await store.DisposeAsync();
    }

    // ---- Launch inputs and password files --------------------------------------------------

    [TestMethod]
    public void PasswordFileSelectionFollowsWindowsPathRules()
    {
        string? Select(string cwd, params string[] arguments) => NativeLaunchCredentialInputs.PasswordFile(NativeInvocation.Parse(arguments), cwd);
        Assert.AreEqual(@"C:\work\secret", Select(@"C:\work", "-passwd", "secret"));
        Assert.AreEqual(@"C:\work\sub\..\secret", Select(@"C:\work\", "-PasswordFile", @"sub\..\secret"));
        Assert.AreEqual(@"D:\keys\p", Select(@"C:\work", "-passwd", @"D:\keys\p"));
        Assert.AreEqual(@"\\server\share\p", Select(@"C:\work", "-passwd", @"\\server\share\p"));
        Assert.AreEqual(@"C:\work\~\p", Select(@"C:\work", "-passwd", @"~\p"));
        Assert.AreEqual(@"C:\work\%USERPROFILE%\p", Select(@"C:\work", "-passwd", @"%USERPROFILE%\p"));
        Assert.IsNull(Select(@"C:\work", "-passwd", "a", "-passwd", ""));
        Assert.AreEqual(@"C:\work\b", Select(@"C:\work", "-passwd", "a", "-PasswordFile", "b"));
        Assert.IsNull(Select(@"C:\work", "host"));
        foreach (var refused in new[] { @"C:relative", @"\rooted" })
        {
            var error = Assert.ThrowsExactly<NativeLaunchCredentialException>(() => Select(@"C:\work", "-passwd", refused));
            Assert.AreEqual(NativeLaunchCredentialException.Problem.InvalidPasswordFile, error.Reason);
            Assert.AreEqual(2u, error.Argument);
        }
        Assert.AreEqual(NativeLaunchCredentialException.Problem.RelativePathNeedsBase,
            Assert.ThrowsExactly<NativeLaunchCredentialException>(() => NativeLaunchCredentialInputs.PasswordFile(NativeInvocation.Parse(["-passwd", "x"]), null)).Reason);
    }

    [TestMethod]
    public void EnvironmentCaptureRemovesTheVariablesAndClaimsOnce()
    {
        Environment.SetEnvironmentVariable(NativeLaunchCredentialInputs.UsernameVariable, "ålice");
        Environment.SetEnvironmentVariable(NativeLaunchCredentialInputs.PasswordVariable, "s3cret");
        using var inputs = NativeLaunchCredentialInputs.Capture(@"C:\p");
        Assert.IsNull(Environment.GetEnvironmentVariable(NativeLaunchCredentialInputs.UsernameVariable));
        Assert.IsNull(Environment.GetEnvironmentVariable(NativeLaunchCredentialInputs.PasswordVariable));
        Assert.AreEqual("NativeLaunchCredentialInputs(<redacted>)", inputs.ToString());
        var payload = inputs.Claim();
        Assert.IsNotNull(payload);
        Assert.IsNull(inputs.Claim());
        Assert.AreEqual("ålice", Text(payload.Username!));
        Assert.AreEqual("s3cret", Text(payload.Password!));
        Assert.AreEqual(@"C:\p", payload.File);
        Assert.IsTrue(payload.HasEnvironment(usernameRequired: true));
        payload.Clear();
        Assert.IsTrue(payload.Password!.IsCleared);

        using var absent = NativeLaunchCredentialInputs.Capture(null);
        var none = absent.Claim()!;
        Assert.IsNull(none.Password);
        Assert.IsFalse(none.HasEnvironment(usernameRequired: false));
        var oversized = new byte[NativeCredentialSecret.MaximumBytes + 1];
        Assert.AreEqual(NativeLaunchCredentialException.Problem.InvalidEnvironment,
            Assert.ThrowsExactly<NativeLaunchCredentialException>(() => new NativeLaunchCredentialInputs(null, oversized, null)).Reason);
        var empty = new NativeLaunchCredentialInputs(null, [], null).Claim()!;
        Assert.IsTrue(empty.HasEnvironment(usernameRequired: false), "present but empty is an explicit value");
    }

    /// <summary>The legacy obfuscation: DES-ECB with d3des's bit order over the fixed key.</summary>
    private static byte[] Obfuscate(string password)
    {
        byte[] fixedKey = [23, 82, 107, 6, 35, 78, 88, 7];
        var key = fixedKey.Select(b => (byte)Enumerable.Range(0, 8).Sum(bit => (b >> bit & 1) << (7 - bit))).ToArray();
        var block = new byte[8];
        Encoding.Latin1.GetBytes(password).AsSpan(0, Math.Min(8, password.Length)).CopyTo(block);
#pragma warning disable CA5351 // The legacy file format is DES by definition.
        using var des = DES.Create();
#pragma warning restore CA5351
        des.Key = key;
        return des.EncryptEcb(block, PaddingMode.None);
    }

    [TestMethod]
    public async Task PasswordFileReadsAreBoundedAndRefuseSpecialFiles()
    {
        var root = Path.Combine(Path.GetTempPath(), "tidyvnc-passwd-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var reader = new NativePasswordFileReader();
        async Task<NativePasswordFileError> Refused(string path, CancellationToken token = default)
        {
            try { using var _ = await reader.ReadAsync(path, token); }
            catch (NativePasswordFileException error) { return error.Error; }
            Assert.Fail("Expected a password file failure");
            return default;
        }
        try
        {
            var file = Path.Combine(root, "passwd");
            await File.WriteAllBytesAsync(file, [.. Obfuscate("password"), .. Obfuscate("viewonly"), 1, 2, 3]);
            using (var block = await reader.ReadAsync(file, default))
                CollectionAssert.AreEqual(Obfuscate("password"), block.CopyBytes());
            // PARITY W20: beyond MAX_PATH without the LongPathsEnabled setting.
            var longFolder = Path.Combine(root, new string('a', 120), new string('b', 120));
            Directory.CreateDirectory(longFolder);
            var longFile = Path.Combine(longFolder, "passwd");
            await File.WriteAllBytesAsync(longFile, Obfuscate("password"));
            using (var block = await reader.ReadAsync(longFile, default))
                CollectionAssert.AreEqual(Obfuscate("password"), block.CopyBytes());
            var shortFile = Path.Combine(root, "short");
            await File.WriteAllBytesAsync(shortFile, [1, 2, 3]);
            Assert.AreEqual(NativePasswordFileError.Truncated, await Refused(shortFile));
            Assert.AreEqual(NativePasswordFileError.Unreadable, await Refused(Path.Combine(root, "missing")));
            Assert.AreEqual(NativePasswordFileError.Unreadable, await Refused("relative"));
            Assert.AreEqual(NativePasswordFileError.NotRegular, await Refused(root));

            var junction = Path.Combine(root, "junction");
            using (var mklink = Process.Start(new ProcessStartInfo("cmd.exe", ["/d", "/c", "mklink", "/J", junction, root])
                   { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true })!)
                await mklink.WaitForExitAsync();
            Assert.AreEqual(NativePasswordFileError.NotRegular, await Refused(junction));
            Directory.Delete(junction);

            var pipeName = "tidyvnc-test-" + Guid.NewGuid().ToString("N");
            await using (var pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous))
            {
                var waiting = pipe.WaitForConnectionAsync();
                Assert.AreEqual(NativePasswordFileError.NotRegular, await Refused(@"\\.\pipe\" + pipeName));
            }
            Assert.AreEqual(NativePasswordFileError.NotRegular, await Refused(@"\\.\NUL"));

            using var cancelled = new CancellationTokenSource();
            await cancelled.CancelAsync();
            Assert.AreEqual(NativePasswordFileError.Cancelled, await Refused(file, cancelled.Token));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    // ---- The retention controller -----------------------------------------------------------

    private sealed class Scenario(SingleThreadDispatcher ui, RfbTestServer server, MemoryBacking memory, NativeCredentialStore? store,
                                  NativeRuntime runtime, NativeSession session, NativeAuthenticationCredentials credentials)
    {
        public SingleThreadDispatcher Ui { get; } = ui;
        public RfbTestServer Server { get; } = server;
        public MemoryBacking Memory { get; } = memory;
        public NativeCredentialStore? Store { get; } = store;
        public NativeRuntime Runtime { get; } = runtime;
        public NativeSession Session { get; } = session;
        public NativeAuthenticationCredentials Credentials { get; } = credentials;
        public NativeCredentialKey Key => NativeCredentialKey.Create(Server.Endpoint, "", 2, false);

        /// <summary>One attempt; answer runs for each credential prompt. Returns the settled snapshot.</summary>
        public async Task<NativeSnapshot> Attempt(Action<NativePrompt>? answer)
        {
            void Handler(object? sender, PropertyChangedEventArgs change)
            {
                if (change.PropertyName == nameof(NativeSession.Prompt) && Session.Prompt is { Kind: NativePrompt.PromptKind.Credentials } prompt)
                    answer?.Invoke(prompt);
            }
            Session.PropertyChanged += Handler;
            try
            {
                Credentials.BeginAttempt(Server.Endpoint);
                try { await Session.ConnectAsync(Server.Endpoint); }
                catch (NativeCommandFailure) { }
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

    private static async Task Run(Func<Scenario, Task> body, bool remembering = true, NativeLaunchCredentialInputs? launch = null)
    {
        using var ui = new SingleThreadDispatcher();
        await using var server = new RfbTestServer(width: 32, height: 24, password: "password");
        var memory = new MemoryBacking();
        await using var store = new NativeCredentialStore(memory);
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [2] });
            var credentials = new NativeAuthenticationCredentials(ui, remembering ? store : null, launch);
            credentials.Bind(session);
            try { await body(new Scenario(ui, server, memory, remembering ? store : null, runtime, session, credentials)); }
            finally
            {
                await credentials.CloseAsync();
                await session.CloseAsync();
                await runtime.ShutdownAsync();
            }
        });
    }

    [TestMethod]
    public Task RememberSavesOnlyAfterAuthenticationSucceeds() => Run(async s =>
    {
        var failed = await s.Attempt(p => s.Credentials.Submit(p, [], Utf8("wrong"), NativeCredentialRetention.Remember));
        Assert.AreEqual(NativeEndReason.AuthenticationRejected, failed.EndReason);
        await s.Credentials.Work;
        Assert.IsTrue(s.Memory.Entries.IsEmpty, "a rejected password is never saved");

        var connected = await s.Attempt(p => s.Credentials.Submit(p, [], Utf8("password"), NativeCredentialRetention.Remember));
        Assert.AreEqual(NativeSessionState.Connected, connected.State);
        await Until(() => s.Credentials.Notice?.Kind == NativeCredentialNoticeKind.Saved);
        Assert.AreEqual("password", s.Memory.Entries[s.Key]);
        Assert.IsFalse(s.Credentials.HasSessionCredential);
        await s.Disconnect();

        // A second remember does not overwrite without the explicit replace choice.
        await s.Attempt(p => s.Credentials.Submit(p, [], Utf8("password"), NativeCredentialRetention.Remember));
        await Until(() => s.Credentials.Notice?.Kind == NativeCredentialNoticeKind.SaveUnconfirmed);
        Assert.AreEqual(NativeCredentialError.Duplicate, s.Credentials.Notice!.StoreError);
        await s.Disconnect();
        s.Memory.Entries[s.Key] = "stale";
        await s.Attempt(p => s.Credentials.Submit(p, [], Utf8("password"), NativeCredentialRetention.ReplaceRemembered));
        await Until(() => s.Credentials.Notice?.Kind == NativeCredentialNoticeKind.Saved);
        Assert.AreEqual("password", s.Memory.Entries[s.Key]);
    });

    [TestMethod]
    public Task UseOnceKeepsNothingAndSessionRetentionIsExplicitlyReused() => Run(async s =>
    {
        byte[]? submitted = null;
        await s.Attempt(p => s.Credentials.Submit(p, [], submitted = Utf8("password")));
        Assert.IsTrue(submitted!.All(b => b == 0), "submitted buffers are wiped");
        await s.Credentials.Work;
        Assert.IsTrue(s.Memory.Entries.IsEmpty);
        Assert.IsFalse(s.Credentials.HasSessionCredential);
        await s.Disconnect();

        await s.Attempt(p => s.Credentials.Submit(p, [], Utf8("password"), NativeCredentialRetention.Session));
        Assert.IsTrue(s.Credentials.HasSessionCredential);
        Assert.IsTrue(s.Memory.Entries.IsEmpty, "session retention never persists");
        await s.Disconnect();
        Assert.IsTrue(s.Credentials.HasSessionCredential, "kept across a disconnect for this destination");

        var usable = false;
        var reconnected = await s.Attempt(p =>
        {
            usable = s.Credentials.CanUseSession(p, "");
            s.Credentials.UseSession(p, "");
        });
        Assert.IsTrue(usable);
        Assert.AreEqual(NativeSessionState.Connected, reconnected.State);
        Assert.IsTrue(s.Credentials.HasSessionCredential, "re-retained after a successful reuse");
        await s.Disconnect();

        s.Credentials.BeginAttempt("elsewhere.example::5900");
        Assert.IsFalse(s.Credentials.HasSessionCredential, "a different destination drops it");
    });

    [TestMethod]
    public Task ARejectedSavedPasswordIsReportedNotDeleted() => Run(async s =>
    {
        s.Memory.Entries[s.Key] = "outdated";
        var rejected = await s.Attempt(p => s.Credentials.UseSaved(p, ""));
        Assert.AreEqual(NativeEndReason.AuthenticationRejected, rejected.EndReason);
        await Until(() => s.Credentials.Notice?.Kind == NativeCredentialNoticeKind.SavedPasswordRejected);
        Assert.AreEqual("outdated", s.Memory.Entries[s.Key]);

        s.Memory.Entries[s.Key] = "password";
        var connected = await s.Attempt(p => s.Credentials.UseSaved(p, ""));
        Assert.AreEqual(NativeSessionState.Connected, connected.State);
        await s.Disconnect();

        s.Memory.Entries.Clear();
        NativePrompt? seen = null;
        var attempt = s.Attempt(p => { seen = p; s.Credentials.UseSaved(p, ""); });
        await Until(() => s.Credentials.Notice?.Kind == NativeCredentialNoticeKind.StoreFailure);
        Assert.AreEqual(NativeCredentialError.NotFound, s.Credentials.Notice!.StoreError);
        Assert.IsNotNull(s.Session.Prompt, "a lookup failure leaves the prompt for the user");
        s.Memory.Entries[s.Key] = "password";
        s.Credentials.ForgetSaved(seen!, "");
        await Until(() => s.Credentials.Notice?.Kind == NativeCredentialNoticeKind.Removed);
        Assert.IsTrue(s.Memory.Entries.IsEmpty);
        s.Credentials.Submit(seen!, [], Utf8("password"));
        Assert.AreEqual(NativeSessionState.Connected, (await attempt).State);
    });

    [TestMethod]
    public Task ReverseWindowsNeverRemember() => Run(async s =>
    {
        Assert.IsFalse(s.Credentials.SupportsRemembering);
        var outcome = NativeCredentialError.IOFailure;
        byte[]? password = null;
        var attempt = s.Attempt(p =>
        {
            try { s.Credentials.Submit(p, [], password = Utf8("password"), NativeCredentialRetention.Remember); }
            catch (NativeCredentialException error) { outcome = error.Error; s.Credentials.Submit(p, [], Utf8("password")); }
        });
        Assert.AreEqual(NativeSessionState.Connected, (await attempt).State);
        Assert.AreEqual(NativeCredentialError.Unavailable, outcome);
        Assert.IsTrue(password!.All(b => b == 0), "refused input is still wiped");
    }, remembering: false);

    [TestMethod]
    public async Task LaunchEnvironmentAnswersTheBoundEndpointOnly()
    {
        await Run(async s =>
        {
            var connected = await s.Attempt(null);
            Assert.AreEqual(NativeSessionState.Connected, connected.State);
            Assert.IsTrue(s.Memory.Entries.IsEmpty, "launch credentials are never saved");
            await s.Disconnect();
            // Reconnects to the same endpoint reuse them.
            Assert.AreEqual(NativeSessionState.Connected, (await s.Attempt(null)).State);
            await s.Disconnect();
            s.Credentials.EndpointChanged("elsewhere.example::5900");
            var attempt = s.Attempt(null);
            await Until(() => s.Session.Prompt is not null);
            await Task.Delay(100);
            Assert.IsNotNull(s.Session.Prompt, "revoked launch credentials do not answer");
            s.Credentials.Submit(s.Session.Prompt!, [], Utf8("password"));
            await attempt;
        }, launch: new NativeLaunchCredentialInputs(null, Utf8("password"), null));
    }

    [TestMethod]
    public async Task LaunchPasswordFileAnswersPasswordOnlyPromptsAndReportsFailures()
    {
        var root = Path.Combine(Path.GetTempPath(), "tidyvnc-launch-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var file = Path.Combine(root, "passwd");
            await File.WriteAllBytesAsync(file, Obfuscate("password"));
            await Run(async s =>
            {
                Assert.AreEqual(NativeSessionState.Connected, (await s.Attempt(null)).State);
                await s.Disconnect();
                await File.WriteAllBytesAsync(file, [1, 2]);
                var attempt = s.Attempt(null);
                await Until(() => s.Credentials.Notice?.Kind == NativeCredentialNoticeKind.LaunchFailure);
                Assert.AreEqual(NativePasswordFileError.Truncated, s.Credentials.Notice!.FileError);
                Assert.IsNotNull(s.Session.Prompt, "the prompt stays for manual entry");
                s.Credentials.Submit(s.Session.Prompt!, [], Utf8("password"));
                Assert.AreEqual(NativeSessionState.Connected, (await attempt).State);
            }, launch: new NativeLaunchCredentialInputs(null, null, file));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [TestMethod]
    public Task StaleOrClosedRequestsAreRefusedAndStillWipe() => Run(async s =>
    {
        NativePrompt? first = null;
        var attempt = s.Attempt(p => first ??= p);
        await Until(() => first is not null);
        await s.Session.DisconnectAsync();
        await attempt;
        var password = Utf8("password");
        Assert.ThrowsExactly<NativeError>(() => s.Credentials.Submit(first!, [], password));
        Assert.IsTrue(password.All(b => b == 0));
        s.Credentials.UseSaved(first!, "");
        Assert.AreEqual(NativeCredentialNoticeKind.RequestUnavailable, s.Credentials.Notice?.Kind);
        Assert.IsFalse(s.Credentials.CanUseSession(first!, ""));
    });
}
