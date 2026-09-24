// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Text;
using Microsoft.Win32.SafeHandles;
using Windows.Win32;
using Windows.Win32.Storage.FileSystem;

namespace TidyVNC.Native.Credentials;

public sealed class NativeLaunchCredentialException : Exception
{
    public enum Problem { InvalidEnvironment, RelativePathNeedsBase, InvalidPasswordFile }

    public Problem Reason { get; }
    /// <summary>The argv index of the offending PasswordFile value (0 for environment problems).</summary>
    public uint Argument { get; }

    public NativeLaunchCredentialException(Problem reason, uint argument = 0) : base(reason switch
    {
        Problem.InvalidEnvironment => "A launch credential exceeds its byte limit or contains invalid data.",
        Problem.RelativePathNeedsBase => "A relative PasswordFile needs the launch working directory.",
        _ => "The PasswordFile path is not valid.",
    })
    {
        Reason = reason;
        Argument = argument;
    }
}

/// <summary>
/// Launch credentials (plans/native-ui/CREDENTIAL-INPUTS.md, SERVICES.md
/// section 3): VNC_USERNAME / VNC_PASSWORD captured once at process entry and
/// removed from this process's environment block, plus the selected
/// PasswordFile. One atomic <see cref="Claim"/> hands them to one connection
/// window. Values are never written to preferences, profiles, history,
/// documents or Credential Manager. The original environment strings the
/// runtime already materialized are outside this owner's control.
/// </summary>
public sealed class NativeLaunchCredentialInputs : IDisposable
{
    public const string UsernameVariable = "VNC_USERNAME";
    public const string PasswordVariable = "VNC_PASSWORD";

    private readonly Lock gate = new();
    private NativeLaunchCredentialPayload? pending;

    /// <summary>Consumes (wipes) both byte arrays, including on failure.</summary>
    public NativeLaunchCredentialInputs(byte[]? username, byte[]? password, string? passwordFile)
    {
        try
        {
            foreach (var value in new[] { username, password })
                if (value is not null && (value.Length > NativeCredentialSecret.MaximumBytes || value.Contains((byte)0)))
                    throw new NativeLaunchCredentialException(NativeLaunchCredentialException.Problem.InvalidEnvironment);
            var user = username is null ? null : NativeCredentialSecret.Consume(username);
            try { pending = new(user, password is null ? null : NativeCredentialSecret.Consume(password), passwordFile); }
            catch { user?.Clear(); throw; }
        }
        finally
        {
            if (username is not null) Array.Clear(username);
            if (password is not null) Array.Clear(password);
        }
    }

    /// <summary>
    /// Called once, after argument handling and before any window: reads the
    /// two variables (UTF-8, at most 4096 bytes each; absent differs from
    /// empty) and removes them from the environment block so child processes
    /// (ssh, the askpass helper) never inherit them.
    /// </summary>
    public static NativeLaunchCredentialInputs Capture(string? passwordFile)
    {
        // Both variables leave the environment block before anything can fail.
        var userText = Environment.GetEnvironmentVariable(UsernameVariable);
        var passwordText = Environment.GetEnvironmentVariable(PasswordVariable);
        Environment.SetEnvironmentVariable(UsernameVariable, null);
        Environment.SetEnvironmentVariable(PasswordVariable, null);
        static byte[]? Encode(string? value)
        {
            if (value is null) return null;
            try { return new UTF8Encoding(false, true).GetBytes(value); }
            catch (EncoderFallbackException) { throw new NativeLaunchCredentialException(NativeLaunchCredentialException.Problem.InvalidEnvironment); }
        }
        byte[]? username = null, password = null;
        try
        {
            username = Encode(userText);
            password = Encode(passwordText);
            return new NativeLaunchCredentialInputs(username, password, passwordFile);
        }
        finally
        {
            if (username is not null) Array.Clear(username);
            if (password is not null) Array.Clear(password);
        }
    }

