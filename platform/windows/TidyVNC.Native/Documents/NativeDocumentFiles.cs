// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Storage.FileSystem;

namespace TidyVNC.Native.Documents;

public enum NativeDocumentOpenError { Unreadable, NotRegular, TooLarge, Changed, Cancelled }

public sealed class NativeDocumentOpenException(NativeDocumentOpenError error) : Exception($"Connection file open: {error}")
{
    public NativeDocumentOpenError Error { get; } = error;
}

public enum NativeDocumentSaveError { InvalidDestination, Denied, Changed, OverwriteRequired, Busy, WriteFailed, CommittedUncertain, Cancelled }

public sealed class NativeDocumentSaveException(NativeDocumentSaveError error, int nativeCode = 0) : Exception($"Connection file save: {error}")
{
    public NativeDocumentSaveError Error { get; } = error;
    public int NativeCode { get; } = nativeCode;
}

/// <summary>What a file handle says about a file: identity and the metadata a concurrent editor changes.</summary>
internal readonly record struct NativeFileIdentity(ulong Volume, ulong Index, long Size, long Written, long Changed, uint Links, uint Attributes);

internal static unsafe class NativeFileHandles
{
    public const uint GenericRead = 0x80000000;
    public const uint FileReadAttributes = 0x80;
    public const uint FileGenericRead = 0x00120089;

    public static SafeFileHandle Open(string path, uint access, FILE_SHARE_MODE share, bool directory = false)
        => PInvoke.CreateFile(path, access, share, null, FILE_CREATION_DISPOSITION.OPEN_EXISTING,
            FILE_FLAGS_AND_ATTRIBUTES.FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAGS_AND_ATTRIBUTES.FILE_FLAG_BACKUP_SEMANTICS, null);

    public static NativeFileIdentity? Identity(SafeFileHandle handle)
    {
        BY_HANDLE_FILE_INFORMATION info;
        FILE_BASIC_INFO basic;
        var raw = (HANDLE)handle.DangerousGetHandle();
        if (!PInvoke.GetFileInformationByHandle(raw, &info) ||
            !PInvoke.GetFileInformationByHandleEx(raw, FILE_INFO_BY_HANDLE_CLASS.FileBasicInfo, &basic, (uint)sizeof(FILE_BASIC_INFO)))
            return null;
        return new(info.dwVolumeSerialNumber, ((ulong)info.nFileIndexHigh << 32) | info.nFileIndexLow,
            (long)(((ulong)info.nFileSizeHigh << 32) | info.nFileSizeLow), basic.LastWriteTime, basic.ChangeTime, info.nNumberOfLinks, basic.FileAttributes);
    }

    public const uint Excluded = (uint)(FILE_FLAGS_AND_ATTRIBUTES.FILE_ATTRIBUTE_REPARSE_POINT | FILE_FLAGS_AND_ATTRIBUTES.FILE_ATTRIBUTE_DIRECTORY |
                                        FILE_FLAGS_AND_ATTRIBUTES.FILE_ATTRIBUTE_DEVICE);
}

public interface INativeDocumentReader
{
    Task<byte[]> ReadAsync(string path, CancellationToken cancellation);
}

/// <summary>
/// Bounded connection-file reads off the UI thread (SERVICES.md section 4):
/// one regular disk file opened without following reparse points, at most the
/// shared 1 MiB document limit, with before/after identity checks. Pipes,
/// devices and directories are refused without a blocking read.
/// </summary>
public sealed class NativeDocumentFileReader : INativeDocumentReader
{
    public Task<byte[]> ReadAsync(string path, CancellationToken cancellation)
        => cancellation.IsCancellationRequested ? Task.FromException<byte[]>(new NativeDocumentOpenException(NativeDocumentOpenError.Cancelled))
                                                : Task.Run(() => Read(path, cancellation), CancellationToken.None);

