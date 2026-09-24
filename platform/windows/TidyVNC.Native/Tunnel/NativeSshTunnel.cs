// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Globalization;
using System.Net.Sockets;
using System.Text;

namespace TidyVNC.Native.Tunnel;

/// <summary>
/// One SSH gateway attempt (SERVICES.md section 11, DECISIONS.md D17; the
/// macOS NativeConfiguredSSHTunnel). Windows OpenSSH has no ControlMaster,
/// so the tunnel runs <c>ssh -W target:port</c> and relays its standard
/// streams to a private AF_UNIX socket that the core's routed connect uses
/// (no TCP port is ever listened on). The owner:
/// <list type="bullet">
/// <item>prepares an immutable configuration snapshot and the effective
/// gateway before starting anything that can authenticate;</item>
/// <item>starts ssh.exe with explicit arguments and a restricted environment
/// inside a kill-on-close Job Object, with native prompts through the
/// askpass helper when an interaction is supplied (BatchMode otherwise);</item>
/// <item>treats the first bytes from the remote RFB server as readiness,
/// within 20 seconds without prompts or five minutes with them;</item>
/// <item>accepts exactly one relay connection, from this process;</item>
/// <item>reports typed failures from ssh's stderr without keeping its text;</item>
/// <item>closes by ending the relay, then the whole process tree.</item>
/// </list>
/// VNC credentials never reach ssh's arguments or environment.
/// </summary>
public sealed class NativeSshTunnel : IAsyncDisposable
{
    private const int PeerProcessControl = unchecked((int)0x58000100); // SIO_AF_UNIX_GETPEERPID
    private static readonly TimeSpan AcceptDeadline = TimeSpan.FromSeconds(30);

    private readonly string directory;
    private readonly NativeOwnedProcess process;
    private readonly NativeSshAskpassServer? askpass;
    private readonly Socket listener;
    private readonly StderrClassifier classifier;
    private readonly byte[] first;
    private readonly CancellationTokenSource closing = new();
    private readonly TaskCompletionSource<NativeSshTunnelError?> ended = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Task? relay;
    private int disposed;

    private NativeSshTunnel(string directory, NativeOwnedProcess process, NativeSshAskpassServer? askpass, Socket listener,
                            StderrClassifier classifier, byte[] first, string localEndpoint, NativeSshResolvedGateway resolved)
    {
        this.directory = directory;
        this.process = process;
        this.askpass = askpass;
        this.listener = listener;
        this.classifier = classifier;
        this.first = first;
        LocalEndpoint = localEndpoint;
        Resolved = resolved;
    }

    /// <summary>The relay socket path to pass to the session's routed connect.</summary>
    public string LocalEndpoint { get; }
    public NativeSshResolvedGateway Resolved { get; }
    /// <summary>The effective route (ssh-v2) that scopes credentials and trust.</summary>
    public string RouteIdentity => Resolved.RouteIdentity;
    /// <summary>Completes when the tunnel ends: null after a normal close, otherwise why ssh ended.</summary>
    public Task<NativeSshTunnelError?> Ended => ended.Task;
    /// <summary>The ssh.exe process id (tests check the tree is gone after close).</summary>
    public int ProcessId => process.Id;

    /// <summary>The askpass helper installed beside the app (tidyvnc-ssh-askpass.exe).</summary>
    public static string DefaultAskpass => Path.Combine(AppContext.BaseDirectory, "tidyvnc-ssh-askpass.exe");

    /// <summary>A target host:port in the form ssh -W accepts; hosts are refused if ssh could reinterpret them.</summary>
    internal static string Target(string host, int port)
    {
        if (host.Length is 0 or > 255 || port is < 1 or > 65535 || host.Any(c => char.IsWhiteSpace(c) || char.IsControl(c) || c is '%' or '"' or '\'' or '[' or ']' or '@'))
            throw new NativeSshTunnelException(NativeSshTunnelError.ForwardingFailed);
        return (host.Contains(':', StringComparison.Ordinal) ? $"[{host}]" : host) + ":" + port.ToString(CultureInfo.InvariantCulture);
    }