    /// <summary>
    /// The PasswordFile (alias passwd) in effect: every occurrence is checked
    /// without IO, the last wins, and an empty value disables it. Windows path
    /// rules: fully qualified drive or UNC paths as given; plain relative paths
    /// against the working directory captured at launch; drive-relative
    /// ("C:x") and root-relative ("\x") paths are refused. No ~, %VAR% or
    /// shell expansion.
    /// </summary>
    public static string? PasswordFile(NativeInvocation invocation, string? workingDirectory)
    {
        string? selected = null;
        foreach (var field in invocation.Assignments)
        {
            if (!string.Equals(field.Name, "PasswordFile", StringComparison.OrdinalIgnoreCase)) continue;
            var argument = field.ValueArgument != 0 ? field.ValueArgument : field.Argument;
            if (field.Value.Length == 0) { selected = null; continue; }
            var path = field.Value;
            if (path.Contains('\0', StringComparison.Ordinal) || path.Length > short.MaxValue)
                throw new NativeLaunchCredentialException(NativeLaunchCredentialException.Problem.InvalidPasswordFile, argument);
            if (!Path.IsPathFullyQualified(path))
            {
                if (Path.IsPathRooted(path))
                    throw new NativeLaunchCredentialException(NativeLaunchCredentialException.Problem.InvalidPasswordFile, argument);
                if (workingDirectory is null || !Path.IsPathFullyQualified(workingDirectory) || workingDirectory.Contains('\0', StringComparison.Ordinal))
                    throw new NativeLaunchCredentialException(NativeLaunchCredentialException.Problem.RelativePathNeedsBase, argument);
                path = Path.Join(workingDirectory, path);
            }
            selected = path;
        }
        return selected;
    }

    /// <summary>Hosts that supply an invocation without a process capture get only its explicit file policy.</summary>
    public static NativeLaunchCredentialInputs? FileOnly(NativeInvocation invocation, string? workingDirectory)
        => PasswordFile(invocation, workingDirectory) is { } file ? new NativeLaunchCredentialInputs(null, null, file) : null;

    /// <summary>The single transfer; later calls return null.</summary>
    public NativeLaunchCredentialPayload? Claim()
    {
        lock (gate)
        {
            var payload = pending;
            pending = null;
            return payload;
        }
    }

    public void Clear()
    {
        lock (gate)
        {
            pending?.Clear();
            pending = null;
        }
    }

    public void Dispose() => Clear();
    public override string ToString() => "NativeLaunchCredentialInputs(<redacted>)";
}

/// <summary>Claimed launch credentials; clearing also invalidates references held by in-flight work.</summary>
public sealed class NativeLaunchCredentialPayload(NativeCredentialSecret? username, NativeCredentialSecret? password, string? file)
{
    public NativeCredentialSecret? Username { get; } = username;
    public NativeCredentialSecret? Password { get; } = password;
    public string? File { get; } = file;

    public bool HasEnvironment(bool usernameRequired) => Password is not null && (!usernameRequired || Username is not null);

    public void Clear()
    {
        Username?.Clear();
        Password?.Clear();
    }

    public override string ToString() => "NativeLaunchCredentialPayload(<redacted>)";
}

public enum NativePasswordFileError { Unreadable, NotRegular, Truncated, Changed, Cancelled }

public sealed class NativePasswordFileException(NativePasswordFileError error) : Exception($"Password file {error}")
{
    public NativePasswordFileError Error { get; } = error;
}

public interface INativePasswordFileReader
{
    /// <summary>
    /// The first eight (obfuscated, not encrypted) bytes of a legacy password
    /// file. The caller clears the returned block after use or cancellation.
    /// </summary>
    Task<NativeCredentialSecret> ReadAsync(string path, CancellationToken cancellation);
}

/// <summary>
/// Bounded PasswordFile reads off the UI thread: one regular disk file, opened
/// without following reparse points (Windows rule, SERVICES.md section 3),
/// only its first eight bytes, with before/after size and time checks. Pipes,
/// devices, directories and links are refused without a blocking read. Only
/// the core decodes the block.
/// </summary>
public sealed unsafe class NativePasswordFileReader : INativePasswordFileReader
{
    public const int BlockBytes = 8;
    private const uint FileGenericRead = 0x00120089; // FILE_GENERIC_READ