    private static byte[] Read(string path, CancellationToken cancellation)
    {
        void Check() { if (cancellation.IsCancellationRequested) throw new NativeDocumentOpenException(NativeDocumentOpenError.Cancelled); }
        if (!Path.IsPathFullyQualified(path) || path.Contains('\0', StringComparison.Ordinal)) throw new NativeDocumentOpenException(NativeDocumentOpenError.Unreadable);
        using var handle = NativeFileHandles.Open(path, NativeFileHandles.FileGenericRead,
            FILE_SHARE_MODE.FILE_SHARE_READ | FILE_SHARE_MODE.FILE_SHARE_WRITE | FILE_SHARE_MODE.FILE_SHARE_DELETE);
        if (handle.IsInvalid) throw new NativeDocumentOpenException(NativeDocumentOpenError.Unreadable);
        if (PInvoke.GetFileType(handle) != FILE_TYPE.FILE_TYPE_DISK) throw new NativeDocumentOpenException(NativeDocumentOpenError.NotRegular);
        var before = NativeFileHandles.Identity(handle) ?? throw new NativeDocumentOpenException(NativeDocumentOpenError.Unreadable);
        if ((before.Attributes & NativeFileHandles.Excluded) != 0) throw new NativeDocumentOpenException(NativeDocumentOpenError.NotRegular);
        if (before.Size > NativeConnectionDocument.MaximumBytes) throw new NativeDocumentOpenException(NativeDocumentOpenError.TooLarge);
        var data = new byte[before.Size];
        for (var offset = 0; offset < data.Length;)
        {
            Check();
            int count;
            try { count = RandomAccess.Read(handle, data.AsSpan(offset), offset); }
            catch (IOException) { throw new NativeDocumentOpenException(NativeDocumentOpenError.Unreadable); }
            if (count == 0) throw new NativeDocumentOpenException(NativeDocumentOpenError.Changed);
            offset += count;
        }
        if (NativeFileHandles.Identity(handle) != before) throw new NativeDocumentOpenException(NativeDocumentOpenError.Changed);
        Check();
        return data;
    }
}

/// <summary>A save destination as chosen in the dialog: the folder and, when the file exists, its identity.</summary>
public sealed class NativeDocumentDestination
{
    internal NativeDocumentDestination(string path, Guid writer, NativeFileIdentity folder, NativeFileIdentity? file)
    {
        Path = path; Writer = writer; Folder = folder; File = file;
    }

    public string Path { get; }
    public bool Exists => File is not null;
    internal Guid Writer { get; }
    internal NativeFileIdentity Folder { get; }
    internal NativeFileIdentity? File { get; }
    public override string ToString() => "NativeDocumentDestination(<redacted>)";
}

public interface INativeDocumentWriter
{
    Task<NativeDocumentDestination> PrepareAsync(string path, CancellationToken cancellation = default);
    Task WriteAsync(byte[] data, NativeDocumentDestination destination, bool overwrite, CancellationToken cancellation = default);
}

/// <summary>
/// Atomic connection-file saves (SERVICES.md section 4; NativeDocumentFileWriter
/// on macOS). The destination is a .tidyvnc file in an existing folder; an
/// existing destination must be a regular single-link file the user can write.
/// The write takes a per-folder writer lock, rechecks that neither the folder
/// nor the file changed since the dialog, writes a flushed temporary file
/// beside it and replaces the destination with ReplaceFileW (or a no-replace
/// move for a new file). Documents keep the folder's inherited access control.
/// Replacement is atomic, not a compare-and-swap against editors that do not
/// cooperate; the recheck immediately before it narrows that window.
/// </summary>
public sealed class NativeDocumentFileWriter : INativeDocumentWriter
{
    public const string Extension = ".tidyvnc";
    private readonly Guid id = Guid.NewGuid();
    private readonly Action<string>? checkpoint;

    public NativeDocumentFileWriter() { }

    /// <summary>Tests: called with "written", "willReplace" and "didReplace".</summary>
    internal NativeDocumentFileWriter(Action<string> checkpoint) => this.checkpoint = checkpoint;

    private static NativeDocumentSaveException Failure()
    {
        var code = Marshal.GetLastPInvokeError();
        return new NativeDocumentSaveException(code switch
        {
            5 or 19 or 32 => NativeDocumentSaveError.Denied, // ACCESS_DENIED, WRITE_PROTECT, SHARING_VIOLATION
            2 or 3 or 123 or 206 or 267 => NativeDocumentSaveError.InvalidDestination, // not found, bad name, too long, not a directory
            _ => NativeDocumentSaveError.WriteFailed,
        }, code);
    }

    private static void Validate(string path)
    {
        if (!Path.IsPathFullyQualified(path) || path.Contains('\0', StringComparison.Ordinal) || path.Length > short.MaxValue ||
            !string.Equals(Path.GetExtension(path), Extension, StringComparison.OrdinalIgnoreCase) ||
            Path.GetFileName(path) is not { Length: > 0 and <= 255 } || Path.EndsInDirectorySeparator(path))
            throw new NativeDocumentSaveException(NativeDocumentSaveError.InvalidDestination);
    }

