// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
using Windows.Win32;
using Windows.Win32.Storage.FileSystem;

namespace TidyVNC.Native.Trust;

public enum NativeLegacyTrustError { Unavailable, Denied, UnsafeFile, Corrupt, UnsupportedFormat, UnsupportedDigest, TooLarge, Changed, Cancelled }

public sealed class NativeLegacyTrustException(NativeLegacyTrustError error) : Exception($"Legacy trust {error}")
{
    public NativeLegacyTrustError Error { get; } = error;
}

/// <summary>
/// Read-only legacy certificate exceptions (SERVICES.md section 5): the
/// retained FLTK viewer's %APPDATA%\TidyVNC\x509_known_hosts and upstream
/// TigerVNC's %APPDATA%\TigerVNC\x509_known_hosts, parsed by the core
/// (tidyvnc_known_hosts_lookup). The app never writes them. A file is used only
/// when it is a regular, single-link file that no principal other than the
/// user, SYSTEM and Administrators can modify; anything else is UnsafeFile.
/// </summary>
public sealed unsafe class NativeLegacyTrustFiles
{
    private static readonly SecurityIdentifier SystemSid = new(WellKnownSidType.LocalSystemSid, null);
    private static readonly SecurityIdentifier Administrators = new(WellKnownSidType.BuiltinAdministratorsSid, null);
    private const FileSystemRights Modify = FileSystemRights.WriteData | FileSystemRights.AppendData | FileSystemRights.WriteAttributes |
        FileSystemRights.WriteExtendedAttributes | FileSystemRights.Delete | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;

    public NativeLegacyTrustFiles(IReadOnlyList<string> paths)
    {
        if (paths.Any(p => !Path.IsPathFullyQualified(p) || p.Contains('\0', StringComparison.Ordinal)))
            throw new ArgumentException("Legacy trust files need fully qualified paths", nameof(paths));
        Paths = paths;
    }

    public IReadOnlyList<string> Paths { get; }

