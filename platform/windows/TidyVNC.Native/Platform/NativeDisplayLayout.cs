// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Interop;

namespace TidyVNC.Native.Platform;

/// <summary>Where one local display lands in a shared remote layout.</summary>
public sealed record NativeDisplayRegion(NativeDisplayInfo Display, uint X, uint Y, uint Width, uint Height);

/// <summary>
/// Local displays mapped through the retained viewer's DesktopLayout
/// algorithm (tidyvnc_display_layout_compute; macOS NativeDisplayLayout).
/// Positions and sizes are effective pixels (physical divided by the
/// display scale) with the physical sizes as backing; device units use the
/// physical sizes and the core normalizes mixed densities so screens never
/// overlap. Local IDs never become RFB identities.
/// </summary>
public sealed unsafe class NativeDisplayLayout
{
    public uint Width { get; }
    public uint Height { get; }
    public bool Normalized { get; }
    public bool DevicePixels { get; }
    public IReadOnlyList<NativeDisplayRegion> Regions { get; }

    public NativeDisplayLayout(IReadOnlyList<NativeDisplayInfo> displays, bool devicePixels)
    {
        if (displays.Count is 0 or > 64 || displays.Select(d => d.Id).Distinct(StringComparer.Ordinal).Count() != displays.Count)
            throw new NativeError(NativeStatus.InvalidArgument, "Invalid display selection");
        var ordered = displays.OrderBy(d => d.Id, StringComparer.Ordinal).ToList();
        var monitors = new tidyvnc_display_monitor[ordered.Count];
        for (var i = 0; i < ordered.Count; i++)
        {
            var display = ordered[i];
            var logical = display.LogicalBounds;
            double x = Math.Round(logical.X), y = Math.Round(logical.Y), width = Math.Round(logical.Width), height = Math.Round(logical.Height);
            if (Math.Abs(x) > 1_000_000 || Math.Abs(y) > 1_000_000 || width is < 1 or > 65535 || height is < 1 or > 65535 ||
                display.Bounds.Width is < 1 or > 65535 || display.Bounds.Height is < 1 or > 65535)
                throw new NativeError(NativeStatus.ResourceLimit, "Display exceeds layout limits");
            monitors[i] = new tidyvnc_display_monitor
            {
                id = (uint)i, x = (int)x, y = (int)y, width = (uint)width, height = (uint)height,
                backing_width = (uint)display.Bounds.Width, backing_height = (uint)display.Bounds.Height,
            };
        }
        var output = Abi.Init<tidyvnc_display_layout>();
        var error = Abi.Init<tidyvnc_error>();
        fixed (tidyvnc_display_monitor* data = monitors)
        {
            var request = Abi.Init<tidyvnc_display_layout_request>();
            request.monitor_count = (uint)monitors.Length; request.device_pixels = devicePixels ? 1u : 0u; request.monitors = data;
            Abi.Check(NativeMethods.tidyvnc_display_layout_compute(&request, &output, &error), &error);
        }
        DevicePixels = devicePixels;
        Width = output.width; Height = output.height; Normalized = output.normalized != 0;
        var regions = new List<NativeDisplayRegion>();
        for (var i = 0; i < output.screen_count; i++)
        {
            var screen = output.screens[i];
            regions.Add(new NativeDisplayRegion(ordered[(int)screen.id], screen.x, screen.y, screen.width, screen.height));
        }
        Regions = regions;
    }

    /// <summary>
    /// The server layout for this arrangement, reusing the baseline's screen
    /// IDs: exact geometry matches first, then remaining IDs in numeric
    /// order; new screens take the lowest unused ID.
    /// </summary>
    public NativeRemoteLayout RemoteLayout(NativeRemoteLayout baseline)
    {
        var remaining = baseline.Screens.OrderBy(s => s.Id).ToList();
        var identities = new Dictionary<string, NativeRemoteScreen>(StringComparer.Ordinal);
        foreach (var region in Regions)
        {
            var index = remaining.FindIndex(s => s.X == region.X && s.Y == region.Y && s.Width == region.Width && s.Height == region.Height);
            if (index < 0) continue;
            identities[region.Display.Id] = remaining[index];
            remaining.RemoveAt(index);
        }
        var used = baseline.Screens.Select(s => s.Id).ToHashSet();
        uint candidate = 0;
        var screens = new List<NativeRemoteScreen>();
        foreach (var region in Regions)
        {
            NativeRemoteScreen? identity = identities.TryGetValue(region.Display.Id, out var exact) ? exact : null;
            if (identity is null && remaining.Count > 0) { identity = remaining[0]; remaining.RemoveAt(0); }
            uint id;
            if (identity is { } found) id = found.Id;
            else
            {
                while (used.Contains(candidate)) candidate++;
                id = candidate; used.Add(id);
            }
            screens.Add(new NativeRemoteScreen(id, region.X, region.Y, region.Width, region.Height, identity?.Flags ?? 0));
        }
        return new NativeRemoteLayout(Width, Height, screens);
    }
}
