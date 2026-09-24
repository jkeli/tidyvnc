// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Globalization;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

[Flags]
public enum NativeCertificateReason : uint
{
    None = 0,
    Invalid = 1, Revoked = 2, UnknownIssuer = 4, SignerNotCa = 8, WeakAlgorithm = 16,
    NotYetValid = 32, Expired = 64, BadSignature = 128, OldRevocationData = 256,
    WrongOwner = 512, FutureRevocationData = 1024, SignerConstraints = 2048, Mismatch = 4096,
    WrongPurpose = 8192, MissingOcsp = 16384, InvalidOcsp = 32768, CriticalExtension = 65536,
    UnknownProblem = 131072, MissingProblem = 262144,
}

/// <summary>Core classification of a certificate verification status (NativeCertificatePolicy).</summary>
public sealed record NativeCertificatePolicy(IReadOnlyList<NativeCertificateReason> Reasons, bool MayOverride, uint FatalStatus)
{
    public static unsafe NativeCertificatePolicy For(uint status)
    {
        var value = Abi.Init<tidyvnc_certificate_policy>();
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_certificate_policy_get(status, &value, &error), &error);
        var bits = value.reasons;
        var reasons = Enum.GetValues<NativeCertificateReason>()
            .Where(reason => reason != NativeCertificateReason.None && (bits & (uint)reason) != 0).ToList();
        return new NativeCertificatePolicy(reasons, value.may_override != 0, value.fatal_status);
    }
}

/// <summary>A validated RSA-AES server key identity (NativeHostKey). Never printed.</summary>
public sealed class NativeHostKey
{
    public uint Bits { get; }
    public byte[] Identity { get; }

    public unsafe NativeHostKey(byte[] identity)
    {
        if (identity.Length > 2052) throw new ArgumentException("Host key identity too long", nameof(identity));
        uint bits = 0;
        var error = Abi.Init<tidyvnc_error>();
        fixed (byte* p = identity)
            Abi.Check(NativeMethods.tidyvnc_host_key_validate(NativeText.Span(p, identity.Length), &bits, &error), &error);
        Bits = bits; Identity = identity;
    }

    public override string ToString() => "NativeHostKey(<redacted>)";
}

/// <summary>Issuer, serial, validity, key and signature details of a decoded certificate.</summary>
public sealed record NativeCertificateDetails(string? Subject, string? Issuer, string? SerialNumber, DateTimeOffset? ValidFrom,
                                              DateTimeOffset? ValidUntil, string? KeyAlgorithm, int? KeyBits, string? SignatureAlgorithm)
{
    private static readonly Dictionary<string, string> Signatures = new()
    {
        ["1.2.840.113549.1.1.5"] = "RSA-SHA1", ["1.2.840.113549.1.1.11"] = "RSA-SHA256", ["1.2.840.113549.1.1.12"] = "RSA-SHA384",
        ["1.2.840.113549.1.1.13"] = "RSA-SHA512", ["1.2.840.113549.1.1.10"] = "RSA-PSS", ["1.2.840.10045.4.3.2"] = "ECDSA-SHA256",
        ["1.2.840.10045.4.3.3"] = "ECDSA-SHA384", ["1.2.840.10045.4.3.4"] = "ECDSA-SHA512", ["1.3.101.112"] = "Ed25519",
        ["1.3.101.113"] = "Ed448",
    };

    /// <summary>Decodes DER bytes; null when the certificate cannot be read (never guessed).</summary>
    public static NativeCertificateDetails? Decode(byte[] der)
    {
        try
        {
            using var certificate = X509CertificateLoader.LoadCertificate(der);
            string? keyAlgorithm = null; int? bits = null;
            using (var rsa = certificate.GetRSAPublicKey()) if (rsa is not null) { keyAlgorithm = "RSA"; bits = rsa.KeySize; }
            if (keyAlgorithm is null)
                using (var ec = certificate.GetECDsaPublicKey()) if (ec is not null) { keyAlgorithm = "EC"; bits = ec.KeySize; }
            var oid = certificate.SignatureAlgorithm.Value;
            return new NativeCertificateDetails(
                certificate.GetNameInfo(X509NameType.SimpleName, false), certificate.Issuer,
                string.Join(':', certificate.SerialNumberBytes.ToArray().Reverse().Select(b => b.ToString("X2", CultureInfo.InvariantCulture))),
                new DateTimeOffset(certificate.NotBefore.ToUniversalTime()), new DateTimeOffset(certificate.NotAfter.ToUniversalTime()),
                keyAlgorithm, bits, oid is not null && Signatures.TryGetValue(oid, out var name) ? name : oid);
        }
        catch (CryptographicException) { return null; }
    }
}

/// <summary>
/// What the trust dialog shows (NativeTrustPresentation). Derived from owned,
/// bounded prompt data; fingerprints never appear in diagnostics.
/// </summary>
public sealed class NativeTrustPresentation
{
    public bool MayConnectOnce { get; }
    public IReadOnlyList<NativeCertificateReason> Reasons { get; }
    /// <summary>Set when no core policy was available or the identity could not be decoded.</summary>
    public NativeTrustProblem Problem { get; }
    public string? Subject { get; }
    public string? Sha256Fingerprint { get; }
    /// <summary>RSA-AES: RealVNC's truncated SHA-1 display format, never labelled SHA-256.</summary>
    public string? CompatibilityFingerprint { get; }
    public NativeCertificateDetails? Certificate { get; }

    public enum NativeTrustProblem { None, PolicyUnavailable, CertificateDecode, KeyUnverified, KeyUnavailable, InvalidRequest }

    public NativeTrustPresentation(NativePrompt request)
    {
        var validIdentity = request.Identity.Length is > 0 and <= 65536;
        Sha256Fingerprint = validIdentity ? request.Sha256Fingerprint : null;
        Reasons = [];
        switch (request.Kind)
        {
            case NativePrompt.PromptKind.Certificate:
                NativeCertificatePolicy? policy = null;
                try { policy = NativeCertificatePolicy.For(request.CertificateStatus); } catch (NativeError) { }
                Reasons = policy?.Reasons ?? [];
                Certificate = validIdentity ? NativeCertificateDetails.Decode(request.Identity) : null;
                if (Certificate is not null)
                {
                    Subject = Certificate.Subject;
                    MayConnectOnce = policy?.MayOverride == true;
                    Problem = policy is null ? NativeTrustProblem.PolicyUnavailable : NativeTrustProblem.None;
                }
                else Problem = NativeTrustProblem.CertificateDecode;
                break;
            case NativePrompt.PromptKind.HostKey:
                try { _ = new NativeHostKey(request.Identity); MayConnectOnce = true; } catch (Exception e) when (e is NativeError or ArgumentException) { }
                Problem = MayConnectOnce ? NativeTrustProblem.KeyUnverified : NativeTrustProblem.KeyUnavailable;
#pragma warning disable CA5350 // Display compatibility with RealVNC's key fingerprint, not a security decision.
                if (MayConnectOnce)
                    CompatibilityFingerprint = string.Join('-', SHA1.HashData(request.Identity).Take(8)
                        .Select(b => b.ToString("x2", CultureInfo.InvariantCulture)));
#pragma warning restore CA5350
                break;
            default:
                Problem = NativeTrustProblem.InvalidRequest;
                break;
        }
    }

    public override string ToString() => "NativeTrustPresentation(<redacted>)";
}