    /// <summary>
    /// The two roaming locations, current FLTK first. An isolated test root
    /// (TESTING.md section 2) has its own copies under the root instead, so
    /// automation never reads the user's trust files.
    /// </summary>
    public static NativeLegacyTrustFiles Default()
    {
        if (Storage.NativeStateRoot.IsIsolated)
        {
            var root = Path.Combine(Storage.NativeStateRoot.Directory, "legacy-appdata");
            return new([Path.Combine(root, "TidyVNC", "x509_known_hosts"), Path.Combine(root, "TigerVNC", "x509_known_hosts")]);
        }
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData, Environment.SpecialFolderOption.DoNotVerify);
        return string.IsNullOrEmpty(roaming) ? new([]) : new([
            Path.Combine(roaming, "TidyVNC", "x509_known_hosts"),
            Path.Combine(roaming, "TigerVNC", "x509_known_hosts"),
        ]);
    }

    /// <summary>
    /// Looks the presented certificate up in every file: a match in any file
    /// is a match; otherwise records for the host in any file make it Changed.
    /// A missing file counts as empty. Runs off the calling thread.
    /// </summary>
    public Task<NativeKnownHostsMatch> LookupAsync(string host, byte[] certificate, CancellationToken cancellation = default)
    {
        if (cancellation.IsCancellationRequested) return Task.FromException<NativeKnownHostsMatch>(new NativeLegacyTrustException(NativeLegacyTrustError.Cancelled));
        return Task.Run(() => Lookup(host, certificate, cancellation), CancellationToken.None);
    }

    private NativeKnownHostsMatch Lookup(string host, byte[] certificate, CancellationToken cancellation)
    {
        NativeCertificateKey key;
        try { key = new NativeCertificateKey(certificate); }
        catch (NativeError) { throw new NativeLegacyTrustException(NativeLegacyTrustError.Corrupt); }
        using (key)
        {
            var now = DateTimeOffset.UtcNow;
            NativeKnownHostsMatch? combined = null;
            foreach (var path in Paths)
            {
                if (cancellation.IsCancellationRequested) throw new NativeLegacyTrustException(NativeLegacyTrustError.Cancelled);
                var data = Read(path, cancellation) ?? [];
                NativeKnownHostsMatch match;
                try { match = NativeKnownHosts.Lookup(data, host, key, now); }
                catch (NativeKnownHostsFailure failure)
                {
                    throw new NativeLegacyTrustException(failure.Reason switch
                    {
                        NativeKnownHostsFailure.Problem.TooLarge => NativeLegacyTrustError.TooLarge,
                        NativeKnownHostsFailure.Problem.UnsupportedFormat => NativeLegacyTrustError.UnsupportedFormat,
                        NativeKnownHostsFailure.Problem.UnsupportedDigest => NativeLegacyTrustError.UnsupportedDigest,
                        _ => NativeLegacyTrustError.Corrupt,
                    });
                }
                catch (NativeError) { throw new NativeLegacyTrustException(NativeLegacyTrustError.Corrupt); }
                if (match.State == NativeKnownHostsState.Match) return match;
                combined = combined is null || combined.State == NativeKnownHostsState.Missing ? match : combined;
            }
            return combined ?? throw new NativeLegacyTrustException(NativeLegacyTrustError.Unavailable);
        }
    }

    private const uint FileGenericRead = 0x00120089;

    private readonly record struct Stamp(long Size, long Written, long Changed, uint Links);

    private static Stamp Inspect(SafeFileHandle handle)
    {
        FILE_BASIC_INFO basic;
        FILE_STANDARD_INFO standard;
        var raw = (Windows.Win32.Foundation.HANDLE)handle.DangerousGetHandle();
        if (!PInvoke.GetFileInformationByHandleEx(raw, FILE_INFO_BY_HANDLE_CLASS.FileBasicInfo, &basic, (uint)sizeof(FILE_BASIC_INFO)) ||
            !PInvoke.GetFileInformationByHandleEx(raw, FILE_INFO_BY_HANDLE_CLASS.FileStandardInfo, &standard, (uint)sizeof(FILE_STANDARD_INFO)))
            throw new NativeLegacyTrustException(NativeLegacyTrustError.Unavailable);
        const uint excluded = (uint)(FILE_FLAGS_AND_ATTRIBUTES.FILE_ATTRIBUTE_REPARSE_POINT | FILE_FLAGS_AND_ATTRIBUTES.FILE_ATTRIBUTE_DIRECTORY |
                                     FILE_FLAGS_AND_ATTRIBUTES.FILE_ATTRIBUTE_DEVICE);
        if ((basic.FileAttributes & excluded) != 0 || standard.Directory || standard.NumberOfLinks != 1)
            throw new NativeLegacyTrustException(NativeLegacyTrustError.UnsafeFile);
        return new(standard.EndOfFile, basic.LastWriteTime, basic.ChangeTime, standard.NumberOfLinks);
    }

    private static void CheckAccess(SafeFileHandle handle)
    {
        FileSecurity security;
        try
        {
            using var stream = new FileStream(new SafeFileHandle(handle.DangerousGetHandle(), ownsHandle: false), FileAccess.Read);
            security = stream.GetAccessControl();
        }
        catch (UnauthorizedAccessException) { throw new NativeLegacyTrustException(NativeLegacyTrustError.Denied); }
        catch (IOException) { throw new NativeLegacyTrustException(NativeLegacyTrustError.Unavailable); }
        using var identity = WindowsIdentity.GetCurrent();
        var user = identity.User;
        bool Trusted(SecurityIdentifier sid) => sid == user || sid == SystemSid || sid == Administrators;
        if (security.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier owner || !Trusted(owner))
            throw new NativeLegacyTrustException(NativeLegacyTrustError.UnsafeFile);
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType == AccessControlType.Allow && (rule.FileSystemRights & Modify) != 0 &&
                (rule.IdentityReference is not SecurityIdentifier sid || !Trusted(sid)))
                throw new NativeLegacyTrustException(NativeLegacyTrustError.UnsafeFile);
        }
    }

    /// <summary>Bounded read without following links; null when the file does not exist.</summary>
    private static byte[]? Read(string path, CancellationToken cancellation)
    {
        using var handle = PInvoke.CreateFile(Platform.NativeWin32Path.For(path), FileGenericRead,
            FILE_SHARE_MODE.FILE_SHARE_READ | FILE_SHARE_MODE.FILE_SHARE_WRITE | FILE_SHARE_MODE.FILE_SHARE_DELETE, null,
            FILE_CREATION_DISPOSITION.OPEN_EXISTING,
            FILE_FLAGS_AND_ATTRIBUTES.FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAGS_AND_ATTRIBUTES.FILE_FLAG_BACKUP_SEMANTICS, null);
        if (handle.IsInvalid)
        {
            var error = System.Runtime.InteropServices.Marshal.GetLastPInvokeError();
            return error is 2 or 3 ? null // ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND
                : throw new NativeLegacyTrustException(error == 5 ? NativeLegacyTrustError.Denied : NativeLegacyTrustError.Unavailable);
        }
        if (PInvoke.GetFileType(handle) != FILE_TYPE.FILE_TYPE_DISK) throw new NativeLegacyTrustException(NativeLegacyTrustError.UnsafeFile);
        var before = Inspect(handle);
        CheckAccess(handle);
        if (before.Size is < 0 or > NativeKnownHosts.MaximumBytes) throw new NativeLegacyTrustException(NativeLegacyTrustError.TooLarge);
        var data = new byte[before.Size];
        for (var offset = 0; offset < data.Length;)
        {
            if (cancellation.IsCancellationRequested) throw new NativeLegacyTrustException(NativeLegacyTrustError.Cancelled);
            int count;
            try { count = RandomAccess.Read(handle, data.AsSpan(offset), offset); }
            catch (IOException) { throw new NativeLegacyTrustException(NativeLegacyTrustError.Unavailable); }
            if (count == 0) throw new NativeLegacyTrustException(NativeLegacyTrustError.Changed);
            offset += count;
        }
        if (Inspect(handle) != before) throw new NativeLegacyTrustException(NativeLegacyTrustError.Changed);
        return data;
    }
}

