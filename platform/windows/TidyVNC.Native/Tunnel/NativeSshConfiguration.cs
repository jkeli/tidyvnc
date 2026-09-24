// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Globalization;
using System.Text;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native.Tunnel;

public enum NativeSshTunnelError
{
    /// <summary>ssh.exe is not installed (Settings &gt; System &gt; Optional features &gt; OpenSSH Client).</summary>
    ClientMissing,
    /// <summary>The SSH configuration uses something the viewer does not run (Include, Match exec, proxy or command directives, forwards).</summary>
    UnsupportedConfiguration,
    ConfigurationFailed,
    HostKeyUnknown,
    HostKeyChanged,
    HostKeySaveFailed,
    AuthenticationFailed,
    ResolutionFailed,
    ConnectionFailed,
    ForwardingFailed,
    Timeout,
    Cancelled,
    Closed,
    Failed,
}

public sealed class NativeSshTunnelException(NativeSshTunnelError error) : Exception($"SSH gateway: {error}")
{
    public NativeSshTunnelError Error { get; } = error;
}

/// <summary>Where the tunnel reads SSH configuration and known hosts (tests substitute private files).</summary>
public sealed record NativeSshTunnelOptions
{
    /// <summary>The user's configuration; null uses %USERPROFILE%\.ssh\config (absent is fine; it is never created).</summary>
    public string? ConfigurationFile { get; init; }
    /// <summary>Null keeps OpenSSH's own known_hosts files.</summary>
    public string? KnownHostsFile { get; init; }
    public bool Ipv4 { get; init; } = true;
    public bool Ipv6 { get; init; } = true;
    /// <summary>Without interaction (BatchMode); with native prompts (askpass).</summary>
    public TimeSpan StartupDeadline { get; init; } = TimeSpan.FromSeconds(20);
    public TimeSpan InteractiveDeadline { get; init; } = TimeSpan.FromMinutes(5);
    /// <summary>The per-user state root; attempts use private directories below it.</summary>
    public string? StateDirectory { get; init; }
}

/// <summary>
/// The effective gateway after OpenSSH evaluated the admitted configuration
/// snapshot (SSH-CONFIGURATION.md): host, user, port and an optional literal
/// HostKeyAlias. RouteIdentity (ssh-v2) scopes VNC credentials and trust.
/// </summary>
public sealed record NativeSshResolvedGateway(string HostName, string User, int Port, string HostKeyAlias)
{
    public string RouteIdentity => NativeIdentity.SshResolved(HostName, User, (uint)Port, HostKeyAlias);
    public override string ToString() => "NativeSshResolvedGateway(<redacted>)";
}

/// <summary>
/// Configuration admission: the user's ssh config is copied once into the
/// attempt's private directory, checked lexically (Include, Match exec and
/// Match localnetwork are refused before OpenSSH evaluates anything, since
/// evaluation would run them), then evaluated by <c>ssh -G</c> against that
/// immutable snapshot. Effective proxy, command and forwarding directives
/// are refused visibly; the connection later uses the same snapshot.
/// </summary>
public static class NativeSshConfiguration
{
    public const int MaximumBytes = 256 * 1024;
    /// <summary>
    /// Refused before evaluation: Include is not supported yet (its files
    /// would escape the snapshot), and Match exec/localnetwork would run or
    /// change during evaluation. Everything else is judged on the effective
    /// values <c>ssh -G</c> reports for this gateway, so directives for other
    /// hosts do not block it.
    /// </summary>
    private static readonly string[] Refused = ["include"];

