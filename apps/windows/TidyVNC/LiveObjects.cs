// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
#if DEBUG

namespace TidyVNC;

/// <summary>
/// Leak checks in Debug builds (W6.11): objects that should die with their window register here, and
/// after the test collect hook runs, the live count per kind is written to live-objects.txt in the test
/// state root. Release builds compile this out.
/// </summary>
internal static class LiveObjects
{
    private static readonly List<(string Kind, WeakReference Target)> tracked = [];
    private static readonly Lock gate = new();

    public static void Track(object target, string? kind = null)
    {
        lock (gate) tracked.Add((kind ?? target.GetType().Name, new WeakReference(target)));
    }

    /// <summary>Live objects by kind after a collection, as "Kind: count" lines.</summary>
    public static string Report()
    {
        lock (gate)
        {
            tracked.RemoveAll(entry => !entry.Target.IsAlive);
            return string.Join(Environment.NewLine, tracked.GroupBy(e => e.Kind).OrderBy(g => g.Key).Select(g => $"{g.Key}: {g.Count()}"));
        }
    }
}
#endif
