// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
namespace TidyVNC.Native.Platform;

/// <summary>
/// Paths for direct Win32 calls (CsWin32 CreateFile, ReplaceFile, MoveFileEx).
/// .NET's own file APIs extend long paths themselves, but a direct call takes
/// the string as given, so a path of MAX_PATH or more characters gets its
/// extended-length form (\\?\C:\... or \\?\UNC\server\share\...), which opens
/// without the LongPathsEnabled system setting (PARITY W20, CORE.md section 4).
/// </summary>
internal static class NativeWin32Path
{
    private const int MaxPath = 260;

    public static string For(string path)
    {
        if (path.Length < MaxPath || path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.StartsWith(@"\\.\", StringComparison.Ordinal))
            return path;
        // \\?\ turns off normalisation, so separators and . or .. segments are resolved first.
        var full = Path.GetFullPath(path);
        return full.StartsWith(@"\\", StringComparison.Ordinal) ? @"\\?\UNC\" + full[2..] : @"\\?\" + full;
    }
}