    public static string? ClientPath
    {
        get
        {
            var path = Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.Windows), "System32", "OpenSSH", "ssh.exe");
            return File.Exists(path) ? path : null;
        }
    }

    /// <summary>The environment ssh.exe runs with: system and profile locations only, plus the named agent socket.</summary>
    internal static Dictionary<string, string> Environment()
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        // ssh.exe exits 255 without ProgramData (its global ssh_config lives there).
        foreach (var name in new[]
                 {
                     "SystemRoot", "windir", "SystemDrive", "USERPROFILE", "HOMEDRIVE", "HOMEPATH", "USERNAME", "USERDOMAIN",
                     "LOCALAPPDATA", "APPDATA", "TEMP", "TMP", "COMPUTERNAME", "ProgramData", "ALLUSERSPROFILE", "SSH_AUTH_SOCK",
                 })
            if (System.Environment.GetEnvironmentVariable(name) is { Length: > 0 } value) result[name] = value;
        var system = System.Environment.GetFolderPath(System.Environment.SpecialFolder.System);
        result["PATH"] = system + ";" + Path.Combine(system, "OpenSSH");
        return result;
    }

    /// <summary>
    /// Refuses directives the viewer never runs. Tokens follow ssh_config:
    /// keyword, then "=" or whitespace; "#" starts a comment at a token start.
    /// </summary>
    internal static void Admit(string text)
    {
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim().TrimEnd('\r');
            if (line.Length == 0 || line[0] == '#') continue;
            var split = line.IndexOfAny([' ', '\t', '=']);
            var keyword = (split < 0 ? line : line[..split]).ToLowerInvariant();
            var rest = split < 0 ? "" : line[(split + 1)..].TrimStart(' ', '\t', '=').ToLowerInvariant();
            if (Refused.Contains(keyword)) throw new NativeSshTunnelException(NativeSshTunnelError.UnsupportedConfiguration);
            if (keyword == "match")
                foreach (var token in rest.Split([' ', '\t', ','], StringSplitOptions.RemoveEmptyEntries))
                    if (token.TrimStart('!') is "exec" or "localnetwork") throw new NativeSshTunnelException(NativeSshTunnelError.UnsupportedConfiguration);
        }
    }

    /// <summary>Copies the configuration (or an empty one) into the private attempt directory.</summary>
    internal static string Snapshot(string? source, string directory)
    {
        source ??= Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile), ".ssh", "config");
        byte[] bytes = [];
        var info = new FileInfo(source);
        if (info.Exists)
        {
            if ((info.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory | FileAttributes.Device)) != 0 || info.Length > MaximumBytes)
                throw new NativeSshTunnelException(NativeSshTunnelError.UnsupportedConfiguration);
            try { bytes = File.ReadAllBytes(source); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw new NativeSshTunnelException(NativeSshTunnelError.ConfigurationFailed); }
            if (bytes.Length > MaximumBytes) throw new NativeSshTunnelException(NativeSshTunnelError.UnsupportedConfiguration);
        }
        else if (Directory.Exists(source)) throw new NativeSshTunnelException(NativeSshTunnelError.ConfigurationFailed);
        string text;
        try { text = new UTF8Encoding(false, true).GetString(bytes); }
        catch (DecoderFallbackException) { throw new NativeSshTunnelException(NativeSshTunnelError.UnsupportedConfiguration); }
        Admit(text);
        var snapshot = Path.Combine(directory, "config");
        File.WriteAllBytes(snapshot, bytes);
        return snapshot;
    }

    /// <summary>Evaluates the snapshot with <c>ssh -G</c> and returns the effective gateway, refusing unsupported effects.</summary>
    internal static async Task<NativeSshResolvedGateway> ResolveAsync(string client, string snapshot, NativeSshGateway gateway,
                                                                       IReadOnlyList<string> forced, CancellationToken cancellation)
    {
        var arguments = new List<string> { "-G", "-F", snapshot };
        arguments.AddRange(forced);
        if (gateway.User is { } user) arguments.AddRange(["-l", user]);
        if (gateway.PortIsExplicit) arguments.AddRange(["-p", gateway.Port.ToString(CultureInfo.InvariantCulture)]);
        arguments.Add(gateway.Host);
        using var probe = NativeOwnedProcess.Start(client, arguments, Environment());
        probe.Input.Dispose();
        var output = ReadBoundedAsync(probe.Output, 1024 * 1024);
        var errors = ReadBoundedAsync(probe.Error, 64 * 1024);
        int code;
        try { code = await probe.Exited.WaitAsync(TimeSpan.FromSeconds(15), cancellation); }
        catch (TimeoutException) { throw new NativeSshTunnelException(NativeSshTunnelError.ConfigurationFailed); }
        catch (OperationCanceledException) { throw new NativeSshTunnelException(NativeSshTunnelError.Cancelled); }
        var text = await output;
        await errors;
        if (code != 0 || text is null) throw new NativeSshTunnelException(NativeSshTunnelError.ConfigurationFailed);
        var values = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var line in text.Split('\n'))
        {
            var trimmed = line.TrimEnd('\r');
            var space = trimmed.IndexOf(' ', StringComparison.Ordinal);
            if (space <= 0) continue;
            var key = trimmed[..space];
            if (!values.TryGetValue(key, out var list)) values[key] = list = [];
            list.Add(trimmed[(space + 1)..]);
        }
        string One(string key) => values.TryGetValue(key, out var list) && list.Count == 1 ? list[0] : throw new NativeSshTunnelException(NativeSshTunnelError.ConfigurationFailed);
        bool Unset(string key) => !values.TryGetValue(key, out var list) || list.All(v => v is "none" or "");
        if (!Unset("proxycommand") || !Unset("proxyjump") || !Unset("remotecommand") || !Unset("knownhostscommand") ||
            !Unset("pkcs11provider") || (values.TryGetValue("tunnel", out var tunnel) && !tunnel.Contains("false")) ||
            (values.TryGetValue("permitlocalcommand", out var local) && local.Contains("yes") && !Unset("localcommand")) ||
            values.ContainsKey("localforward") || values.ContainsKey("remoteforward") || values.ContainsKey("dynamicforward"))
            throw new NativeSshTunnelException(NativeSshTunnelError.UnsupportedConfiguration);
        if (!int.TryParse(One("port"), NumberStyles.None, CultureInfo.InvariantCulture, out var port) || port is < 1 or > 65535)
            throw new NativeSshTunnelException(NativeSshTunnelError.ConfigurationFailed);
        var host = One("hostname");
        var resolvedUser = One("user");
        var alias = values.TryGetValue("hostkeyalias", out var aliases) && aliases.Count == 1 ? aliases[0] : "";
        if (host.Length is 0 or > 1024 || resolvedUser.Length is 0 or > 256 || alias.Length > 1024)
            throw new NativeSshTunnelException(NativeSshTunnelError.ConfigurationFailed);
        return new NativeSshResolvedGateway(host, resolvedUser, port, alias);
    }

    /// <summary>Reads a stream to its end, keeping at most maximum bytes of UTF-8 text (null when exceeded).</summary>
    internal static async Task<string?> ReadBoundedAsync(Stream stream, int maximum)
    {
        var buffer = new MemoryStream();
        var chunk = new byte[16384];
        var overflow = false;
        try
        {
            while (await stream.ReadAsync(chunk) is var count && count > 0)
            {
                if (buffer.Length + count > maximum) overflow = true;
                else buffer.Write(chunk, 0, count);
            }
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException) { }
        if (overflow) return null;
        try { return new UTF8Encoding(false, true).GetString(buffer.ToArray()); }
        catch (DecoderFallbackException) { return null; }
    }

    /// <summary>A private per-attempt directory under the state root (owner-only DACL).</summary>
    internal static string AttemptDirectory(string? stateDirectory)
    {
        var root = Path.Combine(stateDirectory ?? NativeStateRoot.Directory, "t");
        var directory = Path.Combine(root, Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(4)).ToLowerInvariant());
        try { NativePrivateFiles.EnsureDirectory(directory); }
        catch (NativeStorageException) { throw new NativeSshTunnelException(NativeSshTunnelError.Failed); }
        return directory;
    }
}
