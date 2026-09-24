// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Security.Credentials;

namespace TidyVNC.Native.Credentials;

/// <summary>
/// A synchronous credential backend, called on the store's worker only. It
/// must report the committed outcome even when cancellation arrives during IO.
/// </summary>
public interface INativeCredentialBacking
{
    NativeCredentialSecret Lookup(NativeCredentialKey key);
    void Save(NativeCredentialKey key, NativeCredentialSecret secret, NativeCredentialSaveMode mode);
    void Delete(NativeCredentialKey key);
    NativeCredentialMetadataPage List(int limit);
}

/// <summary>
/// Windows Credential Manager generic credentials (DECISIONS.md D15,
/// SERVICES.md section 3): target "TidyVNC/credentials.v1/&lt;digest&gt;",
/// CRED_PERSIST_LOCAL_MACHINE, empty user name, UTF-8 password blob of at
/// most 2560 bytes and a fixed comment. Credential Manager never shows UI.
/// DPAPI protects entries from other users, not from other programs running
/// as this user.
/// </summary>
public sealed unsafe class NativeCredentialManagerBacking : INativeCredentialBacking
{
    public const string DefaultPrefix = "TidyVNC/credentials.v1/";
    public const string Comment = "TidyVNC saved password";
    public const int MaximumBlobBytes = (int)PInvoke.CRED_MAX_CREDENTIAL_BLOB_SIZE;

    private readonly string prefix;

    /// <summary>
    /// Null uses the state root's prefix (DefaultPrefix, or the isolated test
    /// prefix under TIDYVNC_STATE_ROOT in Debug builds); tests may pass their own.
    /// </summary>
    public NativeCredentialManagerBacking(string? prefix = null)
    {
        prefix ??= TidyVNC.Native.Storage.NativeStateRoot.CredentialPrefix;
        if (prefix.Length is 0 or > 256 || prefix.Contains('*', StringComparison.Ordinal)) throw new ArgumentException("Invalid prefix", nameof(prefix));
        this.prefix = prefix;
    }

    /// <summary>The service result for a Win32 error (SERVICES.md section 3 table).</summary>
    public static NativeCredentialError Classify(int win32) => (WIN32_ERROR)win32 switch
    {
        WIN32_ERROR.ERROR_NOT_FOUND => NativeCredentialError.NotFound,
        WIN32_ERROR.ERROR_NO_SUCH_LOGON_SESSION => NativeCredentialError.Unavailable,
        WIN32_ERROR.ERROR_INVALID_PARAMETER or WIN32_ERROR.ERROR_INVALID_FLAGS or WIN32_ERROR.ERROR_BAD_USERNAME => NativeCredentialError.Invalid,
        WIN32_ERROR.ERROR_ACCESS_DENIED => NativeCredentialError.Denied,
        _ => NativeCredentialError.IOFailure,
    };

    private static NativeCredentialException Failure()
    {
        var code = Marshal.GetLastPInvokeError();
        return new NativeCredentialException(Classify(code), code);
    }

    private string Target(NativeCredentialKey key) => prefix + key.Digest;

    public NativeCredentialSecret Lookup(NativeCredentialKey key)
    {
        CREDENTIALW* credential = null;
        fixed (char* target = Target(key))
            if (!PInvoke.CredRead(target, CRED_TYPE.CRED_TYPE_GENERIC, 0, &credential)) throw Failure();
        try
        {
            var size = (int)credential->CredentialBlobSize;
            if (size > MaximumBlobBytes || (size > 0 && credential->CredentialBlob is null))
                throw new NativeCredentialException(NativeCredentialError.Corrupt);
            var copy = new byte[size];
            new ReadOnlySpan<byte>(credential->CredentialBlob, size).CopyTo(copy);
            return NativeCredentialSecret.Consume(copy);
        }
        finally
        {
            if (credential->CredentialBlob is not null)
                new Span<byte>(credential->CredentialBlob, (int)Math.Min(credential->CredentialBlobSize, (uint)MaximumBlobBytes)).Clear();
            PInvoke.CredFree(credential);
        }
    }

    private bool Exists(NativeCredentialKey key)
    {
        CREDENTIALW* credential = null;
        fixed (char* target = Target(key))
        {
            if (PInvoke.CredRead(target, CRED_TYPE.CRED_TYPE_GENERIC, 0, &credential))
            {
                PInvoke.CredFree(credential);
                return true;
            }
        }
        var failure = Failure();
        return failure.Error == NativeCredentialError.NotFound ? false : throw failure;
    }

    /// <summary>
    /// Create refuses an existing entry (Duplicate). Credential Manager has no
    /// create-only write, so a concurrent creator between the check and the
    /// write wins last; both wrote a password that authenticated.
    /// </summary>
    public void Save(NativeCredentialKey key, NativeCredentialSecret secret, NativeCredentialSaveMode mode)
    {
        if (mode == NativeCredentialSaveMode.Create && Exists(key)) throw new NativeCredentialException(NativeCredentialError.Duplicate);
        secret.Use((data, length) =>
        {
            if (length > MaximumBlobBytes) throw new NativeCredentialException(NativeCredentialError.Invalid);
            fixed (char* target = Target(key)) fixed (char* comment = Comment)
            {
                var credential = new CREDENTIALW
                {
                    Type = CRED_TYPE.CRED_TYPE_GENERIC,
                    TargetName = target,
                    Comment = comment,
                    CredentialBlobSize = (uint)length,
                    CredentialBlob = (byte*)data,
                    Persist = CRED_PERSIST.CRED_PERSIST_LOCAL_MACHINE,
                };
                if (!PInvoke.CredWrite(&credential, 0)) throw Failure();
            }
            return true;
        });
    }