    private static NativeFileIdentity FolderIdentity(string path)
    {
        var folder = Path.GetDirectoryName(path) ?? throw new NativeDocumentSaveException(NativeDocumentSaveError.InvalidDestination);
        using var handle = NativeFileHandles.Open(folder, NativeFileHandles.FileReadAttributes,
            FILE_SHARE_MODE.FILE_SHARE_READ | FILE_SHARE_MODE.FILE_SHARE_WRITE | FILE_SHARE_MODE.FILE_SHARE_DELETE);
        if (handle.IsInvalid) throw Failure();
        var identity = NativeFileHandles.Identity(handle) ?? throw Failure();
        const uint directory = (uint)FILE_FLAGS_AND_ATTRIBUTES.FILE_ATTRIBUTE_DIRECTORY, reparse = (uint)FILE_FLAGS_AND_ATTRIBUTES.FILE_ATTRIBUTE_REPARSE_POINT;
        if ((identity.Attributes & directory) == 0 || (identity.Attributes & reparse) != 0)
            throw new NativeDocumentSaveException(NativeDocumentSaveError.InvalidDestination);
        return identity;
    }

    private static NativeFileIdentity? FileIdentity(string path)
    {
        using var handle = NativeFileHandles.Open(path, NativeFileHandles.FileReadAttributes,
            FILE_SHARE_MODE.FILE_SHARE_READ | FILE_SHARE_MODE.FILE_SHARE_WRITE | FILE_SHARE_MODE.FILE_SHARE_DELETE);
        if (handle.IsInvalid)
        {
            var code = Marshal.GetLastPInvokeError();
            if (code == 2) return null; // ERROR_FILE_NOT_FOUND
            throw Failure();
        }
        if (PInvoke.GetFileType(handle) != FILE_TYPE.FILE_TYPE_DISK) throw new NativeDocumentSaveException(NativeDocumentSaveError.InvalidDestination);
        var identity = NativeFileHandles.Identity(handle) ?? throw Failure();
        if ((identity.Attributes & NativeFileHandles.Excluded) != 0 || identity.Links != 1)
            throw new NativeDocumentSaveException(NativeDocumentSaveError.InvalidDestination);
        if ((identity.Attributes & (uint)FILE_FLAGS_AND_ATTRIBUTES.FILE_ATTRIBUTE_READONLY) != 0)
            throw new NativeDocumentSaveException(NativeDocumentSaveError.Denied);
        return identity;
    }

    public Task<NativeDocumentDestination> PrepareAsync(string path, CancellationToken cancellation = default)
    {
        if (cancellation.IsCancellationRequested) return Task.FromException<NativeDocumentDestination>(new NativeDocumentSaveException(NativeDocumentSaveError.Cancelled));
        return Task.Run(() =>
        {
            Validate(path);
            var folder = FolderIdentity(path);
            return new NativeDocumentDestination(path, id, folder, FileIdentity(path));
        }, CancellationToken.None);
    }

    /// <summary>The same folder object (writes inside it change its times, not its identity).</summary>
    private static bool SameFolder(NativeFileIdentity a, NativeFileIdentity b) => a.Volume == b.Volume && a.Index == b.Index;

    /// <summary>A per-folder lock shared by every TidyVNC process for this user session.</summary>
    private static Mutex FolderLock(NativeFileIdentity folder)
    {
        var name = $"Local\\TidyVNC-document-{folder.Volume:x8}-{folder.Index:x16}";
        return new Mutex(false, name);
    }

    public Task WriteAsync(byte[] data, NativeDocumentDestination destination, bool overwrite, CancellationToken cancellation = default)
    {
        if (cancellation.IsCancellationRequested) return Task.FromException(new NativeDocumentSaveException(NativeDocumentSaveError.Cancelled));
        return Task.Run(() => Write(data, destination, overwrite, cancellation), CancellationToken.None);
    }

