// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Globalization;

namespace TidyVNC.Native;

/// <summary>
/// User-visible text as a catalog reference: the macOS catalog key (dots kept;
/// the app's resource name replaces them with underscores, DECISIONS.md D20)
/// and its arguments. Models in this library never hold English text, so the
/// app localizes every message and tests compare keys. Arguments are strings,
/// numbers or nested <see cref="NativeText"/>; remote or user text is only ever
/// an argument, never a key or format (UX.md section 9).
/// </summary>
public sealed class NativeText : IEquatable<NativeText>
{
    private static Func<NativeText, string>? resolver;

    public string Key { get; }
    public IReadOnlyList<object> Arguments { get; }

    public NativeText(string key, params object[] arguments)
    {
        ArgumentException.ThrowIfNullOrEmpty(key);
        ArgumentNullException.ThrowIfNull(arguments);
        foreach (var argument in arguments)
            if (argument is not (string or NativeText or int or uint or long or ulong or double))
                throw new ArgumentException($"Unsupported text argument {argument?.GetType().Name}", nameof(arguments));
        Key = key;
        Arguments = arguments.ToArray();
    }

    /// <summary>Installed once by the app: resolves a catalog key and formats its arguments.</summary>
    public static void SetResolver(Func<NativeText, string> value) => resolver = value;

    /// <summary>The localized text, or a key-and-arguments form when no catalog is installed (tests).</summary>
    public override string ToString() => resolver?.Invoke(this) ??
        (Arguments.Count == 0 ? Key : $"{Key}({string.Join(", ", Arguments.Select(a => Convert.ToString(a, CultureInfo.InvariantCulture)))})");

    public bool Equals(NativeText? other) => other is not null && Key == other.Key && Arguments.SequenceEqual(other.Arguments);
    public override bool Equals(object? obj) => Equals(obj as NativeText);
    public override int GetHashCode() => HashCode.Combine(Key, Arguments.Count);
}
