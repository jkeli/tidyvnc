// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using System.Text;
using TidyVNC.Native.Documents;
using TidyVNC.Native.Storage;
using TidyVNC.Native.Tunnel;

namespace TidyVNC.Native.Tests;

/// <summary>
/// The connection controller, session defaults and recent history
/// (plans/native-ui-winui TODO W5.1/W5.16), ported from the macOS
/// NativeRecentHistoryTests, NativeInvocationResolutionTests (admission) and
/// ConnectionModel behaviour, with isolated stores and real loopback peers.
/// </summary>
[TestClass]
public sealed class ConnectionTests
{
    private string root = "";

    [TestInitialize]
    public void Setup()
    {
        root = Path.Combine(Path.GetTempPath(), "tidyvnc-connection-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
    }

    [TestCleanup]
    public void Teardown() => Directory.Delete(root, recursive: true);

    private static async Task Until(Func<bool> condition, string label, int seconds = 10)
    {
        var deadline = Stopwatch.StartNew();
        while (!condition())
        {
            if (deadline.Elapsed > TimeSpan.FromSeconds(seconds)) Assert.Fail($"Timed out: {label}");
            await Task.Delay(5);
        }
    }

    private static NativeConnectionDestination Direct(string endpoint) => new(endpoint, null);

    private sealed class Fixture : IAsyncDisposable
    {
        public required SingleThreadDispatcher Ui { get; init; }
        public required NativeRuntime Runtime { get; init; }
        public required NativePreferencesStore Preferences { get; init; }
        public required NativeProfileHistoryStore Profiles { get; init; }
        public required NativeRecentHistory History { get; init; }
        public NativeConnectionServices Services(Func<NativeSshGateway, string, NativeSshInteraction, NativeSessionConfiguration, CancellationToken, Task<INativeTunnel>>? tunnels = null,
                                                 INativeDocumentReader? reader = null, Func<NativeSetupDisplays>? displays = null)
            => new(Runtime, Preferences) { Profiles = Profiles, History = History, TunnelFactory = tunnels, DocumentReader = reader, Displays = displays };

        public async ValueTask DisposeAsync()
        {
            await Ui.InvokeAsync(async () =>
            {
                await History.CloseAsync();
                await Runtime.ShutdownAsync();
            });
            await Preferences.CloseAsync(); await Profiles.CloseAsync();
            Preferences.Dispose(); Profiles.Dispose();
            Ui.Dispose();
        }
    }

    private async Task<Fixture> Create()
    {
        var ui = new SingleThreadDispatcher();
        var runtime = await ui.InvokeAsync(() => new NativeRuntime(ui));
        // The stores create their own private folder; a shared parent folder is refused.
        var state = Path.Combine(root, "state");
        var profiles = new NativeProfileHistoryStore(state);
        return new Fixture
        {
            Ui = ui, Runtime = runtime, Preferences = new NativePreferencesStore(state), Profiles = profiles,
            History = new NativeRecentHistory(ui, profiles),
        };
    }

    private static void AnswerPassword(NativeConnectionController controller, string password = "password")
    {
        controller.SessionReady += session => session.PropertyChanged += (_, change) =>
        {
            if (change.PropertyName == nameof(NativeSession.Prompt) && session.Prompt is { Kind: NativePrompt.PromptKind.Credentials } prompt)
                controller.Credentials.Submit(prompt, [], Encoding.UTF8.GetBytes(password));
        };
    }

    [TestMethod]
    public async Task HistoryOrdersRemovesClearsAndRecoversFromConflicts()
    {
        await using var f = await Create();
        await f.Ui.InvokeAsync(async () =>
        {
            var history = f.History;
            history.Reload();
            await Until(() => !history.IsBusy, "initial read");
            Assert.IsTrue(history.HasLoaded && history.Connections.IsEmpty && history.CanImportHistory);
            Assert.IsFalse(File.Exists(f.Profiles.Path), "an initial read never writes");
            history.RecordSuccessful(Direct("first"));
            history.RecordSuccessful(Direct("second"));
            await Until(() => !history.IsBusy && history.Connections.Length == 2, "records saved");
            CollectionAssert.AreEqual(new[] { "second", "first" }, history.Connections.Select(d => d.Endpoint).ToArray(), "newest first");
            Assert.IsFalse(history.CanImportHistory, "native history is no longer an import candidate");
            var before = await f.Profiles.ReadAsync();
            var profile = new NativeConnectionProfile(Guid.NewGuid(), "Keep", "profile-host", NativeSettings.Empty, null, null);
            var changed = await f.Profiles.UpsertProfileAsync(profile, before.Revision);
            history.Remove(Direct("first"));
            await Until(() => !history.IsBusy, "stale removal");
            Assert.AreEqual(NativeStorageError.Conflict, history.Error);
            Assert.IsFalse(history.CanEdit, "a stale edit needs a reload");
            history.Reload();
            await Until(() => !history.IsBusy, "conflict reload");
            Assert.IsTrue(history.Connections.Contains(Direct("first")), "a reload never replays a removal");
            history.Remove(Direct("first"));
            await Until(() => !history.IsBusy, "remove");
            CollectionAssert.AreEqual(new[] { Direct("second") }, history.Connections.ToArray());
            history.Clear();
            await Until(() => !history.IsBusy, "clear");
            var cleared = await f.Profiles.ReadAsync();
            Assert.IsTrue(history.Connections.IsEmpty);
            CollectionAssert.AreEqual(changed.Value.Profiles.ToArray(), cleared.Value.Profiles.ToArray(), "clearing history keeps profiles");

            // Routes are part of the destination: a gateway entry never becomes a direct one.
            var a = new NativeConnectionDestination("remote.invalid", NativeSshGateway.Parse("alice@gateway.invalid"));
            var b = a with { SshGateway = NativeSshGateway.Parse("bob@gateway.invalid") };
            history.RecordSuccessful(a); history.RecordSuccessful(b); history.RecordSuccessful(Direct("remote.invalid")); history.RecordSuccessful(a);
            await Until(() => !history.IsBusy && history.Connections.Length == 3, "routes");
            CollectionAssert.AreEqual(new[] { a, Direct("remote.invalid"), b }, history.Connections.ToArray());
            history.Remove(a);
            await Until(() => !history.IsBusy && history.Connections.Length == 2, "route removed");
            CollectionAssert.AreEqual(new[] { Direct("remote.invalid"), b }, history.Connections.ToArray());

            // Only the latest 20 are kept.
            for (var i = 0; i < 25; i++) history.RecordSuccessful(Direct($"host{i}"));
            await Until(() => !history.IsBusy && history.Connections.Length == 20 && history.Connections[0].Endpoint == "host24", "capacity");
            Assert.IsFalse(history.Connections.Contains(Direct("host4")));

            // Corrupt data is never shown as current.
            await File.WriteAllTextAsync(f.Profiles.Path, "{");
            history.Reload();
            await Until(() => !history.IsBusy, "corrupt read");
            Assert.AreEqual(NativeStorageError.Corrupt, history.Error);
            Assert.IsTrue(history.Connections.IsEmpty && !history.HasLoaded);
        });
    }

    [TestMethod]
    public async Task OnlySuccessfulConnectionsEnterHistoryAndWindowsStayIndependent()
    {
        await using var f = await Create();
        await using var peer = new LoopbackPeer();
        await using var auth = new LoopbackPeer(authentication: true);
        await f.Ui.InvokeAsync(async () =>
        {
            f.History.Reload();
            using var first = new NativeConnectionController(f.Services());
            using var second = new NativeConnectionController(f.Services());
            await Until(() => first.Defaults.IsReady && second.Defaults.IsReady, "defaults");
            Assert.IsFalse(first.CanConnect, "an empty address cannot connect");
            Assert.AreEqual(NativeEndpointIssue.Required, first.EndpointIssue);
            first.Endpoint = peer.Endpoint;
            Assert.IsTrue(first.CanConnect);
            first.Connect();
            Assert.IsTrue(first.Busy && !first.CanConnect && !first.CanEditDestination);
            await Until(() => !first.Busy && !f.History.IsBusy && f.History.Connections.Length == 1, "successful history");
            Assert.AreEqual(NativeSessionState.Connected, first.Session!.Snapshot.State);
            Assert.IsNull(first.Message);
            CollectionAssert.AreEqual(new[] { Direct(peer.Endpoint) }, f.History.Connections.ToArray());

            second.Endpoint = "host::99999";
            Assert.IsNotNull(second.EndpointIssue);
            second.Connect();
            Assert.IsFalse(second.Busy, "an invalid address never starts");
            second.Endpoint = auth.Endpoint;
            second.Connect();
            await Until(() => second.Session!.Prompt is not null, "authentication");
            second.Cancel();
            await Until(() => !second.Busy, "cancelled");
            Assert.IsNull(second.ConnectionProblem, "a cancelled attempt is not a problem");
            await Until(() => !f.History.IsBusy, "history idle");
            CollectionAssert.AreEqual(new[] { Direct(peer.Endpoint) }, f.History.Connections.ToArray(), "cancelled attempts never enter history");
            Assert.AreEqual(peer.Endpoint, first.Endpoint, "another window's field is untouched");

            first.Disconnect();
            await Until(() => !first.Busy && first.Session.Snapshot.State != NativeSessionState.Connected, "disconnect");
            Assert.IsNull(first.ConnectionProblem, "an explicit disconnect is not a problem");
            await first.CloseAsync(); await second.CloseAsync();
            Assert.IsTrue(first.Closing && !first.CanConnect);
        });
    }

    [TestMethod]
    public async Task ProblemsOfferRetryOnlyWhenAllowed()
    {
        await using var f = await Create();
        await f.Ui.InvokeAsync(async () =>
        {
            // A refused port: a reconnectable problem, reported once, with Retry.
            var refused = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
            refused.Start();
            var port = ((System.Net.IPEndPoint)refused.LocalEndpoint).Port;
            refused.Stop();
            using var controller = new NativeConnectionController(f.Services());
            await Until(() => controller.Defaults.IsReady, "defaults");
            controller.Endpoint = $"127.0.0.1::{port}";
            controller.Connect();
            await Until(() => !controller.Busy, "refused");
            var problem = controller.ConnectionProblem!;
            Assert.AreEqual(NativeConnectionIssue.Refused, problem.Issue);
            Assert.IsTrue(controller.OffersRetry(problem) && controller.CanRetry(problem));
            controller.HideProblem(problem.Id);
            Assert.IsNull(controller.ConnectionProblem);
            Assert.IsTrue(controller.CanRetry(problem), "hiding keeps the retry intent");
            controller.Endpoint = "127.0.0.1::1";
            Assert.IsFalse(controller.CanRetry(problem), "an edited address is a new destination, not a retry");
            controller.Endpoint = $"127.0.0.1::{port}";
            controller.DismissProblem(problem.Id);
            Assert.IsFalse(controller.CanRetry(problem), "Cancel revokes the retry");
            controller.Connect();
            await Until(() => !controller.Busy, "second refusal");
            var again = controller.ConnectionProblem!;
            Assert.AreNotEqual(problem.Id, again.Id);
            controller.Retry(again);
            Assert.IsTrue(controller.Busy, "Retry connects the same destination");
            await Until(() => !controller.Busy, "retried");
            await controller.CloseAsync();

            // ReconnectOnError=off: problems show without Retry.
            using var noRetry = new NativeConnectionController(f.Services(), new NativeConnectionRequest
            {
                Invocation = new NativeInvocationLayer(NativeInvocation.Parse(["-ReconnectOnError=off"]), $"127.0.0.1::{port}", root),
            });
            await Until(() => noRetry.Defaults.IsReady, "cli defaults");
            Assert.AreEqual($"127.0.0.1::{port}", noRetry.Endpoint, "the command-line address is installed");
            noRetry.Connect();
            await Until(() => !noRetry.Busy && noRetry.ConnectionProblem is not null, "no retry problem");
            Assert.IsFalse(noRetry.OffersRetry(noRetry.ConnectionProblem!));
            await noRetry.CloseAsync();

            // AlertOnFatalError=off with no Retry available: the window closes instead of alerting.
            using var silent = new NativeConnectionController(f.Services(), new NativeConnectionRequest
            {
                Invocation = new NativeInvocationLayer(NativeInvocation.Parse(["-AlertOnFatalError=off", "-ReconnectOnError=off"]), $"127.0.0.1::{port}", root),
                ConnectOnReady = true,
            });
            await Until(() => silent.ClosesAfterFailure, "silent close");
            Assert.IsTrue(silent.Closing);
            Assert.IsNull(silent.ConnectionProblem);
            await silent.CloseAsync();
        });
    }

    /// <summary>
    /// W5.16 / E01, E02: a name that does not resolve and a server that disappears mid-session end the
    /// attempt with their own typed problem, each with its message, and Retry where reconnecting helps.
    /// </summary>
    [TestMethod]
    public async Task NameFailuresAndVanishingServersAreTypedProblems()
    {
        await using var f = await Create();
        await using var peer = new LoopbackPeer();
        await f.Ui.InvokeAsync(async () =>
        {
            using var unresolved = new NativeConnectionController(f.Services());
            await Until(() => unresolved.Defaults.IsReady, "defaults");
            unresolved.Endpoint = "no-such-host.invalid::1";
            unresolved.Connect();
            await Until(() => !unresolved.Busy && unresolved.ConnectionProblem is not null, "the resolution failure", 30);
            Assert.IsTrue(unresolved.ConnectionProblem!.Issue is NativeConnectionIssue.Resolution or NativeConnectionIssue.ResolutionTimeout,
                $"issue {unresolved.ConnectionProblem.Issue}");
            StringAssert.StartsWith(unresolved.ConnectionProblem.Issue.Message().Key, "connection.issue.resolution");
            await unresolved.CloseAsync();

            using var vanishing = new NativeConnectionController(f.Services());
            await Until(() => vanishing.Defaults.IsReady, "defaults");
            vanishing.Endpoint = peer.Endpoint;
            vanishing.Connect();
            await Until(() => vanishing.Session?.Snapshot.State == NativeSessionState.Connected, "connected");
            peer.Drop();
            await Until(() => vanishing.ConnectionProblem is not null, "the dropped connection");
            var problem = vanishing.ConnectionProblem!;
            Assert.IsTrue(problem.Issue is NativeConnectionIssue.PeerClosed or NativeConnectionIssue.Transport or NativeConnectionIssue.Connection,
                $"issue {problem.Issue}");
            Assert.IsTrue(vanishing.OffersRetry(problem), "a vanished server can be retried");
            StringAssert.StartsWith(problem.Issue.Message().Key, "connection.issue.");
            await vanishing.CloseAsync();
        });
    }

    /// <summary>A stand-in tunnel whose relay is a loopback peer (the routed connect accepts a loopback TCP relay).</summary>
    private sealed class FailingTunnel(NativeSshTunnelError error, string relay) : INativeTunnel
    {
        private readonly TaskCompletionSource<NativeSshTunnelError?> ended = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public string LocalEndpoint => relay;
        public string RouteIdentity => "ssh-v2:fixture";
        public Task<NativeSshTunnelError?> Ended => ended.Task;
        public bool Disposed { get; private set; }
        public void End() => ended.TrySetResult(error);
        public ValueTask DisposeAsync() { Disposed = true; ended.TrySetResult(null); return ValueTask.CompletedTask; }
    }

    [TestMethod]
    public async Task GatewayAttemptsReportTunnelFailures()
    {
        await using var f = await Create();
        await f.Ui.InvokeAsync(async () =>
        {
            var starts = 0;
            using var controller = new NativeConnectionController(f.Services(tunnels: (gateway, endpoint, interaction, configuration, token) =>
            {
                starts++;
                Assert.AreEqual(NativeSshGateway.Parse("alice@gateway.invalid").CanonicalUri, gateway.CanonicalUri);
                Assert.AreEqual("remote.invalid::5901", endpoint);
                throw new NativeSshTunnelException(NativeSshTunnelError.ClientMissing);
            }));
            await Until(() => controller.Defaults.IsReady, "defaults");
            controller.Endpoint = "remote.invalid::5901";
            controller.SshGatewayText = "bad gateway with spaces@";
            Assert.IsNotNull(controller.GatewayIssue);
            Assert.IsFalse(controller.CanConnect, "an invalid gateway blocks Connect");
            controller.SshGatewayText = "alice@gateway.invalid";
            Assert.IsNull(controller.GatewayIssue);
            controller.Endpoint = "/tmp/vnc.sock";
            Assert.IsNull(controller.EndpointIssue);
            Assert.AreEqual(NativeTunnelTexts.UnsupportedTarget, controller.GatewayIssue, "a Unix socket cannot be forwarded");
            controller.Endpoint = "remote.invalid::5901";
            controller.Connect();
            await Until(() => !controller.Busy, "tunnel failure");
            Assert.AreEqual(1, starts);
            Assert.AreEqual(NativeTunnelTexts.Text(NativeSshTunnelError.ClientMissing), controller.Message);
            Assert.IsNull(controller.ConnectionProblem, "tunnel failures are fatal messages, not Retry problems");
            Assert.IsTrue(controller.CanConnect, "the window can try again after an explicit edit or Connect");
            await controller.CloseAsync();

            // A tunnel that exits while authentication is pending cancels the attempt with the tunnel message.
            await using var peer = new LoopbackPeer(authentication: true);
            FailingTunnel? running = null;
            using var ending = new NativeConnectionController(f.Services(tunnels: (_, _, _, _, _) =>
                Task.FromResult<INativeTunnel>(running = new FailingTunnel(NativeSshTunnelError.ConnectionFailed, peer.Endpoint))));
            await Until(() => ending.Defaults.IsReady, "defaults");
            ending.Endpoint = "remote.invalid::5901";
            ending.SshGatewayText = "gateway.invalid";
            ending.Connect();
            await Until(() => ending.Session!.Prompt is not null, "authentication through the tunnel");
            running!.End();
            await Until(() => !ending.Busy, "tunnel ended");
            Assert.AreEqual(new NativeText("connection.recovery.the.ssh.tunnel.closed.check.the.gateway.and.connect.again"), ending.Message);
            Assert.IsNull(ending.ConnectionProblem, "the cancelled attempt adds no second problem");
            Assert.IsNull(ending.Session!.Prompt, "the pending prompt is withdrawn");
            Assert.IsTrue(running.Disposed, "the attempt's tunnel is always closed");
            await ending.CloseAsync();
        });
    }

    private sealed class MemoryReader(string text) : INativeDocumentReader
    {
        public int Reads { get; private set; }
        public Task<byte[]> ReadAsync(string path, CancellationToken cancellation)
        {
            Reads++;
            return Task.FromResult(Encoding.UTF8.GetBytes("TidyVNC Configuration file Version 1.0\n" + text));
        }
    }

    [TestMethod]
    public async Task DefaultsInstallProfilesCommandLinesAndReviewedFiles()
    {
        await using var f = await Create();
        await f.Ui.InvokeAsync(async () =>
        {
            var stored = await f.Preferences.CommitAsync(new NativePreferencesRecord(
                NativeSettings.Create([KeyValuePair.Create("SendClipboard", "off"), KeyValuePair.Create("Shared", "on")]), NativeImportOrigin.None), null);
            var profile = new NativeConnectionProfile(Guid.NewGuid(), "Fixture", "profile.invalid",
                NativeSettings.Create([KeyValuePair.Create("Shared", "off"), KeyValuePair.Create("ReconnectOnError", "off")]),
                NativeSshGateway.Parse("gateway.invalid"), null);
            await f.Profiles.UpsertProfileAsync(profile, null);
            var preferencesWrite = File.GetLastWriteTimeUtc(f.Preferences.Path);

            // Profile: its address, gateway and settings over app defaults.
            using var fromProfile = new NativeConnectionController(f.Services(), new NativeConnectionRequest { ProfileId = profile.Id });
            await Until(() => fromProfile.Defaults.IsReady, "profile defaults");
            Assert.AreEqual(("profile.invalid", profile.SshGateway!.CanonicalUri), (fromProfile.Endpoint, fromProfile.SshGatewayText));
            Assert.IsFalse(fromProfile.Session!.InitialShared || fromProfile.Session.InitialReconnectOnError);
            Assert.IsFalse(fromProfile.Session.ClipboardSendEnabled, "app defaults inherited");
            Assert.AreEqual(NativeSessionState.Idle, fromProfile.Session.Snapshot.State, "loading never connects");
            await fromProfile.CloseAsync();

            // A missing profile is a profile error, not an app-defaults error.
            using var missing = new NativeConnectionController(f.Services(), new NativeConnectionRequest { ProfileId = Guid.NewGuid() });
            await Until(() => !missing.Defaults.IsLoading, "missing profile");
            Assert.AreEqual(NativeStorageError.NotFound, missing.Defaults.ProfileError);
            Assert.IsNull(missing.Session);
            await missing.CloseAsync();

            // Command line over profile: the operand wins, AlertOnFatalError stays launch policy.
            using var cli = new NativeConnectionController(f.Services(), new NativeConnectionRequest
            {
                ProfileId = profile.Id,
                Invocation = new NativeInvocationLayer(NativeInvocation.Parse(["-Shared=on", "-via="]), "cli.invalid", root),
            });
            await Until(() => cli.Defaults.IsReady, "cli defaults");
            Assert.AreEqual(("cli.invalid", ""), (cli.Endpoint, cli.SshGatewayText), "an empty via selects a direct connection");
            Assert.IsTrue(cli.Session!.InitialShared);
            await cli.CloseAsync();

            // An invalid command line fails before any file IO.
            var reader = new MemoryReader("ServerName=file.invalid\nShared=off\nFuture=1\nFullScreenMode=Selected\nFullScreenSelectedMonitors=2");
            using var invalid = new NativeConnectionController(f.Services(reader: reader), new NativeConnectionRequest
            {
                Invocation = new NativeInvocationLayer(NativeInvocation.Parse(["-via=bad gateway@"]), "", root),
                Document = new NativeDocumentOpenRequest(Guid.NewGuid(), Path.Combine(root, "fixture.tidyvnc"), root),
            });
            await Until(() => !invalid.Defaults.IsLoading, "invalid cli");
            Assert.IsNotNull(invalid.Defaults.InvocationIssue);
            Assert.AreEqual(0, reader.Reads, "no file IO after an invalid command line");
            await invalid.CloseAsync();

            // A file: monitor mapping, review with its ignored field, then the session.
            var displays = new NativeSetupDisplays(["one"], ["one", "two"]);
            using var file = new NativeConnectionController(f.Services(reader: reader, displays: () => displays), new NativeConnectionRequest
            {
                Invocation = new NativeInvocationLayer(NativeInvocation.Parse(["-Shared=on"]), "", root),
                Document = new NativeDocumentOpenRequest(Guid.NewGuid(), Path.Combine(root, "fixture.tidyvnc"), root),
            });
            await Until(() => file.Defaults.MonitorMapping is not null, "file mapping");
            var mapping = file.Defaults.MonitorMapping!;
            CollectionAssert.AreEqual(new[] { 2 }, mapping.Numbers.ToArray());
            Assert.AreEqual(0, mapping.Suggested.Count, "monitor 2 has no legacy display");
            file.Defaults.ResolveMapping(mapping.Id, new Dictionary<int, string> { [2] = "gone" });
            Assert.IsNotNull(file.Defaults.DocumentIssue, "every number needs a connected display");
            file.Defaults.ResolveMapping(mapping.Id, new Dictionary<int, string> { [2] = "two" });
            var review = file.Defaults.DocumentReview!;
            Assert.AreEqual("Future", review.Setup.Notices.Single().Name);
            Assert.IsNull(file.Session, "nothing is created before review");
            file.Defaults.EditDocumentMapping(review.Id);
            var edited = file.Defaults.MonitorMapping!;
            Assert.AreEqual("two", edited.Suggested[2], "editing keeps the chosen display");
            file.Defaults.ResolveMapping(edited.Id, new Dictionary<int, string> { [2] = "two" });
            file.Defaults.AcceptDocument(file.Defaults.DocumentReview!.Id);
            await Until(() => file.Defaults.IsReady, "file accepted");
            Assert.AreEqual("file.invalid", file.Endpoint);
            Assert.IsFalse(file.Session!.InitialShared, "the file wins over the command line");
            CollectionAssert.AreEqual(new[] { "two" }, file.Session.InitialFullscreenPolicy.SelectedDisplays.ToArray());
            Assert.AreEqual(NativeSessionState.Idle, file.Session.Snapshot.State, "a reviewed file never connects by itself");
            await file.CloseAsync();

            // A cancelled review leaves no session.
            using var cancelled = new NativeConnectionController(f.Services(reader: new MemoryReader("ServerName=x.invalid\nFuture=1")),
                new NativeConnectionRequest { Document = new NativeDocumentOpenRequest(Guid.NewGuid(), Path.Combine(root, "c.tidyvnc"), root) });
            await Until(() => cancelled.Defaults.DocumentReview is not null, "review");
            cancelled.Defaults.CancelDocument(cancelled.Defaults.DocumentReview!.Id);
            Assert.AreEqual(NativeDocumentTexts.Cancelled, cancelled.Defaults.DocumentIssue);
            Assert.IsNull(cancelled.Session);
            await cancelled.CloseAsync();

            Assert.AreEqual(preferencesWrite, File.GetLastWriteTimeUtc(f.Preferences.Path), "launch layers never persist");
            Assert.IsNotNull(stored.Revision);
        });
    }

    [TestMethod]
    public async Task ConnectOnReadyIsRevokedByAnEditAndCloseDrainsEverything()
    {
        await using var f = await Create();
        await using var peer = new LoopbackPeer(authentication: true);
        await f.Ui.InvokeAsync(async () =>
        {
            using var controller = new NativeConnectionController(f.Services(), new NativeConnectionRequest
            {
                Invocation = new NativeInvocationLayer(NativeInvocation.Parse([]), peer.Endpoint, root),
                ConnectOnReady = true,
            });
            // The scheduled connect runs after admission; an edit in between revokes it.
            controller.SessionReady += _ => controller.Endpoint = "other.invalid";
            await Until(() => controller.Defaults.IsReady, "defaults");
            await Task.Delay(50);
            Assert.IsFalse(controller.Busy, "an intervening edit revokes the automatic connect");

            using var automatic = new NativeConnectionController(f.Services(), new NativeConnectionRequest
            {
                Invocation = new NativeInvocationLayer(NativeInvocation.Parse([]), peer.Endpoint, root),
                ConnectOnReady = true,
            });
            await Until(() => automatic.Session?.Prompt is not null, "automatic connect reaches authentication");
            Assert.AreEqual(peer.Endpoint, automatic.AttemptEndpoint);
            // Closing during authentication dismisses the prompt and drains the session.
            await automatic.CloseAsync();
            Assert.IsTrue(automatic.Session!.IsClosing);
            Assert.IsNull(automatic.Session.Prompt);
            Assert.IsFalse(automatic.CanConnect);
            await controller.CloseAsync();
        });
    }
}
