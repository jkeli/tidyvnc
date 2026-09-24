// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Text;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

/// <summary>
/// A validated SSH gateway ("via": [user@]host or ssh://[user@]host[:port];
/// tidyvnc_ssh_gateway_create). Persisted as its canonical URI, which parses
/// back to the same gateway. Nothing is resolved or run.
/// </summary>
public sealed record NativeSshGateway(string Host, string Scope, string? User, uint Port, bool PortIsExplicit, string CanonicalUri)
{
    public static unsafe NativeSshGateway Parse(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        var error = Abi.Init<tidyvnc_error>();
        ulong raw = 0;
        fixed (byte* data = bytes)
            Abi.Check(NativeMethods.tidyvnc_ssh_gateway_create(AbiText.Span(data, bytes.Length), &raw, &error), &error);
        using var owner = NativeHandle.Adopt(raw);
        var info = Abi.Init<tidyvnc_ssh_gateway_info>();
        Abi.Check(NativeMethods.tidyvnc_ssh_gateway_get(owner.Raw, &info, &error), &error);
        static string Text(tidyvnc_bytes value) => value.length == 0 ? "" : Encoding.UTF8.GetString(value.data, checked((int)value.length));
        var hasUser = (info.flags & Tidyvnc.TIDYVNC_SSH_GATEWAY_USER) != 0;
        return new NativeSshGateway(Text(info.host), Text(info.scope), hasUser ? Text(info.user) : null, info.port,
            (info.flags & Tidyvnc.TIDYVNC_SSH_GATEWAY_EXPLICIT_PORT) != 0, Text(info.canonical_uri));
    }

    /// <summary>"ssh-v1:…": the route identity that scopes saved credentials and trust.</summary>
    public string RouteIdentity => NativeIdentity.SshRoute(CanonicalUri);
    /// <summary>"ssh-request-v2:…": the requested gateway including port intent.</summary>
    public string IntentIdentity => NativeIdentity.SshIntent(CanonicalUri);
}
