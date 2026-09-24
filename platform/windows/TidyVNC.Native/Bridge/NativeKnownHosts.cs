// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

/// <summary>A certificate's DER SPKI and commitment digests (tidyvnc_certificate_key).</summary>
public sealed unsafe class NativeCertificateKey : IDisposable
{
    internal NativeHandle Handle { get; }
    public byte[] Spki { get; }

    public NativeCertificateKey(ReadOnlySpan<byte> certificate)
    {
        if (certificate.IsEmpty || certificate.Length > 65536) throw new ArgumentException("Invalid certificate", nameof(certificate));
        var error = Abi.Init<tidyvnc_error>();
        ulong raw = 0;
        fixed (byte* data = certificate)
            Abi.Check(NativeMethods.tidyvnc_certificate_key_create(AbiText.Span(data, certificate.Length), &raw, &error), &error);
        Handle = NativeHandle.Adopt(raw);
        var info = Abi.Init<tidyvnc_certificate_key_info>();
        Abi.Check(NativeMethods.tidyvnc_certificate_key_get(Handle.Raw, &info, &error), &error);
        Spki = new ReadOnlySpan<byte>(info.spki.data, checked((int)info.spki.length)).ToArray();
    }

    public override string ToString() => "NativeCertificateKey(<redacted>)";
    public void Dispose() => Handle.Dispose();
}

public enum NativeKnownHostsState : uint { Missing = 0, Match = 1, Changed = 2 }

/// <summary>An identity a legacy record expects: an SPKI fingerprint or a digest commitment.</summary>
public sealed record NativeKnownHostsIdentity(bool IsCommitment, uint Algorithm, string Text);

public sealed record NativeKnownHostsMatch(
    NativeKnownHostsState State, IReadOnlyList<NativeKnownHostsIdentity> Expected, bool HasMore, bool IncludesWildcardHost,
    string ReceivedFingerprint)
{
    public override string ToString() => "NativeKnownHostsMatch(<redacted>)";
}

public sealed class NativeKnownHostsFailure : Exception
{
    public enum Problem : uint { TooLarge = 1, Corrupt = 2, UnsupportedFormat = 3, UnsupportedDigest = 4 }
    public Problem Reason { get; }
    /// <summary>One-based line, or zero.</summary>
    public uint Line { get; }

    public NativeKnownHostsFailure(Problem reason, uint line) : base(line == 0 ? $"Legacy trust store: {reason}" : $"Legacy trust store line {line}: {reason}")
    {
        Reason = reason; Line = line;
    }
}

/// <summary>
/// Read-only lookup in the retained viewer's x509_known_hosts
/// (tidyvnc_known_hosts_lookup; NativeLegacyTrustCodec on macOS). A match
/// never writes anything and is not a trust decision by itself.
/// </summary>
public static unsafe class NativeKnownHosts
{
    public const int MaximumBytes = 1024 * 1024;

    public static NativeKnownHostsMatch Lookup(ReadOnlySpan<byte> file, string host, NativeCertificateKey key, DateTimeOffset now)
    {
        var hostBytes = System.Text.Encoding.UTF8.GetBytes(host);
        var output = Abi.Init<tidyvnc_known_hosts_match>();
        var error = Abi.Init<tidyvnc_error>();
        uint status;
        fixed (byte* f = file) fixed (byte* h = hostBytes)
            status = NativeMethods.tidyvnc_known_hosts_lookup(AbiText.Span(f, file.Length), AbiText.Span(h, hostBytes.Length),
                default, key.Handle.Raw, (ulong)Math.Max(0, now.ToUnixTimeSeconds()), &output, &error);
        if (status != Tidyvnc.TIDYVNC_OK)
        {
            if (error.domain == Tidyvnc.TIDYVNC_DOMAIN_KNOWN_HOSTS)
                throw new NativeKnownHostsFailure((NativeKnownHostsFailure.Problem)(error.detail & 0xff), error.detail >> 8);
            throw new NativeError(error);
        }
        var expected = new NativeKnownHostsIdentity[output.count];
        for (var i = 0; i < expected.Length; i++)
        {
            ref var entry = ref output.expected[i];
            fixed (byte* text = entry.text)
                expected[i] = new NativeKnownHostsIdentity(entry.kind == Tidyvnc.TIDYVNC_KNOWN_HOSTS_COMMITMENT, entry.algorithm, AbiText.Fixed(text, 132));
        }
        return new NativeKnownHostsMatch((NativeKnownHostsState)output.state, expected, output.has_more != 0, output.wildcard != 0,
            AbiText.Fixed(output.received, 100));
    }
}
