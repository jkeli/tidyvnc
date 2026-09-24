// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Buffers.Binary;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

namespace TidyVNC.Native.Tunnel;

/// <summary>
/// A gateway host key as OpenSSH offers it (NativeSSHHostKey on macOS): the
/// wire blob of a plain Ed25519, RSA or NIST ECDSA key, validated
/// structurally, with the SHA-256 fingerprint OpenSSH prints
/// ("SHA256:" + unpadded base64). Certificates and other formats are not
/// reviewable and fail closed.
/// </summary>
public sealed record NativeSshHostKey(string Host, string Algorithm, byte[] Blob)
{
    private static readonly string[] Supported = ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"];

    public string Fingerprint => "SHA256:" + Convert.ToBase64String(SHA256.HashData(Blob)).TrimEnd('=');

    public static NativeSshHostKey? Parse(string host, string algorithm, string base64)
    {
        if (host.Length is 0 or > 1024 || !Supported.Contains(algorithm, StringComparer.Ordinal) || base64.Length > 8192) return null;
        byte[] blob;
        try { blob = Convert.FromBase64String(base64); }
        catch (FormatException) { return null; }
        var position = 0;
        byte[]? Field()
        {
            if (position + 4 > blob.Length) return null;
            var length = BinaryPrimitives.ReadUInt32BigEndian(blob.AsSpan(position));
            if (length > blob.Length - position - 4) return null;
            var value = blob.AsSpan(position + 4, (int)length).ToArray();
            position += 4 + (int)length;
            return value;
        }
        if (Field() is not { } name || Encoding.ASCII.GetString(name) != algorithm) return null;
        var valid = algorithm switch
        {
            "ssh-ed25519" => Field() is { Length: 32 },
            "ssh-rsa" => Field() is { Length: > 0 and <= 16 } && Field() is { Length: >= 256 and <= 2049 },
            _ => Field() is { } curve && Encoding.ASCII.GetString(curve) == algorithm["ecdsa-sha2-".Length..] &&
                 Field() is { Length: > 0 } point && point[0] == 4 && point.Length == algorithm switch
                 {
                     "ecdsa-sha2-nistp256" => 65, "ecdsa-sha2-nistp384" => 97, _ => 133,
                 },
        };
        return valid && position == blob.Length ? new NativeSshHostKey(host, algorithm, blob) : null;
    }

    public override string ToString() => $"NativeSshHostKey({Algorithm}, <redacted>)";
}

public enum NativeSshPromptKind
{
    /// <summary>A password or key passphrase; the answer is a secret.</summary>
    Secret,
    /// <summary>A new gateway host key to review; approving returns its fingerprint.</summary>
    HostKey,
    /// <summary>Any other question OpenSSH asks (answered yes/no by the user, never a secret).</summary>
    Question,
}

/// <summary>
/// One SSH question for the app to present (TUNNELS.md "Native SSH prompt
/// transport"). Text is OpenSSH's prompt, bounded and shown as plain text;
/// for host keys the app shows the gateway context and the computed
/// fingerprint, never trust derived from the prompt's prose.
/// </summary>
public sealed record NativeSshPrompt(Guid Id, NativeSshPromptKind Kind, string Text, NativeSshHostKey? HostKey)
{
    public override string ToString() => $"NativeSshPrompt({Kind}, <redacted>)";
}

/// <summary>What the app does with SSH questions: present one and return the answer bytes (wiped by the caller), or null.</summary>
public interface INativeSshInteraction
{
    Task<byte[]?> AnswerAsync(NativeSshPrompt prompt, CancellationToken cancellation);
}

/// <summary>
/// The per-attempt askpass endpoint (SERVICES.md section 11): a named pipe
/// that only the current user can open, created as the first instance of a
/// random name, one request at a time. A request must carry the attempt's
/// random token and come from a process inside the attempt's job. Host key
/// observations (KnownHostsCommand, reason HOSTNAME) are recorded, not
/// trusted; a later confirmation is reviewed only when its prompt names the
/// observed host, algorithm and fingerprint. Close revokes any open prompt.
/// </summary>
public sealed class NativeSshAskpassServer : IAsyncDisposable
{
    public const int PromptCharacters = 2048;

    private readonly NamedPipeServerStream pipe;
    private readonly byte[] token = RandomNumberGenerator.GetBytes(NativeSshAskpassProtocol.TokenBytes);
    private readonly INativeSshInteraction interaction;
    private readonly Func<int, bool> clientAllowed;
    private readonly CancellationTokenSource closing = new();
    private readonly Task serving;
    private NativeSshHostKey? observed;
    private int prompts;

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(nint pipe, out uint processId);

    /// <param name="clientAllowed">Whether a client process id belongs to this attempt (its job).</param>
    public NativeSshAskpassServer(INativeSshInteraction interaction, Func<int, bool> clientAllowed)
    {
        this.interaction = interaction;
        this.clientAllowed = clientAllowed;
        Name = "tidyvnc-askpass-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        var security = new PipeSecurity();
        using (var identity = WindowsIdentity.GetCurrent())
            security.AddAccessRule(new PipeAccessRule(identity.User!, PipeAccessRights.FullControl, AccessControlType.Allow));
        security.SetAccessRuleProtection(true, false);
        pipe = NamedPipeServerStreamAcl.Create(Name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.FirstPipeInstance, 0, 0, security);
        serving = Task.Run(ServeAsync);
    }

