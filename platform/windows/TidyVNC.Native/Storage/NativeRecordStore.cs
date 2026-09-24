// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Text.Json;

namespace TidyVNC.Native.Storage;

/// <summary>A record as read: Revision is null when no record exists yet.</summary>
public sealed record NativeRecordSnapshot<T>(Guid? Revision, T Value)
{
    public bool IsStored => Revision is not null;
}

/// <summary>
/// A versioned JSON record in the state directory (SERVICES.md section 2):
/// "schema" and "revision" plus the record's own fields, strictly validated
/// (unknown fields are UnsupportedFields, wrong types Corrupt). Writes take the
/// cross-process writer lock, re-read, compare revisions (Conflict on a
/// mismatch), and replace the file atomically with a fresh revision. A corrupt
/// record is never treated as absent and is replaced only on explicit request;
/// a newer schema is read-only and never overwritten. All IO runs off the
/// calling thread; cancellation is checked before a write is admitted and an
/// admitted write always completes.
/// </summary>
public abstract class NativeRecordStore<T> : IDisposable
{
    private readonly SemaphoreSlim serial = new(1, 1);
    private bool closed;

    protected NativeRecordStore(string directory, string fileName)
    {
        Directory = directory;
        Path = System.IO.Path.Combine(directory, fileName);
    }

    public string Directory { get; }
    public string Path { get; }

    /// <summary>The newest schema this build writes.</summary>
    protected abstract int Schema { get; }
    protected virtual int MaximumBytes => 4 * 1024 * 1024;
    protected virtual TimeSpan LockTimeout => TimeSpan.FromSeconds(10);
    /// <summary>The value of an absent record.</summary>
    protected abstract T Empty { get; }
    /// <summary>Validates and decodes the record fields other than schema and revision.</summary>
    protected abstract T Decode(JsonElement record, int schema);
    /// <summary>Writes the record fields other than schema and revision.</summary>
    protected abstract void Encode(Utf8JsonWriter writer, T value);

    protected static NativeStorageException Corrupt() => new(NativeStorageError.Corrupt);

    /// <summary>Only the listed properties may appear (besides schema and revision).</summary>
    protected static void RequireOnly(JsonElement element, params string[] allowed)
    {
        if (element.ValueKind != JsonValueKind.Object) throw Corrupt();
        foreach (var property in element.EnumerateObject())
            if (property.Name is not ("schema" or "revision") && Array.IndexOf(allowed, property.Name) < 0)
                throw new NativeStorageException(NativeStorageError.UnsupportedFields);
    }

    public Task<NativeRecordSnapshot<T>> ReadAsync(CancellationToken cancellation = default)
        => Run(() => ReadNow(), cancellation);

    public Task<NativeRecordSnapshot<T>> CommitAsync(T value, Guid? expected, CancellationToken cancellation = default)
        => Run(() => Write(value, expected, recovery: false), cancellation);

    /// <summary>
    /// Explicit recovery: replaces a corrupt or unsupported record. A valid
    /// record is a Conflict (use CommitAsync); a newer schema is never replaced.
    /// </summary>
    public Task<NativeRecordSnapshot<T>> ReplaceCorruptAsync(T value, CancellationToken cancellation = default)
        => Run(() => Write(value, null, recovery: true), cancellation);

    public async Task CloseAsync()
    {
        await serial.WaitAsync().ConfigureAwait(false);
        closed = true;
        serial.Release();
    }

    public void Dispose()
    {
        serial.Dispose();
        GC.SuppressFinalize(this);
    }

    private async Task<TResult> Run<TResult>(Func<TResult> body, CancellationToken cancellation)
    {
        try { await serial.WaitAsync(cancellation).ConfigureAwait(false); }
        catch (OperationCanceledException) { throw new NativeStorageException(NativeStorageError.Cancelled); }
        try
        {
            if (closed) throw new NativeStorageException(NativeStorageError.Closed);
            if (cancellation.IsCancellationRequested) throw new NativeStorageException(NativeStorageError.Cancelled);
            return await Task.Run(body, CancellationToken.None).ConfigureAwait(false);
        }
        finally
        {
            serial.Release();
        }
    }

    private NativeRecordSnapshot<T> ReadNow()
    {
        if (!System.IO.Directory.Exists(Directory)) return new(null, Empty);
        NativePrivateFiles.CheckPrivate(new DirectoryInfo(Directory));
        var bytes = NativePrivateFiles.Read(Path, MaximumBytes);
        return bytes is null ? new(null, Empty) : Parse(bytes);
    }

    private NativeRecordSnapshot<T> Parse(byte[] bytes)
    {
        JsonDocument document;
        try { document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 32, CommentHandling = JsonCommentHandling.Disallow }); }
        catch (JsonException) { throw Corrupt(); }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("schema", out var schemaValue) || schemaValue.ValueKind != JsonValueKind.Number ||
                !schemaValue.TryGetInt32(out var schema) || schema < 1)
                throw Corrupt();
            if (schema > Schema) throw new NativeStorageException(NativeStorageError.FutureSchema);
            if (!root.TryGetProperty("revision", out var revisionValue) || revisionValue.ValueKind != JsonValueKind.String ||
                !Guid.TryParseExact(revisionValue.GetString(), "D", out var revision))
                throw Corrupt();
            try { return new(revision, Decode(root, schema)); }
            catch (InvalidOperationException) { throw Corrupt(); }
            catch (FormatException) { throw Corrupt(); }
        }
    }

    private NativeRecordSnapshot<T> Write(T value, Guid? expected, bool recovery)
    {
        NativePrivateFiles.EnsureDirectory(Directory);
        var encoded = Serialize(value, out var revision);
        // Validate our own output before it can replace anything.
        var parsed = Parse(encoded);
        return NativePrivateFiles.WithWriterLock(Path, LockTimeout, () =>
        {
            NativeRecordSnapshot<T> current;
            try { current = ReadNow(); }
            catch (NativeStorageException error) when (recovery && error.Error is NativeStorageError.Corrupt or NativeStorageError.UnsupportedFields)
            {
                current = new(null, Empty); // The damaged record is what recovery replaces.
            }
            if (recovery ? current.IsStored : current.Revision != expected)
                throw new NativeStorageException(NativeStorageError.Conflict);
            NativePrivateFiles.Replace(Path, encoded);
            return new NativeRecordSnapshot<T>(revision, parsed.Value);
        });
    }

    private byte[] Serialize(T value, out Guid revision)
    {
        revision = Guid.NewGuid();
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true }))
        {
            writer.WriteStartObject();
            writer.WriteNumber("schema", Schema);
            writer.WriteString("revision", revision.ToString("D"));
            Encode(writer, value);
            writer.WriteEndObject();
        }
        return buffer.ToArray();
    }
}
