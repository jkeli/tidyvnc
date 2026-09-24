// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
namespace TidyVNC.Native.Storage;

/// <summary>Typed store outcomes (SERVICES.md sections 1-2; NativeStorageError on macOS).</summary>
public enum NativeStorageError
{
    Corrupt, FutureSchema, UnsupportedFields, TooLarge, Conflict, Unavailable, Denied, IOFailure, Cancelled, Closed, ResourceLimit,
    /// <summary>The profile or history entry named by an operation no longer exists.</summary>
    NotFound,
    /// <summary>A value an operation was given cannot be stored (empty name, invalid address or gateway target).</summary>
    Invalid,
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
/// (TESTING.md section 2); Release builds compile the override out, except the
/// measurement builds of build.py --measurement, which the package stage refuses.
/// </summary>
public static class NativeStateRoot
{
    public const string OverrideVariable = "TIDYVNC_STATE_ROOT";

    /// <summary>The Debug-only override (TESTING.md section 2); always null in packaged Release builds.</summary>
    private static string? Override
    {
        get
        {
#if DEBUG || TIDYVNC_MEASUREMENT
            if (Environment.GetEnvironmentVariable(OverrideVariable) is { Length: > 0 } root) return Path.GetFullPath(root);
#endif
            return null;
        }
    }

    public static string Directory
    {
        get
        {
            if (Override is { } root) return root;
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.DoNotVerify);
            if (string.IsNullOrEmpty(local)) throw new NativeStorageException(NativeStorageError.Unavailable);
            return Path.Combine(local, "TidyVNC");
        }
    }

    /// <summary>True when a Debug build runs against an isolated test root.</summary>
    public static bool IsIsolated => Override is not null;

    /// <summary>A short stable identifier of the isolated root, naming its other isolated resources.</summary>
    public static string? RunId => Override is { } root
        ? Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(root.ToUpperInvariant())))[..12].ToLowerInvariant()
        : null;

    /// <summary>Credential Manager target prefix: TidyVNC/credentials.v1/, or TidyVNC-test-&lt;run&gt;/credentials.v1/ when isolated.</summary>
    public static string CredentialPrefix => RunId is { } run ? $"TidyVNC-test-{run}/credentials.v1/" : "TidyVNC/credentials.v1/";

    /// <summary>
    /// The registry root that FLTK import sources are read under (read-only):
    /// HKCU, or HKCU\Software\TidyVNC-Test\&lt;run&gt; when isolated. Null when an
    /// isolated root has no test key, which means no sources.
    /// </summary>
    public static Microsoft.Win32.RegistryKey? ImportRoot() => RunId is { } run
        ? Microsoft.Win32.Registry.CurrentUser.OpenSubKey($@"Software\TidyVNC-Test\{run}", writable: false)
        : Microsoft.Win32.Registry.CurrentUser;

    /// <summary>The log file for the "file" target when isolated; null keeps the core's Windows default.</summary>
    public static string? LogFile => Override is { } root ? Path.Combine(root, "vncviewer.log") : null;
}
