// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

public sealed record NativeSecurityChoice(uint Id, string Name, bool Available, NativeSecurityChoice.ProtectionKind Protection,
                                          NativeSecurityChoice.CredentialKind Credentials, uint AesBits)
{
    public enum ProtectionKind : uint { Unencrypted = 0, AnonymousTls, X509Tls, RsaAes, RsaAuthentication, LegacyAuthentication }
    public enum CredentialKind : uint { None = 0, Password, UsernamePassword, ServerSelected }
}

/// <summary>A resolved SecurityTypes selection (NativeSecuritySelection).</summary>
public sealed record NativeSecuritySelection
{
    public IReadOnlyList<uint> Types { get; }
    public string Canonical { get; }

    /// <summary>Null is the compiled default; "" explicitly denies every method.</summary>
    public unsafe NativeSecuritySelection(string? text = null)
    {
        var bytes = AbiText.Utf8(text ?? "");
        if (bytes.Length > 1024) throw new NativeError(NativeStatus.ResourceLimit, "Security selection is too long");
        var result = Abi.Init<tidyvnc_security_selection>();
        var error = Abi.Init<tidyvnc_error>();
        fixed (byte* p = bytes)
            Abi.Check(NativeMethods.tidyvnc_security_resolve(AbiText.Span(p, bytes.Length), text is null ? 1u : 0u, &result, &error), &error);
        if (result.count > 32) throw new NativeError(NativeStatus.InternalFailure, "Invalid security selection count");
        var types = new uint[result.count];
        for (var i = 0; i < types.Length; i++) types[i] = result.types[i];
        Types = types; Canonical = AbiText.Fixed(result.canonical, 1025);
    }

    public bool Equals(NativeSecuritySelection? other) => other is not null && Canonical == other.Canonical && Types.SequenceEqual(other.Types);
    public override int GetHashCode() => Canonical.GetHashCode(StringComparison.Ordinal);

    public static unsafe IReadOnlyList<NativeSecurityChoice> Choices()
    {
        var result = new List<NativeSecurityChoice>();
        var error = Abi.Init<tidyvnc_error>();
        for (uint index = 0; index < 32; index++)
        {
            var value = Abi.Init<tidyvnc_security_choice>();
            if (Abi.Check(NativeMethods.tidyvnc_security_choice_at(index, &value, &error), &error, NativeStatus.Ok, NativeStatus.NoChange) == NativeStatus.NoChange)
                return result;
            if (!Enum.IsDefined((NativeSecurityChoice.ProtectionKind)value.protection) ||
                !Enum.IsDefined((NativeSecurityChoice.CredentialKind)value.credentials))
                throw new NativeError(NativeStatus.Unsupported, "Unknown security metadata");
            result.Add(new NativeSecurityChoice(value.type, AbiText.Fixed(value.name, 32), value.available != 0,
                (NativeSecurityChoice.ProtectionKind)value.protection, (NativeSecurityChoice.CredentialKind)value.credentials, value.aes_bits));
        }
        throw new NativeError(NativeStatus.ResourceLimit, "Security catalog exceeds its limit");
    }
}

/// <summary>GnuTLS priority validation; may read library configuration, so never call it per keystroke on the UI thread.</summary>
public static class NativeTlsPriority
{
    public static unsafe void Validate(string text)
    {
        var bytes = AbiText.Utf8(text);
        if (bytes.Length > 4096) throw new NativeError(NativeStatus.ResourceLimit, "TLS priority is too long");
        var error = Abi.Init<tidyvnc_error>();
        fixed (byte* p = bytes)
            Abi.Check(NativeMethods.tidyvnc_tls_priority_validate(AbiText.Span(p, bytes.Length), &error), &error);
    }
}
