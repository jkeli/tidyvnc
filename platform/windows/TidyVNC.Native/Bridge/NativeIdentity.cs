// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Text;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

public enum NativeCredentialShape : uint { PasswordOnly = 1, UsernamePassword = 2 }
public enum NativeTrustKind { Certificate, HostKey }

/// <summary>Why an identity could not be formed (DOMAIN_IDENTITY reasons).</summary>
public sealed class NativeIdentityFailure : Exception
{
    public enum Problem : uint
    {
        TooLong = 1, InvalidText = 2, InvalidEndpoint = 3, InvalidAuthentication = 4, UnexpectedUsername = 5,
        InvalidGateway = 6, InvalidAlias = 7, InvalidKind = 8,
    }

    public Problem Reason { get; }

    public NativeIdentityFailure(Problem reason) : base($"Invalid identity input ({reason})") => Reason = reason;
}

/// <summary>
/// Versioned SHA-256 identities that name saved credentials, trust entries
/// and SSH routes (tidyvnc_identity_digest), byte-identical to the macOS
/// frontend's. They are neither secrets nor proof of trust, and contain no
/// endpoint, route or user text.
/// </summary>
public static unsafe class NativeIdentity
{
    /// <summary>"v1:…": a credential account for the negotiated method (NativeCredentialKey).</summary>
    public static string CredentialAccount(string endpoint, string route, uint securityType, NativeCredentialShape shape,
                                           string username = "", bool allowUnixSockets = true)
        => Digest(Tidyvnc.TIDYVNC_IDENTITY_CREDENTIAL, endpoint, route, username, "", securityType, (uint)shape, allowUnixSockets, 0);

    /// <summary>"v1:…": the destination a trust decision applies to (NativeTrustScope).</summary>
    public static string TrustScope(string endpoint, string route, NativeTrustKind kind)
        => Digest(kind == NativeTrustKind.Certificate ? Tidyvnc.TIDYVNC_IDENTITY_TRUST_CERTIFICATE : Tidyvnc.TIDYVNC_IDENTITY_TRUST_HOST_KEY,
                  endpoint, route, "", "", 0, 0, true, 0);

    /// <summary>"ssh-v1:…": a requested gateway's route (host, scope, port, user).</summary>
    public static string SshRoute(string gateway)
        => Digest(Tidyvnc.TIDYVNC_IDENTITY_SSH_ROUTE, gateway, "", "", "", 0, 0, false, 0);

    /// <summary>"ssh-request-v2:…": a requested gateway's canonical URI.</summary>
    public static string SshIntent(string gateway)
        => Digest(Tidyvnc.TIDYVNC_IDENTITY_SSH_INTENT, gateway, "", "", "", 0, 0, false, 0);

    /// <summary>"ssh-v2:…": a gateway after <c>ssh -G</c>; an empty alias means no HostKeyAlias.</summary>
    public static string SshResolved(string host, string user, uint port, string hostKeyAlias = "")
        => Digest(Tidyvnc.TIDYVNC_IDENTITY_SSH_RESOLVED, host, "", user, hostKeyAlias, 0, 0, false, port);

    private static string Digest(uint kind, string endpoint, string route, string username, string alias,
                                 uint securityType, uint shape, bool allowUnixSockets, uint port)
    {
        byte[] Encode(string text)
        {
            // Strict: text that is not valid Unicode cannot be byte-identical elsewhere.
            try { return new UTF8Encoding(false, true).GetBytes(text); }
            catch (EncoderFallbackException) { throw new NativeIdentityFailure(NativeIdentityFailure.Problem.InvalidText); }
        }
        var e = Encode(endpoint); var r = Encode(route); var u = Encode(username); var a = Encode(alias);
        var request = Abi.Init<tidyvnc_identity_request>();
        request.kind = kind; request.security_type = securityType; request.shape = shape;
        request.allow_unix_sockets = allowUnixSockets ? 1u : 0u; request.port = port;
        var output = Abi.Init<tidyvnc_identity>();
        var error = Abi.Init<tidyvnc_error>();
        uint status;
        fixed (byte* pe = e) fixed (byte* pr = r) fixed (byte* pu = u) fixed (byte* pa = a)
        {
            request.endpoint = AbiText.Span(pe, e.Length); request.route = AbiText.Span(pr, r.Length);
            request.username = AbiText.Span(pu, u.Length); request.host_key_alias = AbiText.Span(pa, a.Length);
            status = NativeMethods.tidyvnc_identity_digest(&request, &output, &error);
        }
        if (status != Tidyvnc.TIDYVNC_OK)
        {
            if (error.domain == Tidyvnc.TIDYVNC_DOMAIN_IDENTITY) throw new NativeIdentityFailure((NativeIdentityFailure.Problem)error.detail);
            throw new NativeError(error);
        }
        return AbiText.Fixed(output.text, 80);
    }
}