    public static async Task<NativeSshTunnel> StartAsync(NativeSshGateway gateway, string targetHost, int targetPort, INativeSshInteraction? interaction,
                                                         NativeSshTunnelOptions? options = null, string? askpassPath = null,
                                                         CancellationToken cancellation = default)
    {
        options ??= new NativeSshTunnelOptions();
        var client = NativeSshConfiguration.ClientPath ?? throw new NativeSshTunnelException(NativeSshTunnelError.ClientMissing);
        var target = Target(targetHost, targetPort);
        askpassPath ??= DefaultAskpass;
        if (interaction is not null && (!File.Exists(askpassPath) || askpassPath.Contains('"', StringComparison.Ordinal)))
            throw new NativeSshTunnelException(NativeSshTunnelError.Failed);
        var directory = NativeSshConfiguration.AttemptDirectory(options.StateDirectory);
        NativeOwnedProcess? process = null;
        NativeSshAskpassServer? askpass = null;
        Socket? listener = null;
        try
        {
            var snapshot = NativeSshConfiguration.Snapshot(options.ConfigurationFile, directory);
            var family = options switch
            {
                { Ipv4: true, Ipv6: false } => new[] { "-4" },
                { Ipv4: false, Ipv6: true } => ["-6"],
                { Ipv4: false, Ipv6: false } => throw new NativeSshTunnelException(NativeSshTunnelError.ConnectionFailed),
                _ => [],
            };
            var resolved = await NativeSshConfiguration.ResolveAsync(client, snapshot, gateway, family, cancellation);

            if (interaction is not null) askpass = new NativeSshAskpassServer(interaction, pid => process?.Contains(pid) == true);
            var arguments = new List<string> { "-F", snapshot };
            void Option(string value) { arguments.Add("-o"); arguments.Add(value); }
            Option("BatchMode=" + (interaction is null ? "yes" : "no"));
            Option("StrictHostKeyChecking=" + (interaction is null ? "yes" : "ask"));
            if (interaction is not null) Option($"KnownHostsCommand=\"{askpassPath}\" --known-hosts %I %H %t %K");
            if (options.KnownHostsFile is { } knownHosts)
            {
                if (knownHosts.Contains('"', StringComparison.Ordinal)) throw new NativeSshTunnelException(NativeSshTunnelError.Failed);
                Option($"UserKnownHostsFile=\"{knownHosts}\"");
                Option("GlobalKnownHostsFile=none");
            }
            foreach (var fixedOption in new[]
                     {
                         "UpdateHostKeys=no", "ClearAllForwardings=yes", "ControlMaster=no", "ControlPath=none", "PermitLocalCommand=no",
                         "ForwardAgent=no", "ForwardX11=no", "RequestTTY=no", "ExitOnForwardFailure=yes", "LogLevel=ERROR",
                         "ConnectTimeout=15", "ServerAliveInterval=30", "ServerAliveCountMax=3", "CanonicalizeHostname=no",
                     })
                Option(fixedOption);
            // The effective route is enforced; the alias stays the destination argument.
            Option("HostName=" + resolved.HostName.Replace("%", "%%", StringComparison.Ordinal));
            if (resolved.HostKeyAlias.Length > 0) Option("HostKeyAlias=" + resolved.HostKeyAlias);
            arguments.AddRange(family);
            arguments.AddRange(["-l", resolved.User, "-p", resolved.Port.ToString(CultureInfo.InvariantCulture), "-W", target, gateway.Host]);

            var environment = NativeSshConfiguration.Environment();
            if (askpass is not null)
            {
                foreach (var (name, value) in askpass.Environment) environment[name] = value;
                environment["SSH_ASKPASS"] = askpassPath;
                environment["SSH_ASKPASS_REQUIRE"] = "force";
            }
            process = NativeOwnedProcess.Start(client, arguments, environment);
            var classifier = new StderrClassifier(process.Error);

            var ready = await ReadyAsync(process, askpass, classifier, options, cancellation);

            // AF_UNIX paths are limited to 108 bytes (sun_path); the attempt path is short by design.
            var endpoint = Path.Combine(directory, "r");
            if (Encoding.UTF8.GetByteCount(endpoint) > 107) throw new NativeSshTunnelException(NativeSshTunnelError.Failed);
            listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            listener.Bind(new UnixDomainSocketEndPoint(endpoint));
            listener.Listen(1);
            var tunnel = new NativeSshTunnel(directory, process, askpass, listener, classifier, ready, endpoint, resolved);
            tunnel.relay = Task.Run(tunnel.RelayAsync, CancellationToken.None);
            return tunnel;
        }
        catch (Exception error)
        {
            listener?.Dispose();
            process?.Dispose();
            if (askpass is not null) await askpass.DisposeAsync();
            RemoveDirectory(directory);
            if (error is NativeSshTunnelException) throw;
            if (error is OperationCanceledException) throw new NativeSshTunnelException(NativeSshTunnelError.Cancelled);
            if (error is NativeProcessException or SocketException or IOException or UnauthorizedAccessException)
                throw new NativeSshTunnelException(NativeSshTunnelError.Failed);
            throw;
        }
    }