    public Task<NativeCredentialSecret> ReadAsync(string path, CancellationToken cancellation)
    {
        if (cancellation.IsCancellationRequested) return Task.FromException<NativeCredentialSecret>(new NativePasswordFileException(NativePasswordFileError.Cancelled));
        return Task.Run(() => Read(path, cancellation), CancellationToken.None);
    }

    private readonly record struct Stamp(long Size, long Written, long Changed);

    private static Stamp Inspect(SafeFileHandle handle)
    {
        FILE_BASIC_INFO basic;
        FILE_STANDARD_INFO standard;
        if (!PInvoke.GetFileInformationByHandleEx((Windows.Win32.Foundation.HANDLE)handle.DangerousGetHandle(), FILE_INFO_BY_HANDLE_CLASS.FileBasicInfo, &basic, (uint)sizeof(FILE_BASIC_INFO)) ||
            !PInvoke.GetFileInformationByHandleEx((Windows.Win32.Foundation.HANDLE)handle.DangerousGetHandle(), FILE_INFO_BY_HANDLE_CLASS.FileStandardInfo, &standard, (uint)sizeof(FILE_STANDARD_INFO)))
            throw new NativePasswordFileException(NativePasswordFileError.Unreadable);
        const uint excluded = (uint)(FILE_FLAGS_AND_ATTRIBUTES.FILE_ATTRIBUTE_REPARSE_POINT | FILE_FLAGS_AND_ATTRIBUTES.FILE_ATTRIBUTE_DIRECTORY |
                                     FILE_FLAGS_AND_ATTRIBUTES.FILE_ATTRIBUTE_DEVICE);
        if ((basic.FileAttributes & excluded) != 0 || standard.Directory) throw new NativePasswordFileException(NativePasswordFileError.NotRegular);
        return new(standard.EndOfFile, basic.LastWriteTime, basic.ChangeTime);
    }

    private static NativeCredentialSecret Read(string path, CancellationToken cancellation)
    {
        void Check() { if (cancellation.IsCancellationRequested) throw new NativePasswordFileException(NativePasswordFileError.Cancelled); }
        Check();
        if (!Path.IsPathFullyQualified(path) || path.Contains('\0', StringComparison.Ordinal))
            throw new NativePasswordFileException(NativePasswordFileError.Unreadable);
        using var handle = PInvoke.CreateFile(Platform.NativeWin32Path.For(path), FileGenericRead,
            FILE_SHARE_MODE.FILE_SHARE_READ | FILE_SHARE_MODE.FILE_SHARE_WRITE | FILE_SHARE_MODE.FILE_SHARE_DELETE, null,
            FILE_CREATION_DISPOSITION.OPEN_EXISTING,
            FILE_FLAGS_AND_ATTRIBUTES.FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAGS_AND_ATTRIBUTES.FILE_FLAG_BACKUP_SEMANTICS, null);
        if (handle.IsInvalid) throw new NativePasswordFileException(NativePasswordFileError.Unreadable);
        if (PInvoke.GetFileType(handle) != FILE_TYPE.FILE_TYPE_DISK) throw new NativePasswordFileException(NativePasswordFileError.NotRegular);
        var before = Inspect(handle);
        if (before.Size < BlockBytes) throw new NativePasswordFileException(NativePasswordFileError.Truncated);
        var block = new byte[BlockBytes];
        try
        {
            for (var offset = 0; offset < BlockBytes;)
            {
                Check();
                int count;
                try { count = RandomAccess.Read(handle, block.AsSpan(offset), offset); }
                catch (IOException) { throw new NativePasswordFileException(NativePasswordFileError.Unreadable); }
                catch (UnauthorizedAccessException) { throw new NativePasswordFileException(NativePasswordFileError.Unreadable); }
                if (count == 0) throw new NativePasswordFileException(NativePasswordFileError.Truncated);
                offset += count;
            }
            if (Inspect(handle) != before) throw new NativePasswordFileException(NativePasswordFileError.Changed);
            Check();
            return NativeCredentialSecret.Consume(block);
        }
        finally
        {
            Array.Clear(block);
        }
    }

}