    private unsafe void Write(byte[] data, NativeDocumentDestination destination, bool overwrite, CancellationToken cancellation)
    {
        if (data.Length > NativeConnectionDocument.MaximumBytes) throw new NativeDocumentSaveException(NativeDocumentSaveError.WriteFailed);
        if (destination.Writer != id) throw new NativeDocumentSaveException(NativeDocumentSaveError.Changed);
        if (destination.Exists && !overwrite) throw new NativeDocumentSaveException(NativeDocumentSaveError.OverwriteRequired);
        var path = destination.Path;
        Validate(path);
        if (!SameFolder(FolderIdentity(path), destination.Folder)) throw new NativeDocumentSaveException(NativeDocumentSaveError.Changed);
        using var folderLock = FolderLock(destination.Folder);
        bool held;
        try { held = folderLock.WaitOne(0); }
        catch (AbandonedMutexException) { held = true; }
        if (!held) throw new NativeDocumentSaveException(NativeDocumentSaveError.Busy);
        try
        {
            if (FileIdentity(path) != destination.File) throw new NativeDocumentSaveException(NativeDocumentSaveError.Changed);
            var folder = Path.GetDirectoryName(path)!;
            var temporary = Path.Combine(folder, $".tidyvnc-export-{Guid.NewGuid():N}.tmp");
            var committed = false;
            try
            {
                try
                {
                    using var output = new FileStream(temporary, new FileStreamOptions
                    {
                        Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None, Options = FileOptions.WriteThrough,
                    });
                    for (var offset = 0; offset < data.Length; offset += 16384)
                    {
                        if (cancellation.IsCancellationRequested) throw new NativeDocumentSaveException(NativeDocumentSaveError.Cancelled);
                        output.Write(data, offset, Math.Min(16384, data.Length - offset));
                    }
                    checkpoint?.Invoke("written");
                    output.Flush(flushToDisk: true);
                }
                catch (UnauthorizedAccessException error) { throw new NativeDocumentSaveException(NativeDocumentSaveError.Denied, error.HResult); }
                catch (IOException error) { throw new NativeDocumentSaveException(NativeDocumentSaveError.WriteFailed, error.HResult); }
                checkpoint?.Invoke("willReplace");
                if (cancellation.IsCancellationRequested) throw new NativeDocumentSaveException(NativeDocumentSaveError.Cancelled);
                // Last checks: neither the file nor the folder may have changed or been redirected.
                if (FileIdentity(path) != destination.File || !SameFolder(FolderIdentity(path), destination.Folder))
                    throw new NativeDocumentSaveException(NativeDocumentSaveError.Changed);
                bool replaced;
                fixed (char* target = path) fixed (char* source = temporary)
                {
                    replaced = destination.Exists
                        ? PInvoke.ReplaceFile(target, source, null, REPLACE_FILE_FLAGS.REPLACEFILE_IGNORE_MERGE_ERRORS | REPLACE_FILE_FLAGS.REPLACEFILE_IGNORE_ACL_ERRORS)
                        : PInvoke.MoveFileEx(source, target, MOVE_FILE_FLAGS.MOVEFILE_WRITE_THROUGH);
                }
                if (!replaced)
                {
                    var code = Marshal.GetLastPInvokeError();
                    if (code is 80 or 183) throw new NativeDocumentSaveException(NativeDocumentSaveError.Changed, code); // FILE_EXISTS, ALREADY_EXISTS
                    // ReplaceFileW 1176/1177 mean the destination may be in an intermediate state.
                    if (code is 1176 or 1177) throw new NativeDocumentSaveException(NativeDocumentSaveError.CommittedUncertain, code);
                    Marshal.SetLastPInvokeError(code);
                    throw Failure();
                }
                committed = true;
                // A successful replace cannot be rolled back; later failures never claim the old file survived.
                try { checkpoint?.Invoke("didReplace"); }
                catch (Exception error) when (error is not OutOfMemoryException)
                {
                    throw new NativeDocumentSaveException(NativeDocumentSaveError.CommittedUncertain);
                }
            }
            finally
            {
                if (!committed) try { File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }
        finally
        {
            folderLock.ReleaseMutex();
        }
    }
}

/// <summary>A request to open a connection file in a new window: bounded, non-secret, one per explicit open.</summary>
public sealed record NativeDocumentOpenRequest(Guid Id, string Path, string WorkingDirectory);

/// <summary>
/// Routes connection files from the command line, Explorer, the Jump List and
/// the primary-instance handoff (SERVICES.md sections 4 and 12;
/// NativeDocumentLaunchRouter on macOS). Requests may arrive before the app
/// installs its window action; at most 64 wait. A batch is validated whole
/// before any member is queued. UI thread only.
/// </summary>
public sealed class NativeDocumentLaunchRouter(IUiDispatcher dispatcher)
{
    public const int MaximumPending = 64;
    private readonly List<NativeDocumentOpenRequest> pending = [];
    private Action<NativeDocumentOpenRequest>? open;
    private bool draining, stopped;

    public int PendingCount => pending.Count;

    public bool Route(IReadOnlyList<string> paths, string workingDirectory)
    {
        UiThread.Require(dispatcher);
        if (stopped || paths.Count > MaximumPending - pending.Count ||
            !paths.All(p => p.Length is > 0 and <= short.MaxValue && !p.Contains('\0', StringComparison.Ordinal) && Path.IsPathFullyQualified(p)))
            return false;
        pending.AddRange(paths.Select(p => new NativeDocumentOpenRequest(Guid.NewGuid(), p, workingDirectory)));
        Drain();
        return true;
    }

    public void Install(Action<NativeDocumentOpenRequest> action)
    {
        UiThread.Require(dispatcher);
        if (stopped) return;
        open = action;
        Drain();
    }

    private void Drain()
    {
        if (draining) return;
        draining = true;
        try
        {
            while (!stopped && open is { } action && pending.Count > 0)
            {
                var next = pending[0];
                pending.RemoveAt(0);
                action(next);
            }
        }
        finally { draining = false; }
    }

    public void Stop()
    {
        UiThread.Require(dispatcher);
        stopped = true;
        open = null;
        pending.Clear();
    }
}
