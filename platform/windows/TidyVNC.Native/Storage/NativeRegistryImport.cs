// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Globalization;
using System.Text;
using Microsoft.Win32;

namespace TidyVNC.Native.Storage;

/// <summary>Which FLTK-era registry tree an import reads (SERVICES.md section 9).</summary>
public enum NativeRegistrySource
{
    /// <summary>HKCU\Software\TidyVNC\vncviewer (after the FLTK rebrand).</summary>
    TidyVnc,
    /// <summary>HKCU\Software\TigerVNC\vncviewer (upstream, and the not yet rebranded FLTK TidyVNC).</summary>
    TigerVnc,
}

public sealed record NativeRegistryImportSource(NativeRegistrySource Source, bool HasDefaults, bool HasHistory);

/// <summary>Registry values the reader could not represent (wrong type or undecodable text); never imported.</summary>
public sealed record NativeRegistryDefaults(NativeDefaultsProjection Projection, IReadOnlyList<string> SkippedValues);

/// <summary>
/// Read-only import sources for defaults and recent connections from the
/// FLTK viewer's registry keys (TODO W4.5, SERVICES.md section 9). Values are
/// read the way vncviewer/parameters.cxx writes them: REG_DWORD integers and
/// booleans, REG_SZ strings escaped with ConnectionDocument::encodeValue (at
/// most 256 characters), history as "0", "1", … in order. Decoding uses the
/// shared connection-file decoder; the core import projection decides what is
/// imported and excludes passwords, CA/CRL paths, security types, trust and
/// tunnel settings. Keys are opened read-only; nothing is ever written.
/// </summary>
public static class NativeRegistryImport
{
    public const int MaximumValues = 4096;
    public const int MaximumValueCharacters = 256;

    private static string KeyPath(NativeRegistrySource source)
        => source == NativeRegistrySource.TidyVnc ? @"Software\TidyVNC\vncviewer" : @"Software\TigerVNC\vncviewer";

    /// <summary>The sources present under root (HKCU by default); both can exist at once.</summary>
    public static IReadOnlyList<NativeRegistryImportSource> Available(RegistryKey? root = null)
    {
        root ??= NativeStateRoot.ImportRoot();
        if (root is null) return [];
        var result = new List<NativeRegistryImportSource>();
        foreach (var source in new[] { NativeRegistrySource.TidyVnc, NativeRegistrySource.TigerVnc })
        {
            using var key = root.OpenSubKey(KeyPath(source), writable: false);
            if (key is null) continue;
            using var history = key.OpenSubKey("history", writable: false);
            var hasDefaults = key.ValueCount > 0;
            var hasHistory = history?.GetValue("0") is not null;
            if (hasDefaults || hasHistory) result.Add(new(source, hasDefaults, hasHistory));
        }
        return result;
    }

    /// <summary>
    /// Decodes one stored string exactly as ConnectionDocument::decodeValue
    /// (parameters.cxx getKeyString): at most 255 UTF-8 bytes, escapes \n, \r
    /// and \\ only, no NUL. Null when the value is not decodable.
    /// </summary>
    public static string? DecodeStoredString(string encoded)
    {
        int bytes;
        try { bytes = new UTF8Encoding(false, true).GetByteCount(encoded); }
        catch (EncoderFallbackException) { return null; }
        if (bytes > 255) return null;
        var result = new StringBuilder(encoded.Length);
        for (var i = 0; i < encoded.Length; i++)
        {
            var c = encoded[i];
            if (c == '\0') return null;
            if (c == '\\')
            {
                if (++i == encoded.Length) return null;
                c = encoded[i] switch { 'n' => '\n', 'r' => '\r', '\\' => '\\', _ => '\0' };
                if (c == '\0') return null;
            }
            result.Append(c);
        }
        return result.ToString();
    }

    /// <summary>Defaults from the source's vncviewer key through the core projection; null when the key is absent.</summary>
    public static NativeRegistryDefaults? Defaults(NativeRegistrySource source, RegistryKey? root = null)
    {
        root ??= NativeStateRoot.ImportRoot();
        if (root is null) return null;
        using var key = root.OpenSubKey(KeyPath(source), writable: false);
        if (key is null) return null;
        var names = key.GetValueNames();
        if (names.Length > MaximumValues) throw new NativeImportFailure(NativeImportFailure.Problem.TooManyEntries, 0);
        var values = new List<(string Name, string Value)>();
        var skipped = new List<string>();
        foreach (var name in names)
        {
            if (name.Length == 0) continue; // The default value is not a parameter.
            string? value = key.GetValueKind(name) switch
            {
                // parameters.cxx reads a DWORD back as a signed int.
                RegistryValueKind.DWord => key.GetValue(name) is int number ? number.ToString(CultureInfo.InvariantCulture) : null,
                RegistryValueKind.String => key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) is string text ? DecodeStoredString(text) : null,
                _ => null,
            };
            if (value is null) skipped.Add(name);
            else values.Add((name, value));
        }
        return new NativeRegistryDefaults(NativeImport.DefaultsFromValues(values), skipped);
    }

    /// <summary>
    /// Recent connections from "history" values "0", "1", … until the first
    /// missing index, as the FLTK viewer reads them; null when absent.
    /// </summary>
    public static NativeHistoryProjection? History(NativeRegistrySource source, RegistryKey? root = null)
    {
        root ??= NativeStateRoot.ImportRoot();
        if (root is null) return null;
        using var key = root.OpenSubKey(KeyPath(source) + @"\history", writable: false);
        if (key is null) return null;
        var entries = new List<string>();
        for (var index = 0; index < MaximumValues; index++)
        {
            var name = index.ToString(CultureInfo.InvariantCulture);
            if (key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) is not { } raw) break;
            if (key.GetValueKind(name) != RegistryValueKind.String || raw is not string text || DecodeStoredString(text) is not { } entry)
                throw new NativeImportFailure(NativeImportFailure.Problem.Unrepresentable, (uint)index + 1);
            entries.Add(entry);
        }
        return NativeImport.HistoryFromValues(entries);
    }
}