    public string Name { get; }
    /// <summary>The environment entries ssh.exe passes to the helper.</summary>
    public IReadOnlyDictionary<string, string> Environment => new Dictionary<string, string>
    {
        [NativeSshAskpassProtocol.PipeVariable] = Name,
        [NativeSshAskpassProtocol.TokenVariable] = Convert.ToHexString(token),
        ["TIDYVNC_ASKPASS_OWNER"] = System.Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture),
    };
    /// <summary>The last host key OpenSSH looked up by host name (not a trust decision).</summary>
    public NativeSshHostKey? ObservedHostKey => Volatile.Read(ref observed);
    /// <summary>Questions presented so far (for startup deadline choice and tests).</summary>
    public int Prompts => Volatile.Read(ref prompts);

    private async Task ServeAsync()
    {
        var cancellation = closing.Token;
        while (!cancellation.IsCancellationRequested)
        {
            try { await pipe.WaitForConnectionAsync(cancellation); }
            catch (Exception error) when (error is OperationCanceledException or IOException or ObjectDisposedException) { return; }
            try { await HandleAsync(cancellation); }
            catch (Exception error) when (error is IOException or InvalidDataException or EndOfStreamException or OperationCanceledException) { }
            finally
            {
                try { pipe.Disconnect(); } catch (Exception error) when (error is IOException or InvalidOperationException or ObjectDisposedException) { }
            }
        }
    }

    private async Task HandleAsync(CancellationToken cancellation)
    {
        if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle.DangerousGetHandle(), out var client) || !clientAllowed((int)client))
            return;
        var request = await Task.Run(() => NativeSshAskpassProtocol.DecodeRequest(pipe), cancellation);
        if (!CryptographicOperations.FixedTimeEquals(request.Token, token)) return;
        if (request.Kind == NativeSshAskpassProtocol.Kind.HostKey)
        {
            // Reason, host, algorithm, key: record the HOSTNAME lookup; OpenSSH keeps its ordinary lookup.
            if (request.Fields is [var reason, var host, var algorithm, var key] && reason == "HOSTNAME" &&
                NativeSshHostKey.Parse(host, algorithm, key) is { } parsed)
                Volatile.Write(ref observed, parsed);
            await Reply(NativeSshAskpassProtocol.Status.Answer, [], cancellation);
            return;
        }
        var text = request.Fields.Count > 0 ? request.Fields[0] : "";
        if (text.Length > PromptCharacters) text = text[..PromptCharacters];
        var confirm = request.Fields.Count > 1 && request.Fields[1] is "confirm";
        var prompt = Classify(text, confirm);
        if (prompt is null)
        {
            // A new-key confirmation that does not match the observed key fails closed.
            await Reply(NativeSshAskpassProtocol.Status.Cancelled, [], cancellation);
            return;
        }
        Interlocked.Increment(ref prompts);
        byte[]? answer = null;
        try
        {
            answer = await interaction.AnswerAsync(prompt, cancellation);
            if (prompt.Kind == NativeSshPromptKind.HostKey && answer is not null)
            {
                // Approval returns exactly the computed fingerprint; OpenSSH compares it with its offered key.
                CryptographicOperations.ZeroMemory(answer);
                answer = Encoding.ASCII.GetBytes(prompt.HostKey!.Fingerprint);
            }
            if (answer is not null && !NativeSshAskpassProtocol.ValidAnswer(answer))
            {
                CryptographicOperations.ZeroMemory(answer);
                answer = null;
            }
            await Reply(answer is null ? NativeSshAskpassProtocol.Status.Cancelled : NativeSshAskpassProtocol.Status.Answer, answer ?? [], cancellation);
        }
        finally
        {
            if (answer is not null) CryptographicOperations.ZeroMemory(answer);
        }
    }

    /// <summary>
    /// OpenSSH's new-host-key question ("…(yes/no/[fingerprint])?") is a host
    /// key review only when it names the observed key's host, algorithm
    /// family and fingerprint; otherwise it is refused. Other echoing
    /// questions are yes/no questions; everything else is a secret prompt.
    /// </summary>
    private NativeSshPrompt? Classify(string text, bool confirm)
    {
        if (text.Contains("(yes/no/[fingerprint])", StringComparison.Ordinal) || text.Contains("authenticity of host", StringComparison.OrdinalIgnoreCase))
        {
            var key = ObservedHostKey;
            var family = key?.Algorithm switch
            {
                "ssh-ed25519" => "ED25519", "ssh-rsa" => "RSA", null => null, _ => "ECDSA",
            };
            if (key is null || family is null || !text.Contains(key.Fingerprint, StringComparison.Ordinal) ||
                !text.Contains(family + " key", StringComparison.Ordinal) || !text.Contains("'" + key.Host, StringComparison.Ordinal))
                return null;
            return new NativeSshPrompt(Guid.NewGuid(), NativeSshPromptKind.HostKey, text, key);
        }
        return new NativeSshPrompt(Guid.NewGuid(), confirm ? NativeSshPromptKind.Question : NativeSshPromptKind.Secret, text, null);
    }

    private Task Reply(NativeSshAskpassProtocol.Status status, byte[] answer, CancellationToken cancellation)
    {
        var frame = NativeSshAskpassProtocol.EncodeResponse(status, answer);
        try { return pipe.WriteAsync(frame, cancellation).AsTask().ContinueWith(_ => CryptographicOperations.ZeroMemory(frame), TaskScheduler.Default); }
        catch { CryptographicOperations.ZeroMemory(frame); throw; }
    }

    public async ValueTask DisposeAsync()
    {
        await closing.CancelAsync();
        await pipe.DisposeAsync();
        try { await serving; } catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException) { }
        CryptographicOperations.ZeroMemory(token);
        closing.Dispose();
    }
}
