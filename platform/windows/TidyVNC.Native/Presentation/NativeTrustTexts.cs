// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Storage;
using TidyVNC.Native.Trust;

namespace TidyVNC.Native;

/// <summary>Trust dialog and library texts (macOS NativeTrust.swift, NativeCertificateTrust and NativeTrustLibrary messages).</summary>
public static class NativeTrustTexts
{
    public static NativeText Reason(NativeCertificateReason reason) => new("trust.certificate.reason." + reason switch
    {
        NativeCertificateReason.SignerNotCa => "signerNotCA",
        NativeCertificateReason.MissingOcsp => "missingOCSP",
        NativeCertificateReason.InvalidOcsp => "invalidOCSP",
        _ => char.ToLowerInvariant(reason.ToString()[0]) + reason.ToString()[1..],
    });

    /// <summary>The problems a request presents, in order (macOS NativeTrustPresentation.problems).</summary>
    public static IReadOnlyList<NativeText> Problems(NativeTrustPresentation presentation, NativePrompt.PromptKind kind)
    {
        var problems = new List<NativeText>();
        switch (kind)
        {
            case NativePrompt.PromptKind.Certificate:
                if (presentation.Problem == NativeTrustPresentation.NativeTrustProblem.PolicyUnavailable)
                    problems.Add(new NativeText("trust.presentation.policyUnavailable"));
                else problems.AddRange(presentation.Reasons.Select(Reason));
                if (presentation.Problem == NativeTrustPresentation.NativeTrustProblem.CertificateDecode)
                    problems.Add(new NativeText("trust.presentation.certificateDecode"));
                break;
            case NativePrompt.PromptKind.HostKey:
                problems.Add(new NativeText(presentation.MayConnectOnce ? "trust.presentation.keyUnverified" : "trust.presentation.keyUnavailable"));
                break;
            default:
                problems.Add(new NativeText("trust.presentation.invalidRequest"));
                break;
        }
        return problems;
    }

    public static NativeText Expected(NativeKnownHostsIdentity identity) => identity.IsCommitment
        ? new NativeText("trust.expected.legacyCommitment", identity.Algorithm.ToString(System.Globalization.CultureInfo.InvariantCulture), identity.Text)
        : new NativeText("trust.expected.spki", identity.Text);

    /// <summary>Why saved decisions could not be checked (legacy files first, then the TidyVNC store).</summary>
    public static NativeText? Issue(NativeLegacyTrustError? legacy, NativeStorageError? saved)
    {
        if (saved is { } error) return Storage(error);
        return legacy switch
        {
            null => null,
            NativeLegacyTrustError.Denied => new("trust.inspection.saved.certificate.exceptions.could.not.be.read.because.access.was.denied"),
            NativeLegacyTrustError.UnsafeFile => new("trust.inspection.the.saved.certificate.exception.file.has.unsafe.ownership.permissions.or.file.type"),
            NativeLegacyTrustError.Corrupt => new("trust.inspection.the.saved.certificate.exception.file.is.malformed.it.has.not.been.changed"),
            NativeLegacyTrustError.UnsupportedFormat or NativeLegacyTrustError.UnsupportedDigest => new("trust.inspection.the.saved.certificate.exceptions.use.an.unsupported.format.or.digest"),
            NativeLegacyTrustError.TooLarge => new("trust.inspection.the.saved.certificate.exception.file.exceeds.the.supported.size"),
            NativeLegacyTrustError.Changed => new("trust.inspection.the.saved.certificate.exceptions.changed.while.being.read.connect.again.to.check"),
            NativeLegacyTrustError.Cancelled => new("trust.inspection.the.certificate.exception.check.was.cancelled"),
            _ => new("trust.inspection.saved.certificate.exceptions.could.not.be.checked"),
        };
    }

    public static NativeText Storage(NativeStorageError error) => new(error switch
    {
        NativeStorageError.Conflict => "trust.library.saved.trust.decisions.changed.elsewhere.reload.before.making.another.change",
        NativeStorageError.Denied => "trust.library.access.to.saved.trust.decisions.was.denied.check.access.and.reload",
        NativeStorageError.FutureSchema or NativeStorageError.UnsupportedFields => "trust.library.saved.trust.decisions.require.an.unsupported.format.existing.data.has.been.preserved",
        NativeStorageError.Corrupt or NativeStorageError.Invalid => "trust.library.saved.trust.decisions.could.not.be.read.or.validated.existing.data.has",
        NativeStorageError.TooLarge or NativeStorageError.ResourceLimit => "trust.library.the.saved.trust.decisions.exceed.the.supported.size.or.count",
        NativeStorageError.Cancelled or NativeStorageError.IOFailure => "trust.library.the.trust.decision.could.not.be.confirmed.reload.to.check.its.saved",
        _ => "trust.library.saved.trust.decisions.are.unavailable.reload.to.try.again",
    });

    public static NativeText Notice(NativeTrustNotice notice) => new(notice == NativeTrustNotice.ForgottenHostKey
        ? "trust.inspection.forgot.the.saved.server.key.for.this.destination.compare.the.key.again"
        : "trust.inspection.forgot.the.saved.key.for.this.destination.older.host.wide.exceptions.will");
}
