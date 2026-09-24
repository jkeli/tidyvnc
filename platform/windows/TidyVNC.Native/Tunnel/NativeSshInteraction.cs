// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Security.Cryptography;
using System.Text;
using CommunityToolkit.Mvvm.ComponentModel;

namespace TidyVNC.Native.Tunnel;

/// <summary>
/// One SSH question with the connection it belongs to. OpenSSH's text is
/// untrusted plain text: it never chooses an endpoint, credential, command or
/// automatic answer (macOS NativeSSHQuestion).
/// </summary>
public sealed record NativeSshQuestion(Guid Id, NativeSshGateway Gateway, string Endpoint, NativeSshPrompt Prompt)
{
    public override string ToString() => "NativeSshQuestion(<redacted>)";
}

/// <summary>
/// The window-side SSH prompt owner (macOS NativeSSHInteraction): the askpass
/// server asks from its pipe thread; the question is published on the UI
/// thread, one at a time, and answered or cancelled from the dialog. Secrets
/// are copied once into the answer the server wipes; the typed text is
/// wiped by the caller.
/// </summary>
public sealed partial class NativeSshInteraction : ObservableObject, INativeSshInteraction
{
    private readonly IUiDispatcher dispatcher;
    private NativeSshGateway? gateway;
    private string endpoint = "";
    private TaskCompletionSource<byte[]?>? pending;
    private bool stopped;

    [ObservableProperty] public partial NativeSshQuestion? Question { get; private set; }

    public NativeSshInteraction(IUiDispatcher dispatcher) => this.dispatcher = dispatcher;

    /// <summary>The connection the next questions belong to (set before each tunnel attempt).</summary>
    public void Begin(NativeSshGateway gateway, string endpoint)
    {
        UiThread.Require(dispatcher);
        this.gateway = gateway; this.endpoint = endpoint;
    }

    public Task<byte[]?> AnswerAsync(NativeSshPrompt prompt, CancellationToken cancellation)
    {
        var answer = new TaskCompletionSource<byte[]?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var registration = cancellation.Register(() => dispatcher.TryEnqueue(() => Cancel(prompt.Id)));
        _ = answer.Task.ContinueWith(_ => registration.Dispose(), TaskScheduler.Default);
        if (!dispatcher.TryEnqueue(() =>
        {
            if (stopped || pending is not null || gateway is null || cancellation.IsCancellationRequested) { answer.TrySetResult(null); return; }
            pending = answer;
            Question = new NativeSshQuestion(prompt.Id, gateway, endpoint, prompt);
        })) answer.TrySetResult(null);
        return answer.Task;
    }

    /// <summary>
    /// Answers the current question. SSH reads at most 1023 bytes up to a line
    /// break, so longer or multi-line text is refused rather than truncated.
    /// A host key can only be approved with its own computed fingerprint.
    /// </summary>
    public bool Respond(Guid id, string text)
    {
        UiThread.Require(dispatcher);
        if (stopped || Question is not { } question || question.Id != id || pending is null) return false;
        var bytes = Encoding.UTF8.GetBytes(text);
        try
        {
            if (bytes.Length > 1023 || bytes.Contains((byte)0) || bytes.Contains((byte)'\n') || bytes.Contains((byte)'\r')) return false;
            if (question.Prompt.Kind == NativeSshPromptKind.HostKey &&
                (question.Prompt.HostKey is not { } key || !string.Equals(text, key.Fingerprint, StringComparison.Ordinal))) return false;
            var answer = pending;
            pending = null; Question = null;
            answer.TrySetResult(bytes.ToArray());
            return true;
        }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    public void Cancel(Guid id)
    {
        UiThread.Require(dispatcher);
        if (Question?.Id != id) return;
        var answer = pending;
        pending = null; Question = null;
        answer?.TrySetResult(null);
    }

    public void Cancel()
    {
        if (Question is { } question) Cancel(question.Id);
    }

    public void Stop()
    {
        stopped = true;
        Cancel();
    }
}

public static class NativeTunnelTexts
{
    public static NativeText Text(NativeSshTunnelError error) => new(error switch
    {
        NativeSshTunnelError.ClientMissing => "tunnel.error.windows.client.missing",
        NativeSshTunnelError.UnsupportedConfiguration => "tunnel.error.ssh.configuration.contains.unsupported.settings.command.execution.proxy.hops.and.network.dependent",
        NativeSshTunnelError.ConfigurationFailed => "tunnel.error.ssh.configuration.could.not.be.prepared.check.file.access.and.host.match",
        NativeSshTunnelError.HostKeySaveFailed => "tunnel.error.ssh.could.not.save.the.gateway.key.check.known.hosts.file.access",
        NativeSshTunnelError.Timeout => "tunnel.error.ssh.tunnel.startup.timed.out",
        NativeSshTunnelError.Closed or NativeSshTunnelError.Cancelled => "tunnel.error.the.ssh.tunnel.is.closed",
        _ => "tunnel.error.ssh.did.not.establish.the.tunnel.check.the.gateway.host.key.verification",
    });

    public static NativeText InvalidRequest { get; } = new("tunnel.error.the.ssh.gateway.or.forwarding.request.is.invalid");
    public static NativeText UnsupportedTarget { get; } = new("tunnel.error.ssh.forwarding.requires.a.tcp.server.address");
}
