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
public enum NativeCredentialRetention { UseOnce, Session, Remember }

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

    /// <summary>A stored account ("v1:" + digest), or null when it is not one.</summary>
    public static NativeCredentialKey? FromAccount(string account)
        => account.StartsWith("v1:", StringComparison.Ordinal) ? FromDigest(account[3..]) : null;

    public bool Equals(NativeCredentialKey? other) => other is not null && string.Equals(Account, other.Account, StringComparison.Ordinal);
    public override bool Equals(object? obj) => Equals(obj as NativeCredentialKey);
    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(Account);
    public override string ToString() => "NativeCredentialKey(<redacted>)";
}

/// <summary>
/// Approval to reuse an existing saved password without asking (macOS
/// NativeCredentialApproval). It holds no password: the exact credential
/// account, the username that last succeeded and the credential-protection
/// assessment it was accepted under. It is stored apart from passwords, under
/// the scope key (the prompt's destination, route and method with no username).
/// </summary>
public sealed class NativeCredentialApproval : IEquatable<NativeCredentialApproval>
{
    public const int Version = 1;

    public NativeCredentialApproval(NativeCredentialKey key, string username, bool secure)
    {
        Account = key.Account;
        Username = username;
        Secure = secure;
    }

    private NativeCredentialApproval(string account, string username, bool secure)
    {
        Account = account;
        Username = username;
        Secure = secure;
    }

    public string Account { get; }
    public string Username { get; }
    public bool Secure { get; }

    /// <summary>The saved password this approval reuses.</summary>
    public NativeCredentialKey Key => NativeCredentialKey.FromAccount(Account) ?? throw new NativeCredentialException(NativeCredentialError.Corrupt);

    public void Validate()
    {
        if (System.Text.Encoding.UTF8.GetByteCount(Username) > NativeCredentialSecret.MaximumBytes || Username.Contains('\0', StringComparison.Ordinal))
            throw new NativeCredentialException(NativeCredentialError.Corrupt);
        _ = Key;
    }

    /// <summary>Versioned JSON: {"version":1,"account":…,"username":…,"secure":…}.</summary>
    public byte[] Serialize()
    {
        Validate();
        using var buffer = new MemoryStream();
        using (var writer = new System.Text.Json.Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteNumber("version", Version);
            writer.WriteString("account", Account);
            writer.WriteString("username", Username);
            writer.WriteBoolean("secure", Secure);
            writer.WriteEndObject();
        }
        return buffer.ToArray();
    }

    /// <summary>Throws Corrupt for anything but a valid version 1 record.</summary>
    public static NativeCredentialApproval Parse(ReadOnlySpan<byte> data)
    {
        try
        {
            var reader = new System.Text.Json.Utf8JsonReader(data);
            using var document = System.Text.Json.JsonDocument.ParseValue(ref reader);
            var root = document.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Object || root.GetProperty("version").GetInt32() != Version)
                throw new NativeCredentialException(NativeCredentialError.Corrupt);
            static string Text(System.Text.Json.JsonElement value) => value.ValueKind == System.Text.Json.JsonValueKind.String
                ? value.GetString()! : throw new NativeCredentialException(NativeCredentialError.Corrupt);
            var approval = new NativeCredentialApproval(Text(root.GetProperty("account")), Text(root.GetProperty("username")),
                root.GetProperty("secure").GetBoolean());
            approval.Validate();
            return approval;
        }
        catch (Exception error) when (error is System.Text.Json.JsonException or InvalidOperationException or KeyNotFoundException
                                          or FormatException or ArgumentException)
        {
            throw new NativeCredentialException(NativeCredentialError.Corrupt);
        }
    }

    public bool Equals(NativeCredentialApproval? other) =>
        other is not null && Account == other.Account && Username == other.Username && Secure == other.Secure;
    public override bool Equals(object? obj) => Equals(obj as NativeCredentialApproval);
    public override int GetHashCode() => HashCode.Combine(Account, Username, Secure);
    public override string ToString() => "NativeCredentialApproval(<redacted>)";
}

/// <summary>An approved saved password, ready for automatic submission; the caller owns and clears the secret.</summary>
public sealed record NativeAutomaticCredential(NativeCredentialApproval Approval, NativeCredentialSecret Secret);

public sealed record NativeCredentialMetadata(NativeCredentialKey Key, DateTimeOffset? Modified);

public sealed record NativeCredentialMetadataPage(IReadOnlyList<NativeCredentialMetadata> Entries, bool HasMore);