    /// <summary>Waits for the first bytes the remote RFB server sends through the forward.</summary>
    private static async Task<byte[]> ReadyAsync(NativeOwnedProcess process, NativeSshAskpassServer? askpass, StderrClassifier classifier,
                                                 NativeSshTunnelOptions options, CancellationToken cancellation)
    {
        var buffer = new byte[4096];
        var read = process.Output.ReadAsync(buffer, CancellationToken.None).AsTask();
        var started = System.Diagnostics.Stopwatch.StartNew();
        while (true)
        {
            var deadline = askpass is { Prompts: > 0 } ? options.InteractiveDeadline : options.StartupDeadline;
            var remaining = deadline - started.Elapsed;
            if (remaining <= TimeSpan.Zero) throw new NativeSshTunnelException(NativeSshTunnelError.Timeout);
            var tick = Task.Delay(remaining < TimeSpan.FromMilliseconds(250) ? remaining : TimeSpan.FromMilliseconds(250), cancellation);
            var done = await Task.WhenAny(read, process.Exited, tick);
            if (cancellation.IsCancellationRequested) throw new NativeSshTunnelException(NativeSshTunnelError.Cancelled);
            if (done == read)
            {
                var count = await read;
                if (count > 0) return buffer[..count];
                await Task.WhenAny(process.Exited, Task.Delay(2000, CancellationToken.None));
                throw new NativeSshTunnelException(await classifier.ErrorAsync() ?? NativeSshTunnelError.ForwardingFailed);
            }
            if (done == process.Exited)
                throw new NativeSshTunnelException(await classifier.ErrorAsync() ?? NativeSshTunnelError.Failed);
        }
    }

    private async Task RelayAsync()
    {
        var token = closing.Token;
        Socket? connection = null;
        NativeSshTunnelError? outcome = null;
        try
        {
            using var acceptDeadline = CancellationTokenSource.CreateLinkedTokenSource(token);
            acceptDeadline.CancelAfter(AcceptDeadline);
            while (connection is null)
            {
                var candidate = await listener.AcceptAsync(acceptDeadline.Token);
                var peer = new byte[4];
                try { candidate.IOControl(PeerProcessControl, null, peer); }
                catch (SocketException) { candidate.Dispose(); continue; }
                // Only this process's core may use the forward.
                if (BitConverter.ToInt32(peer) == Environment.ProcessId) connection = candidate;
                else candidate.Dispose();
            }
            listener.Dispose();
            using var stream = new NetworkStream(connection, ownsSocket: false);
            await stream.WriteAsync(first, token);
            var upstream = Pump(stream, process.Input, token);
            var downstream = Pump(process.Output, stream, token);
            var done = await Task.WhenAny(upstream, downstream, process.Exited);
            if (done == process.Exited || done == downstream) outcome = await classifier.ErrorAsync();
        }
        catch (Exception error) when (error is OperationCanceledException or IOException or SocketException or ObjectDisposedException) { }
        finally
        {
            connection?.Dispose();
            ended.TrySetResult(token.IsCancellationRequested ? null : outcome ?? (process.Exited.IsCompleted ? NativeSshTunnelError.Closed : null));
        }
    }

