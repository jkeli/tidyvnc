// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Security.Cryptography;

namespace TidyVNC.Native.Credentials;

/// <summary>Typed credential-store outcomes (SERVICES.md section 3; NativeCredentialStoreIssue on macOS).</summary>
public enum NativeCredentialError
{
    NotFound, Unavailable, Denied, Invalid, Duplicate, Corrupt, TooLarge, Busy, Closed, Cancelled, SecretCleared, IOFailure,
}

/// <summary>A credential failure. Never carries a target name, user name or secret.</summary>
public sealed class NativeCredentialException(NativeCredentialError error, int nativeCode = 0) : Exception($"Credential {error}")
{
    public NativeCredentialError Error { get; } = error;
    /// <summary>The Win32 error for diagnostics only.</summary>
    public int NativeCode { get; } = nativeCode;
}

/// <summary>How long an entered password is kept (the authentication dialog's choices).</summary>
public enum NativeCredentialRetention { UseOnce, Session, Remember, ReplaceRemembered }

public enum NativeCredentialSaveMode { Create, Replace }

/// <summary>
/// One owned, pinned allocation holding secret bytes. Clearing zeroes it.
/// Copies made by the runtime, WinUI (PasswordBox strings), Credential
/// Manager or callers are outside this buffer's control; nothing here claims
/// to erase them (SERVICES.md section 3).
/// </summary>
public sealed class NativeCredentialSecret : IDisposable
{
    public const int MaximumBytes = 4096;
    private readonly Lock gate = new();
    private readonly byte[] storage;
    private int? count;

    private NativeCredentialSecret(byte[] storage, int count)
    {
        this.storage = storage;
        this.count = count;
    }

    /// <summary>Copies bytes into a new secret and wipes the input, including on failure.</summary>
    public static NativeCredentialSecret Consume(byte[] bytes)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        try
        {
            if (bytes.Length > MaximumBytes) throw new NativeCredentialException(NativeCredentialError.TooLarge);
            var storage = GC.AllocateUninitializedArray<byte>(Math.Max(bytes.Length, 1), pinned: true);
            bytes.CopyTo(storage, 0);
            return new NativeCredentialSecret(storage, bytes.Length);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    public bool IsCleared { get { lock (gate) return count is null; } }

    /// <summary>A copy the caller owns and must wipe after passing it on.</summary>
    public byte[] CopyBytes()
    {
        lock (gate)
        {
            if (count is not { } length) throw new NativeCredentialException(NativeCredentialError.SecretCleared);
            return storage.AsSpan(0, length).ToArray();
        }
    }

    /// <summary>Runs body over the bytes in place (the storage is pinned) under the secret's lock.</summary>
    internal T Use<T>(Func<IntPtr, int, T> body)
    {
        lock (gate)
        {
            if (count is not { } length) throw new NativeCredentialException(NativeCredentialError.SecretCleared);
            unsafe
            {
                fixed (byte* data = storage) return body((IntPtr)data, length);
            }
        }
    }

    public void Clear()
    {
        lock (gate)
        {
            CryptographicOperations.ZeroMemory(storage);
            count = null;
        }
    }

    public void Dispose() => Clear();
    public override string ToString() => "NativeCredentialSecret(<redacted>)";
}

/// <summary>
/// A saved-password account: the core's versioned credential identity
/// ("v1:" + 64 hex digits) over the canonical endpoint, route, negotiated
/// security type, authentication shape and user name. It names an entry; it
/// is not proof of trust, and holds no endpoint, route, user or secret text.
/// </summary>
public sealed class NativeCredentialKey : IEquatable<NativeCredentialKey>
{
    private NativeCredentialKey(string account) => Account = account;

    public string Account { get; }
    /// <summary>The 64 lowercase hex digits after "v1:".</summary>
    public string Digest => Account[3..];

    /// <summary>Throws <see cref="NativeIdentityFailure"/> for invalid input or a non-credential security type.</summary>
    public static NativeCredentialKey Create(string endpoint, string routeIdentity, uint securityType, bool usernameRequired,
                                            string username = "", bool allowUnixSockets = true)
        => new(NativeIdentity.CredentialAccount(endpoint, routeIdentity, securityType,
            usernameRequired ? NativeCredentialShape.UsernamePassword : NativeCredentialShape.PasswordOnly,
            usernameRequired ? username : "", allowUnixSockets));

    public static NativeCredentialKey? FromDigest(string digest)
        => digest.Length == 64 && digest.All(char.IsAsciiHexDigitLower) ? new("v1:" + digest) : null;

    public bool Equals(NativeCredentialKey? other) => other is not null && string.Equals(Account, other.Account, StringComparison.Ordinal);
    public override bool Equals(object? obj) => Equals(obj as NativeCredentialKey);
    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(Account);
    public override string ToString() => "NativeCredentialKey(<redacted>)";
}

public sealed record NativeCredentialMetadata(NativeCredentialKey Key, DateTimeOffset? Modified);

public sealed record NativeCredentialMetadataPage(IReadOnlyList<NativeCredentialMetadata> Entries, bool HasMore);