    public void Delete(NativeCredentialKey key)
    {
        fixed (char* target = Target(key))
            if (!PInvoke.CredDelete(target, CRED_TYPE.CRED_TYPE_GENERIC, 0)) throw Failure();
    }

    /// <summary>This app's entries in target-name order; foreign or malformed targets under the prefix are skipped.</summary>
    public NativeCredentialMetadataPage List(int limit)
    {
        uint count = 0;
        CREDENTIALW** credentials = null;
        fixed (char* filter = prefix + "*")
        {
            if (!PInvoke.CredEnumerate(filter, 0, &count, &credentials))
            {
                var failure = Failure();
                return failure.Error == NativeCredentialError.NotFound ? new([], false) : throw failure;
            }
        }
        try
        {
            var entries = new List<NativeCredentialMetadata>();
            for (var i = 0; i < count; ++i)
            {
                var credential = credentials[i];
                if (credential->Type != CRED_TYPE.CRED_TYPE_GENERIC) continue;
                var target = credential->TargetName.ToString();
                if (!target.StartsWith(prefix, StringComparison.Ordinal) || NativeCredentialKey.FromDigest(target[prefix.Length..]) is not { } key) continue;
                var written = (long)(((ulong)(uint)credential->LastWritten.dwHighDateTime << 32) | (uint)credential->LastWritten.dwLowDateTime);
                entries.Add(new(key, written > 0 ? DateTimeOffset.FromFileTime(written) : null));
            }
            entries.Sort((a, b) => string.CompareOrdinal(a.Key.Account, b.Key.Account));
            return new(entries.Take(limit).ToList(), entries.Count > limit);
        }
        finally
        {
            PInvoke.CredFree(credentials);
        }
    }
}

/// <summary>
/// The async credential service (NativeCredentialStore on macOS): one worker
/// at a time, at most 16 waiting callers, cancellation before admission only
/// (an admitted operation always completes and reports its outcome), and a
/// close that refuses new work and drains admitted work.
/// </summary>
public sealed class NativeCredentialStore : IAsyncDisposable
{
    public const int MaximumPending = 16;

    private readonly INativeCredentialBacking backing;
    private readonly SemaphoreSlim serial = new(1, 1);
    private readonly Lock gate = new();
    private readonly TaskCompletionSource drained = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int pending;
    private bool closed;

    public NativeCredentialStore(INativeCredentialBacking? backing = null) => this.backing = backing ?? new NativeCredentialManagerBacking();

    public Task<NativeCredentialSecret> LookupAsync(NativeCredentialKey key, CancellationToken cancellation = default)
        => Perform(b => b.Lookup(key), cancellation);

    public Task SaveAsync(NativeCredentialKey key, NativeCredentialSecret secret, NativeCredentialSaveMode mode = NativeCredentialSaveMode.Create,
                          CancellationToken cancellation = default)
        => Perform(b => { b.Save(key, secret, mode); return true; }, cancellation);

    public Task DeleteAsync(NativeCredentialKey key, CancellationToken cancellation = default)
        => Perform(b => { b.Delete(key); return true; }, cancellation);

    public Task<NativeCredentialMetadataPage> ListAsync(int limit = 128, CancellationToken cancellation = default)
        => limit is >= 1 and <= 256 ? Perform(b => b.List(limit), cancellation)
                                    : Task.FromException<NativeCredentialMetadataPage>(new NativeCredentialException(NativeCredentialError.TooLarge));

    internal int PendingCount { get { lock (gate) return pending; } }

    private async Task<T> Perform<T>(Func<INativeCredentialBacking, T> body, CancellationToken cancellation)
    {
        lock (gate)
        {
            if (closed) throw new NativeCredentialException(NativeCredentialError.Closed);
            if (cancellation.IsCancellationRequested) throw new NativeCredentialException(NativeCredentialError.Cancelled);
            if (pending >= MaximumPending) throw new NativeCredentialException(NativeCredentialError.Busy);
            ++pending;
        }
        try
        {
            try { await serial.WaitAsync(cancellation).ConfigureAwait(false); }
            catch (OperationCanceledException) { throw new NativeCredentialException(NativeCredentialError.Cancelled); }
            try
            {
                lock (gate)
                {
                    // Close cancels work that has not started; started work finishes.
                    if (closed || cancellation.IsCancellationRequested) throw new NativeCredentialException(NativeCredentialError.Cancelled);
                }
                return await Task.Run(() =>
                {
                    try { return body(backing); }
                    catch (NativeCredentialException) { throw; }
                    catch (Exception error) when (error is not OutOfMemoryException)
                    {
                        throw new NativeCredentialException(NativeCredentialError.IOFailure);
                    }
                }, CancellationToken.None).ConfigureAwait(false);
            }
            finally
            {
                serial.Release();
            }
        }
        finally
        {
            lock (gate)
            {
                if (--pending == 0 && closed) drained.TrySetResult();
            }
        }
    }

    /// <summary>Refuses new work, cancels queued work and waits for admitted work to finish.</summary>
    public async Task CloseAsync()
    {
        lock (gate)
        {
            closed = true;
            if (pending == 0) drained.TrySetResult();
        }
        await drained.Task.ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        await CloseAsync().ConfigureAwait(false);
        serial.Dispose();
    }
}
