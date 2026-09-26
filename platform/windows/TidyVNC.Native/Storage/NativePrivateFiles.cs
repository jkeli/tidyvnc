// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Security.AccessControl;
using System.Security.Principal;

namespace TidyVNC.Native.Storage;

/// <summary>
/// Owner-only files for the stores (SERVICES.md section 2): a protected DACL
/// granting full control to the current user and SYSTEM only, owner and DACL
/// checks on open, reparse points refused, bounded reads, and writes that take
/// a LockFileEx writer lock, write a temporary file, flush it and replace the
/// target atomically, retrying briefly on sharing violations (antivirus,
/// backup and indexer handles). Synchronous: call from worker threads only.
/// </summary>
public static class NativePrivateFiles
{
    private const int SharingViolation = unchecked((int)0x80070020);
    private const int LockViolation = unchecked((int)0x80070021);
    private const int UnableToRemoveReplaced = unchecked((int)0x80070497);
    private const int UnableToMoveReplacement = unchecked((int)0x80070498);
    private const int UnableToMoveReplacement2 = unchecked((int)0x80070499);
    private const string TemporarySuffix = ".tidyvnc-tmp";

    private static readonly SecurityIdentifier System = new(WellKnownSidType.LocalSystemSid, null);

    private static SecurityIdentifier CurrentUser
    {
        get
        {
            using var identity = WindowsIdentity.GetCurrent();
            return identity.User ?? throw new NativeStorageException(NativeStorageError.Unavailable);
        }
    }

    /// <summary>
    /// The owner Windows gives new objects this process creates without an explicit
    /// owner: the user, or the Administrators group for an elevated administrator.
    /// </summary>
    private static SecurityIdentifier? DefaultOwner
    {
        get
        {
            using var identity = WindowsIdentity.GetCurrent();
            return identity.Owner;
        }
    }

