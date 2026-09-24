// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Interop;

namespace TidyVNC.Native.Desktop;

/// <summary>A cursor image in straight-alpha RGBA with its hotspot, in device pixels.</summary>
public sealed record NativeCursorRaster(byte[] Rgba, uint Width, uint Height, uint HotspotX, uint HotspotY, bool Blank);

/// <summary>What the desktop view shows as the pointer (vncviewer/Viewport.cxx showCursor).</summary>
public enum NativeCursorChoice { System, Hidden, Dot, Remote }

/// <summary>
/// The remote cursor at the view's scale (DESKTOP.md section 3, D13): the
/// shared cursor sampler (tidyvnc_cursor_renderer) scales the server's cursor
/// by device pixels per remote pixel with the connection's filter, so the
/// pointer matches the scaled desktop as on macOS and in the retained viewer.
/// </summary>
public static class NativeCursorSampler
{
    private const int Tile = 256;

    public static unsafe NativeCursorRaster Sample(NativeImage cursor, double scaleX, double scaleY, NativeScalingFilter filter)
    {
        var options = Abi.Init<tidyvnc_cursor_options>();
        options.quality = (uint)filter; options.scale_x = scaleX; options.scale_y = scaleY;
        var geometry = Abi.Init<tidyvnc_cursor_geometry>();
        var error = Abi.Init<tidyvnc_error>();
        ulong raw;
        Abi.Check(NativeMethods.tidyvnc_cursor_renderer_create(cursor.Handle.Raw, &options, &raw, &geometry, &error), &error);
        using var sampler = NativeHandle.Adopt(raw);
        int width = (int)geometry.width, height = (int)geometry.height;
        var rgba = new byte[width * height * 4];
        var tile = new byte[Tile * Tile * 4];
        for (var y = 0; y < height; y += Tile)
            for (var x = 0; x < width; x += Tile)
            {
                var part = Abi.Init<tidyvnc_cursor_tile>();
                part.x = (uint)x; part.y = (uint)y; part.width = (uint)Math.Min(Tile, width - x); part.height = (uint)Math.Min(Tile, height - y);
                fixed (byte* p = tile)
                {
                    var span = new tidyvnc_mutable_bytes { data = p, length = (ulong)tile.Length };
                    Abi.Check(NativeMethods.tidyvnc_cursor_renderer_render(sampler.Raw, &part, span, &error), &error);
                }
                for (var row = 0; row < part.height; row++)
                    Array.Copy(tile, row * (int)part.width * 4, rgba, ((y + row) * width + x) * 4, (int)part.width * 4);
            }
        return new NativeCursorRaster(rgba, geometry.width, geometry.height, geometry.hotspot_x, geometry.hotspot_y, geometry.blank != 0);
    }
}

/// <summary>The retained viewer's cursor rules (vncviewer/Viewport.cxx setCursor and showCursor).</summary>
public static class NativeCursorPolicy
{
    /// <summary>View-only shows the system arrow; a blank remote cursor follows the fallback; otherwise the remote cursor.</summary>
    public static NativeCursorChoice Choose(bool viewOnly, bool blank, NativeCursorFallback fallback) =>
        viewOnly ? NativeCursorChoice.System
        : !blank ? NativeCursorChoice.Remote
        : fallback switch
        {
            NativeCursorFallback.Dot => NativeCursorChoice.Dot,
            NativeCursorFallback.System => NativeCursorChoice.System,
            _ => NativeCursorChoice.Hidden,
        };

    /// <summary>The retained 5x5 dot (black 3x3 centre, white border, hotspot 2,2), enlarged by whole pixels for the display.</summary>
    public static NativeCursorRaster Dot(double deviceScale)
    {
        var factor = Math.Max(1, (int)Math.Round(deviceScale));
        var size = 5 * factor;
        var rgba = new byte[size * size * 4];
        for (var y = 0; y < size; y++)
            for (var x = 0; x < size; x++)
            {
                var inner = x / factor is >= 1 and <= 3 && y / factor is >= 1 and <= 3;
                var offset = (y * size + x) * 4;
                var value = inner ? (byte)0 : (byte)255;
                rgba[offset] = rgba[offset + 1] = rgba[offset + 2] = value;
                rgba[offset + 3] = 255;
            }
        var hotspot = (uint)(2 * factor + factor / 2);
        return new NativeCursorRaster(rgba, (uint)size, (uint)size, hotspot, hotspot, false);
    }

    /// <summary>A fully transparent 1x1 cursor: the pointer is hidden over the desktop.</summary>
    public static NativeCursorRaster Hidden { get; } = new(new byte[4], 1, 1, 0, 0, true);

    /// <summary>
    /// A scale that keeps the sampled cursor within the largest cursor Windows accepts. A remote cursor
    /// larger than that at the view's scale is shown at the largest size that fits (the software cursor
    /// of DESKTOP.md section 3 remains a later step).
    /// </summary>
    public static (double X, double Y) FitScale(uint remoteWidth, uint remoteHeight, double scaleX, double scaleY, uint maxWidth, uint maxHeight)
    {
        if (remoteWidth == 0 || remoteHeight == 0 || maxWidth == 0 || maxHeight == 0) return (scaleX, scaleY);
        var shrink = Math.Min(1.0, Math.Min(maxWidth / (remoteWidth * scaleX), maxHeight / (remoteHeight * scaleY)));
        return (scaleX * shrink, scaleY * shrink);
    }
}
