// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using TidyVNC.Native.Tunnel;
using TidyVNC.Testing;

namespace TidyVNC.Native.Tests;

/// <summary>
/// SSH gateway tunnels (plans/native-ui-winui TODO W4.9, SERVICES.md
/// section 11, D17) with the real Windows OpenSSH client, the real askpass
/// helper and the in-process SshTestServer: routed RFB sessions, native
/// prompts, typed failures, configuration admission, deadlines and cleanup.
/// Nothing touches the user's ssh configuration or known_hosts.
/// </summary>
[TestClass]
public sealed class TunnelTests
{
    private string root = "", state = "";
    private string KnownHosts => Path.Combine(root, "known_hosts");
    private string Config => Path.Combine(root, "config");

    private static string Askpass => typeof(TunnelTests).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().First(a => a.Key == "TidyVncAskpass").Value!;

    [TestInitialize]
    public void Setup()
    {
        if (NativeSshConfiguration.ClientPath is null) Assert.Inconclusive("Windows OpenSSH client is not installed");
        root = Path.Combine(Path.GetTempPath(), "tidyvnc-tunnel-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        File.WriteAllText(Config, "");
        // Short: AF_UNIX relay paths are limited to 108 bytes.
        state = Path.Combine(Path.GetTempPath(), "tv" + Guid.NewGuid().ToString("N")[..8]);
    }

    [TestCleanup]
    public void Teardown()
    {
        foreach (var directory in new[] { root, state })
            try { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private NativeSshTunnelOptions Options(TimeSpan? startup = null) => new()
    {
        ConfigurationFile = Config, KnownHostsFile = KnownHosts, StateDirectory = state,
        StartupDeadline = startup ?? TimeSpan.FromSeconds(20),
    };

    private void Trust(SshTestServer server) => File.WriteAllText(KnownHosts, $"[127.0.0.1]:{server.Port} {server.KnownHostsKey}\n");

    private static NativeSshGateway Gateway(SshTestServer server, string user = "tester") => NativeSshGateway.Parse($"ssh://{user}@127.0.0.1:{server.Port}");

    private static async Task<NativeSshTunnelError> Failure(Func<Task> body)
    {
        try { await body(); }
        catch (NativeSshTunnelException error) { return error.Error; }
        Assert.Fail("Expected a tunnel failure");
        return default;
    }

    private static async Task Until(Func<bool> condition, int seconds = 15)
    {
        var deadline = Stopwatch.StartNew();
        while (!condition())
        {
            if (deadline.Elapsed > TimeSpan.FromSeconds(seconds)) Assert.Fail("Condition not reached in time");
            await Task.Delay(10);
        }
    }

    private static bool Running(int processId)
    {
        try { using var process = Process.GetProcessById(processId); return !process.HasExited; }
        catch (ArgumentException) { return false; }
    }

    private sealed class ScriptedInteraction(string? password, bool approveHostKey, bool block = false) : INativeSshInteraction
    {
        public List<NativeSshPrompt> Seen { get; } = [];

        public async Task<byte[]?> AnswerAsync(NativeSshPrompt prompt, CancellationToken cancellation)
        {
            lock (Seen) Seen.Add(prompt);
            if (block) await Task.Delay(Timeout.Infinite, cancellation);
            return prompt.Kind switch
            {
                NativeSshPromptKind.HostKey => approveHostKey ? [1] : null,
                NativeSshPromptKind.Secret => password is null ? null : Encoding.UTF8.GetBytes(password),
                _ => null,
            };
        }
    }

    [TestMethod]
    public async Task ARoutedSessionRunsOverTheTunnelAndCloseEndsTheProcessTree()
    {
        await using var server = new SshTestServer();
        await using var peer = new LoopbackPeer();
        Trust(server);
        var tunnel = await NativeSshTunnel.StartAsync(Gateway(server), "127.0.0.1", peer.Port, null, Options());
        StringAssert.StartsWith(tunnel.RouteIdentity, "ssh-v2:");
        Assert.AreEqual("tester", tunnel.Resolved.User);
        Assert.AreEqual(server.Port, tunnel.Resolved.Port);
        Assert.IsTrue(Running(tunnel.ProcessId));

        // Another process that reaches the relay first is refused; the app's own connection still works.
        var pwsh = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
        if (File.Exists(pwsh))
        {
            var script = "$s=[Net.Sockets.Socket]::new('Unix','Stream','Unspecified'); $s.Connect([Net.Sockets.UnixDomainSocketEndPoint]::new('" +
                         tunnel.LocalEndpoint + "')); $b=[byte[]]::new(64); $s.ReceiveTimeout=5000; exit $s.Receive($b)";
            var info = new ProcessStartInfo(pwsh) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
            foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-Command", script }) info.ArgumentList.Add(argument);
            using var foreign = Process.Start(info)!;
            await foreign.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
            Assert.AreEqual(0, foreign.ExitCode, "a foreign process receives nothing from the relay");
        }

        using var ui = new SingleThreadDispatcher();
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1] });
            await session.ConnectAsync($"127.0.0.1::{peer.Port}", tunnel.LocalEndpoint, tunnel.RouteIdentity);
            await Until(() => peer.Established && session.Snapshot.State == NativeSessionState.Connected);
            await Until(() => session.HasFrame);
            await session.DisconnectAsync();
            await Until(() => session.Snapshot.State is NativeSessionState.Closed or NativeSessionState.Failed);
            await runtime.ShutdownAsync();
        });
        Assert.AreEqual(1, server.ForwardedChannels);
        Assert.AreEqual($"127.0.0.1:{peer.Port}", server.Targets.Single());
        var id = tunnel.ProcessId;
        await tunnel.DisposeAsync();
        Assert.IsFalse(Running(id), "close ends ssh.exe");
        Assert.IsNull(await tunnel.Ended);
        Assert.AreEqual(0, Directory.EnumerateDirectories(Path.Combine(state, "t")).Count(), "the attempt directory is removed");
    }

    [TestMethod]
    public async Task NativePromptsReviewNewHostKeysAndAnswerPasswords()
    {
        await using var server = new SshTestServer(password: "gateway secret");
        await using var peer = new LoopbackPeer();
        var interaction = new ScriptedInteraction("gateway secret", approveHostKey: true);
        await using (var tunnel = await NativeSshTunnel.StartAsync(Gateway(server), "127.0.0.1", peer.Port, interaction, Options(), Askpass))
        {
            CollectionAssert.AreEqual(new[] { NativeSshPromptKind.HostKey, NativeSshPromptKind.Secret }, interaction.Seen.Select(p => p.Kind).ToArray());
            StringAssert.StartsWith(interaction.Seen[0].HostKey!.Fingerprint, "SHA256:");
            StringAssert.Contains(File.ReadAllText(KnownHosts), server.KnownHostsKey.Split(' ')[1], "OpenSSH saved the reviewed key");
        }

        // Declining a new key or giving a wrong password is typed, and a declined key is never written.
        File.Delete(KnownHosts);
        Assert.AreEqual(NativeSshTunnelError.HostKeyUnknown, await Failure(() =>
            NativeSshTunnel.StartAsync(Gateway(server), "127.0.0.1", peer.Port, new ScriptedInteraction("gateway secret", false), Options(), Askpass)));
        Assert.IsFalse(File.Exists(KnownHosts) && File.ReadAllText(KnownHosts).Contains(server.KnownHostsKey.Split(' ')[1], StringComparison.Ordinal));
        Trust(server);
        Assert.AreEqual(NativeSshTunnelError.AuthenticationFailed, await Failure(() =>
            NativeSshTunnel.StartAsync(Gateway(server), "127.0.0.1", peer.Port, new ScriptedInteraction("wrong", true), Options(), Askpass)));
    }

    [TestMethod]
    public async Task WithoutInteractionUnknownKeysAndPasswordsFailClosed()
    {
        await using var server = new SshTestServer();
        await using var peer = new LoopbackPeer();
        Assert.AreEqual(NativeSshTunnelError.HostKeyUnknown, await Failure(() => NativeSshTunnel.StartAsync(Gateway(server), "127.0.0.1", peer.Port, null, Options())));
        Assert.IsFalse(File.Exists(KnownHosts), "batch mode never writes known_hosts");

        await using var passworded = new SshTestServer(password: "x");
        File.WriteAllText(KnownHosts, $"[127.0.0.1]:{passworded.Port} {passworded.KnownHostsKey}\n");
        Assert.AreEqual(NativeSshTunnelError.AuthenticationFailed, await Failure(() => NativeSshTunnel.StartAsync(Gateway(passworded), "127.0.0.1", peer.Port, null, Options())));

        // A forward to a closed port fails typed after authentication.
        Trust(server);
        var closed = new TcpListener(IPAddress.Loopback, 0);
        closed.Start();
        var port = ((IPEndPoint)closed.LocalEndpoint).Port;
        closed.Stop();
        Assert.AreEqual(NativeSshTunnelError.ForwardingFailed, await Failure(() => NativeSshTunnel.StartAsync(Gateway(server), "127.0.0.1", port, null, Options())));
    }

    [TestMethod]
    public async Task ConfigurationIsResolvedFromAPrivateSnapshotAndCommandsAreRefused()
    {
        await using var server = new SshTestServer();
        await using var peer = new RfbTestServer(width: 8, height: 8); // Serves every tunnel in this test.
        Trust(server);
        File.WriteAllText(Config, $"Host desk-gateway\n  HostName 127.0.0.1\n  Port {server.Port}\n  User configured\n\nHost other\n  ProxyCommand evil %h\n");
        var alias = NativeSshGateway.Parse("desk-gateway");
        await using (var tunnel = await NativeSshTunnel.StartAsync(alias, "127.0.0.1", peer.Port, null, Options()))
        {
            Assert.AreEqual("127.0.0.1", tunnel.Resolved.HostName);
            Assert.AreEqual("configured", tunnel.Resolved.User);
            Assert.AreEqual(server.Port, tunnel.Resolved.Port);
            Assert.AreEqual(NativeIdentity.SshResolved("127.0.0.1", "configured", (uint)server.Port), tunnel.RouteIdentity);
        }
        await using (var tunnel = await NativeSshTunnel.StartAsync(NativeSshGateway.Parse($"ssh://explicit@desk-gateway"), "127.0.0.1", peer.Port, null, Options()))
            Assert.AreEqual("explicit", tunnel.Resolved.User, "an explicit user wins over the configuration");

        foreach (var refused in new[]
                 {
                     "Include other.conf\n",
                     $"Match exec \"whoami\"\n  Port {server.Port}\n",
                     "Match localnetwork 10.0.0.0/8\n  User x\n",
                     $"Host desk-gateway\n  HostName 127.0.0.1\n  Port {server.Port}\n  ProxyCommand evil %h\n",
                     $"Host desk-gateway\n  HostName 127.0.0.1\n  Port {server.Port}\n  ProxyJump elsewhere\n",
                     $"Host desk-gateway\n  HostName 127.0.0.1\n  Port {server.Port}\n  LocalForward 5000 127.0.0.1:22\n",
                 })
        {
            File.WriteAllText(Config, refused);
            Assert.AreEqual(NativeSshTunnelError.UnsupportedConfiguration, await Failure(() => NativeSshTunnel.StartAsync(alias, "127.0.0.1", peer.Port, null, Options())), refused);
        }
        Assert.AreEqual(0, server.Authenticated - 2, "refused configurations never reach the gateway");

        File.Delete(Config);
        Trust(server);
        await using (var direct = await NativeSshTunnel.StartAsync(Gateway(server), "127.0.0.1", peer.Port, null, Options()))
            Assert.AreEqual("tester", direct.Resolved.User, "an absent configuration is an empty one");
        Assert.IsFalse(File.Exists(Config), "the configuration is never created");
    }

    [TestMethod]
    public async Task DeadlinesCancellationAndBadTargetsAreTyped()
    {
        // A "gateway" that accepts TCP and never speaks SSH.
        var silent = new TcpListener(IPAddress.Loopback, 0);
        silent.Start();
        var accepted = new List<TcpClient>();
        _ = Task.Run(async () => { try { while (true) accepted.Add(await silent.AcceptTcpClientAsync()); } catch (Exception) { } });
        try
        {
            var gateway = NativeSshGateway.Parse($"ssh://tester@127.0.0.1:{((IPEndPoint)silent.LocalEndpoint).Port}");
            var clock = Stopwatch.StartNew();
            Assert.AreEqual(NativeSshTunnelError.Timeout, await Failure(() => NativeSshTunnel.StartAsync(gateway, "127.0.0.1", 5900, null, Options(TimeSpan.FromSeconds(2)))));
            Assert.IsTrue(clock.Elapsed < TimeSpan.FromSeconds(10));

            using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
            Assert.AreEqual(NativeSshTunnelError.Cancelled, await Failure(() => NativeSshTunnel.StartAsync(gateway, "127.0.0.1", 5900, null, Options(), cancellation: cancel.Token)));
        }
        finally
        {
            silent.Stop();
            foreach (var client in accepted) client.Dispose();
        }
        foreach (var target in new[] { "evil%h", "two words", "a@b", "" })
            Assert.AreEqual(NativeSshTunnelError.ForwardingFailed, await Failure(() => NativeSshTunnel.StartAsync(NativeSshGateway.Parse("gateway.example"), target, 5900, null, Options())));
    }

    [TestMethod]
    public async Task CancellingDuringAPromptEndsTheHelperToo()
    {
        await using var server = new SshTestServer(password: "secret");
        Trust(server);
        var interaction = new ScriptedInteraction("secret", true, block: true);
        using var cancel = new CancellationTokenSource();
        var start = NativeSshTunnel.StartAsync(Gateway(server), "127.0.0.1", 5900, interaction, Options(), Askpass, cancel.Token);
        await Until(() => { lock (interaction.Seen) return interaction.Seen.Count == 1; });
        var helpers = Process.GetProcessesByName("tidyvnc-ssh-askpass").Select(p => p.Id).ToList();
        Assert.IsTrue(helpers.Count > 0, "the helper is waiting on the prompt");
        await cancel.CancelAsync();
        Assert.AreEqual(NativeSshTunnelError.Cancelled, await Failure(() => start));
        await Until(() => helpers.All(id => !Running(id)), 10);
    }
}
