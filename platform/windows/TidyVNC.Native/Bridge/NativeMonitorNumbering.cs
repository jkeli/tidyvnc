// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

/// <summary>A local display's top-left origin for legacy numbering; Id is a caller-owned token.</summary>
public readonly record struct NativeMonitorOrigin(uint Id, int X, int Y);

public sealed class NativeMonitorNumberingFailure : Exception
{
    public enum Problem : uint { Empty = 1, TooMany = 2, DuplicateId = 3, AmbiguousOrigin = 4 }
    public Problem Reason { get; }
    public NativeMonitorNumberingFailure(Problem reason) : base($"Monitors cannot be numbered ({reason})") => Reason = reason;
}

/// <summary>
/// The retained viewer's monitor numbers for connection files
/// (tidyvnc_legacy_monitor_order): ascending x, then y. Displays sharing an
/// origin, mirrors included, are refused rather than mapped arbitrarily.
/// </summary>
public static unsafe class NativeMonitorNumbering
{
    /// <summary>Ids in monitor-number order: element n-1 is monitor n.</summary>
    public static uint[] Order(IReadOnlyList<NativeMonitorOrigin> monitors)
    {
        var input = new tidyvnc_display_monitor[monitors.Count];
        for (var i = 0; i < input.Length; i++)
            input[i] = new tidyvnc_display_monitor { id = monitors[i].Id, x = monitors[i].X, y = monitors[i].Y, width = 1, height = 1, backing_width = 1, backing_height = 1 };
        var ids = new uint[Math.Max(1, input.Length)];
        var error = Abi.Init<tidyvnc_error>();
        uint status;
        fixed (tidyvnc_display_monitor* data = input) fixed (uint* output = ids)
            status = NativeMethods.tidyvnc_legacy_monitor_order(data, (uint)input.Length, output, &error);
        if (status != Tidyvnc.TIDYVNC_OK)
        {
            if (error.domain == Tidyvnc.TIDYVNC_DOMAIN_MONITORS) throw new NativeMonitorNumberingFailure((NativeMonitorNumberingFailure.Problem)error.detail);
            throw new NativeError(error);
        }
        return ids[..input.Length];
    }
}