    private static async Task Pump(Stream from, Stream to, CancellationToken token)
    {
        var buffer = new byte[64 * 1024];
        while (await from.ReadAsync(buffer, token) is var count && count > 0)
        {
            await to.WriteAsync(buffer.AsMemory(0, count), token);
            await to.FlushAsync(token);
        }
    }

    private static void RemoveDirectory(string directory)
    {
        try { Directory.Delete(directory, recursive: true); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>Ends the relay, lets ssh exit briefly, then ends the whole process tree and removes the attempt directory.</summary>
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        await closing.CancelAsync();
        listener.Dispose();
        try { process.Input.Dispose(); } catch (IOException) { }
        await Task.WhenAny(process.Exited, Task.Delay(2000));
        process.Dispose();
        if (relay is not null) await relay;
        if (askpass is not null) await askpass.DisposeAsync();
        await classifier.ErrorAsync();
        RemoveDirectory(directory);
        ended.TrySetResult(null);
        closing.Dispose();
    }

    /// <summary>
    /// Reads ssh's stderr in constant space and keeps only the first typed
    /// failure it recognises; no text is retained or reported.
    /// </summary>
    private sealed class StderrClassifier
    {
        private readonly Task<NativeSshTunnelError?> reading;

        public StderrClassifier(Stream stream) => reading = Task.Run(() => ReadAsync(stream));

        public Task<NativeSshTunnelError?> ErrorAsync() => reading.WaitAsync(TimeSpan.FromSeconds(5)).ContinueWith(t => t.IsCompletedSuccessfully ? t.Result : null, TaskScheduler.Default);

        private static NativeSshTunnelError? Classify(string line)
        {
            if (line.Contains("REMOTE HOST IDENTIFICATION HAS CHANGED", StringComparison.Ordinal) ||
                line.Contains("Host key for", StringComparison.Ordinal) && line.Contains("has changed", StringComparison.Ordinal))
                return NativeSshTunnelError.HostKeyChanged;
            if (line.Contains("Failed to add the host to the list of known hosts", StringComparison.Ordinal)) return NativeSshTunnelError.HostKeySaveFailed;
            if (line.Contains("Host key verification failed", StringComparison.Ordinal) ||
                line.Contains("No ", StringComparison.Ordinal) && line.Contains("host key is known", StringComparison.Ordinal))
                return NativeSshTunnelError.HostKeyUnknown;
            if (line.Contains("Permission denied", StringComparison.Ordinal) || line.Contains("Too many authentication failures", StringComparison.Ordinal))
                return NativeSshTunnelError.AuthenticationFailed;
            if (line.Contains("Could not resolve hostname", StringComparison.Ordinal)) return NativeSshTunnelError.ResolutionFailed;
            if (line.Contains("Connection refused", StringComparison.Ordinal) || line.Contains("timed out", StringComparison.Ordinal) ||
                line.Contains("Network is unreachable", StringComparison.Ordinal) || line.Contains("No route to host", StringComparison.Ordinal) ||
                line.Contains("Connection closed", StringComparison.Ordinal) || line.Contains("Connection reset", StringComparison.Ordinal))
                return NativeSshTunnelError.ConnectionFailed;
            if (line.Contains("open failed", StringComparison.Ordinal) || line.Contains("stdio forwarding failed", StringComparison.Ordinal))
                return NativeSshTunnelError.ForwardingFailed;
            return null;
        }

        private static async Task<NativeSshTunnelError?> ReadAsync(Stream stream)
        {
            NativeSshTunnelError? result = null;
            var line = new StringBuilder();
            var buffer = new byte[4096];
            try
            {
                while (await stream.ReadAsync(buffer) is var count && count > 0)
                {
                    foreach (var b in buffer.AsSpan(0, count))
                    {
                        if (b == '\n')
                        {
                            result ??= Classify(line.ToString());
                            line.Clear();
                        }
                        else if (line.Length < 512) line.Append(b < 0x80 ? (char)b : '?');
                    }
                }
            }
            catch (Exception error) when (error is IOException or ObjectDisposedException) { }
            return result ?? (line.Length > 0 ? Classify(line.ToString()) : null);
        }
    }
}
