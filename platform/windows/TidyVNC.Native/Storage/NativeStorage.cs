// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
namespace TidyVNC.Native.Storage;

/// <summary>Typed store outcomes (SERVICES.md sections 1-2; NativeStorageError on macOS).</summary>
public enum NativeStorageError
{
    Corrupt, FutureSchema, UnsupportedFields, TooLarge, Conflict, Unavailable, Denied, IOFailure, Cancelled, Closed, ResourceLimit,
}

/// <summary>
/// A store failure. The message never contains paths or record contents;
/// NativeCode keeps the Win32/HRESULT value for diagnostics only.
/// </summary>
public sealed class NativeStorageException(NativeStorageError error, int nativeCode = 0)
    : Exception($"Storage {error}")
{
    public NativeStorageError Error { get; } = error;
    public int NativeCode { get; } = nativeCode;
}

/// <summary>
/// The per-user state directory, %LOCALAPPDATA%\TidyVNC (DECISIONS.md D16),
/// resolved through the known-folder API rather than the environment. Debug
/// builds honour TIDYVNC_STATE_ROOT so tests never touch real user data
/// (TESTING.md section 2); Release builds compile the override out.
/// </summary>
public static class NativeStateRoot
{
    public static string Directory
    {
        get
        {
#if DEBUG
            if (Environment.GetEnvironmentVariable("TIDYVNC_STATE_ROOT") is { Length: > 0 } root)
                return Path.GetFullPath(root);
#endif
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.DoNotVerify);
            if (string.IsNullOrEmpty(local)) throw new NativeStorageException(NativeStorageError.Unavailable);
            return Path.Combine(local, "TidyVNC");
        }
    }
}