/// <summary>
/// CA and CRL files (SERVICES.md section 5): explicit paths only, never
/// expanded or read while editing; GnuTLS opens them per attempt. Null
/// inherits the previous layer; empty selects no file. Native defaults are
/// empty; the FLTK default %APPDATA%\TidyVNC\x509_ca.pem is not used implicitly.
/// </summary>
public sealed record NativeTrustFiles(string? CaFile = null, string? CrlFile = null)
{
    public const int MaximumPathLength = short.MaxValue;

    /// <summary>Empty, or a fully qualified drive, UNC or \\?\ path without NUL.</summary>
    public static bool IsValidPath(string value)
        => value.Length == 0 || (value.Length <= MaximumPathLength && !value.Contains('\0', StringComparison.Ordinal) && Path.IsPathFullyQualified(value));

    public bool IsValid => (CaFile is null || IsValidPath(CaFile)) && (CrlFile is null || IsValidPath(CrlFile));

    /// <summary>
    /// A path from a connection file: plain relative paths resolve against the
    /// file's directory; drive- or root-relative paths are refused (null).
    /// </summary>
    public static string? ResolveRelative(string value, string documentDirectory)
    {
        if (value.Length == 0 || IsValidPath(value) && Path.IsPathFullyQualified(value)) return value;
        if (Path.IsPathRooted(value) || value.Contains('\0', StringComparison.Ordinal) || !Path.IsPathFullyQualified(documentDirectory)) return null;
        var joined = Path.Join(documentDirectory, value);
        return IsValidPath(joined) ? joined : null;
    }

    public void ApplyTo(NativeSessionConfiguration configuration)
    {
        if (!IsValid) throw new ArgumentException("Invalid CA or CRL path");
        if (CaFile is not null) configuration.CaFile = CaFile;
        if (CrlFile is not null) configuration.CrlFile = CrlFile;
    }

    public override string ToString() => "NativeTrustFiles(<redacted>)";
}