    /// <summary>Owned by the user, with a protected DACL granting only the user and SYSTEM full control.</summary>
    private static FileSecurity PrivateFileSecurity()
    {
        var user = CurrentUser;
        var security = new FileSecurity();
        security.SetAccessRuleProtection(true, false);
        security.SetOwner(user);
        foreach (var sid in new[] { user, System })
            security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow));
        return security;
    }

    /// <summary>Retries: attempts and base delay, overridable by tests.</summary>
    public static int RetryAttempts { get; set; } = 8;
    public static TimeSpan RetryDelay { get; set; } = TimeSpan.FromMilliseconds(25);

    /// <summary>Creates (if needed) and validates a private directory, including its parents under the state root.</summary>
    public static void EnsureDirectory(string directory)
    {
        var info = new DirectoryInfo(directory);
        if (!info.Exists)
        {
            if (info.Parent is { } parent && !parent.Exists) EnsureDirectory(parent.FullName);
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(CurrentUser);
            foreach (var sid in new[] { CurrentUser, System })
                security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            try { info.Create(security); }
            catch (IOException error) when (Directory.Exists(directory)) { _ = error; } // Another process won the race.
            catch (UnauthorizedAccessException error) { throw new NativeStorageException(NativeStorageError.Denied, error.HResult); }
            catch (IOException error) { throw new NativeStorageException(NativeStorageError.IOFailure, error.HResult); }
            info.Refresh();
        }
        CheckPrivate(info);
    }

    /// <summary>
    /// A file or directory is private when it is not a reparse point, the
    /// current user owns it, and its DACL is protected with allow entries for
    /// only the user and SYSTEM. Anything else is Denied, never trusted. The
    /// process's default owner also counts as the user: for an elevated
    /// administrator that is the Administrators group, which files written by
    /// the same elevated user (another tool, an editor) carry.
    /// </summary>
    public static void CheckPrivate(FileSystemInfo info)
    {
        if ((info.Attributes & FileAttributes.ReparsePoint) != 0) throw new NativeStorageException(NativeStorageError.Denied);
        FileSystemSecurity security;
        try
        {
            security = info switch
            {
                DirectoryInfo directory => directory.GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access),
                FileInfo file => file.GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access),
                _ => throw new NativeStorageException(NativeStorageError.Denied),
            };
        }
        catch (UnauthorizedAccessException error) { throw new NativeStorageException(NativeStorageError.Denied, error.HResult); }
        catch (IOException error) { throw new NativeStorageException(NativeStorageError.IOFailure, error.HResult); }
        var user = CurrentUser;
        if (security.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier owner || (owner != user && owner != DefaultOwner))
            throw new NativeStorageException(NativeStorageError.Denied);
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow) continue;
            if (rule.IdentityReference is not SecurityIdentifier sid || (sid != user && sid != System))
                throw new NativeStorageException(NativeStorageError.Denied);
        }
    }

    /// <summary>Reads at most maximum bytes; null when absent. Larger files are TooLarge.</summary>
    public static byte[]? Read(string path, int maximum)
    {
        var info = new FileInfo(path);
        if (!info.Exists)
        {
            if (Directory.Exists(path)) throw new NativeStorageException(NativeStorageError.Denied);
            return null;
        }
        CheckPrivate(info);
        return Retry(() =>
        {
            using var stream = new FileStream(path, new FileStreamOptions
            {
                Mode = FileMode.Open, Access = FileAccess.Read, Share = FileShare.Read | FileShare.Delete,
            });
            if (stream.Length > maximum) throw new NativeStorageException(NativeStorageError.TooLarge);
            var data = new byte[stream.Length];
            stream.ReadExactly(data);
            if (stream.ReadByte() != -1) throw new NativeStorageException(NativeStorageError.TooLarge); // Grew while reading.
            return data;
        });
    }

    /// <summary>
    /// Holds the store's writer lock (a LockFileEx range on name.lock, shared by
    /// every TidyVNC process) for the duration of body.
    /// </summary>
    public static T WithWriterLock<T>(string path, TimeSpan timeout, Func<T> body)
    {
        var lockPath = path + ".lock";
        var deadline = DateTime.UtcNow + timeout;
        FileStream? handle = null;
        try
        {
            // An explicit owner, because an elevated process would otherwise make the Administrators group the owner.
            handle = Retry(() => new FileInfo(lockPath).Create(FileMode.OpenOrCreate, FileSystemRights.Read | FileSystemRights.Write | FileSystemRights.Synchronize,
                FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.None, PrivateFileSecurity()));
            CheckPrivate(new FileInfo(lockPath));
            while (true)
            {
                try { handle.Lock(0, 1); break; }
                catch (IOException error) when (error.HResult == LockViolation)
                {
                    if (DateTime.UtcNow > deadline) throw new NativeStorageException(NativeStorageError.Unavailable, error.HResult);
                    Thread.Sleep(10);
                }
            }
            try { return body(); }
            finally { handle.Unlock(0, 1); }
        }
        catch (UnauthorizedAccessException error) { throw new NativeStorageException(NativeStorageError.Denied, error.HResult); }
        finally
        {
            handle?.Dispose();
        }
    }

    /// <summary>
    /// Replaces path with data: temporary file in the same directory, flushed to
    /// disk, then ReplaceFileW (or a write-through move for a new file). Callers
    /// hold the writer lock. Leftover temporaries from a crash are removed.
    /// </summary>
    public static void Replace(string path, ReadOnlySpan<byte> data)
    {
        var directory = Path.GetDirectoryName(path) ?? throw new NativeStorageException(NativeStorageError.IOFailure);
        foreach (var stale in Directory.EnumerateFiles(directory, Path.GetFileName(path) + ".*" + TemporarySuffix))
        {
            try { File.Delete(stale); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
        var temporary = path + "." + Guid.NewGuid().ToString("N") + TemporarySuffix;
        try
        {
            using (var stream = new FileInfo(temporary).Create(FileMode.CreateNew, FileSystemRights.Write | FileSystemRights.Synchronize, FileShare.None, 4096,
                FileOptions.WriteThrough, PrivateFileSecurity()))
            {
                stream.Write(data);
                stream.Flush(flushToDisk: true);
            }
            CheckPrivate(new FileInfo(temporary));
            Retry(() =>
            {
                if (File.Exists(path))
                {
                    CheckPrivate(new FileInfo(path));
                    File.Replace(temporary, path, destinationBackupFileName: null, ignoreMetadataErrors: true);
                }
                else
                {
                    File.Move(temporary, path, overwrite: false);
                }
                return true;
            });
        }
        catch (UnauthorizedAccessException error) { throw new NativeStorageException(NativeStorageError.Denied, error.HResult); }
        catch (IOException error) { throw new NativeStorageException(NativeStorageError.IOFailure, error.HResult); }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private static bool Transient(IOException error) => error.HResult is SharingViolation or LockViolation or UnableToRemoveReplaced
        or UnableToMoveReplacement or UnableToMoveReplacement2;

    private static T Retry<T>(Func<T> body)
    {
        for (var attempt = 1; ; attempt++)
        {
            try { return body(); }
            catch (IOException error) when (Transient(error) && attempt < RetryAttempts)
            {
                Thread.Sleep(RetryDelay * attempt);
            }
            catch (IOException error) when (Transient(error))
            {
                throw new NativeStorageException(NativeStorageError.IOFailure, error.HResult);
            }
        }
    }
}
