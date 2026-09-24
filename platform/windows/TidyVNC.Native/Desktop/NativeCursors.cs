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
    public static NativeCursorRaster Sample(NativeImage cursor, double scaleX, double scaleY, NativeScalingFilter filter)
    {
        using var tiles = new NativeCursorTiles(cursor, scaleX, scaleY, filter);
        int width = (int)tiles.Width, height = (int)tiles.Height;
        var rgba = new byte[width * height * 4];
        foreach (var tile in tiles.Render(new NativePixelRect(0, 0, tiles.Width, tiles.Height)).Tiles)
            for (var row = 0; row < tile.Rect.Height; row++)
                Array.Copy(tile.Rgba, row * (int)tile.Rect.Width * 4, rgba, (((int)tile.Rect.Y + row) * width + (int)tile.Rect.X) * 4, (int)tile.Rect.Width * 4);
        return new NativeCursorRaster(rgba, tiles.Width, tiles.Height, tiles.HotspotX, tiles.HotspotY, tiles.Blank);
    }
}

/// <summary>One tile of a sampled cursor: its rectangle in cursor device pixels and straight RGBA.</summary>
public sealed record NativeCursorTile(NativePixelRect Rect, byte[] Rgba)
{
    /// <summary>The tile as premultiplied BGRA, the layout of a WinUI WriteableBitmap.</summary>
    public byte[] PremultipliedBgra()
    {
        var bgra = new byte[Rgba.Length];
        for (var i = 0; i < Rgba.Length; i += 4)
        {
            int alpha = Rgba[i + 3];
            bgra[i] = (byte)((Rgba[i + 2] * alpha + 127) / 255);
            bgra[i + 1] = (byte)((Rgba[i + 1] * alpha + 127) / 255);
            bgra[i + 2] = (byte)((Rgba[i] * alpha + 127) / 255);
            bgra[i + 3] = (byte)alpha;
        }
        return bgra;
    }
}

/// <summary>
/// The shared cursor sampler held open for one cursor at one scale and filter
/// (the macOS NativeCursorRenderer): 256-pixel tiles, rendered only where the
/// cursor is visible and reused while only the pointer moves. Cursors larger
/// than Windows accepts are drawn from these tiles (DESKTOP.md section 3).
/// </summary>
public sealed unsafe class NativeCursorTiles : IDisposable
{
    public const uint TileSize = 256;
    private readonly NativeHandle sampler;
    private Dictionary<NativePixelRect, NativeCursorTile> previous = new();

    public NativeCursorTiles(NativeImage cursor, double scaleX, double scaleY, NativeScalingFilter filter)
    {
        var options = Abi.Init<tidyvnc_cursor_options>();
        options.quality = (uint)filter; options.scale_x = scaleX; options.scale_y = scaleY;
        var geometry = Abi.Init<tidyvnc_cursor_geometry>();
        var error = Abi.Init<tidyvnc_error>();
        ulong raw;
        Abi.Check(NativeMethods.tidyvnc_cursor_renderer_create(cursor.Handle.Raw, &options, &raw, &geometry, &error), &error);
        sampler = NativeHandle.Adopt(raw);
        Image = cursor; ScaleX = scaleX; ScaleY = scaleY; Filter = filter;
        Width = geometry.width; Height = geometry.height;
        HotspotX = geometry.hotspot_x; HotspotY = geometry.hotspot_y; Blank = geometry.blank != 0;
    }

    public NativeImage Image { get; }
    public double ScaleX { get; }
    public double ScaleY { get; }
    public NativeScalingFilter Filter { get; }
    /// <summary>The sampled cursor in device pixels, with its hotspot.</summary>
    public uint Width { get; }
    public uint Height { get; }
    public uint HotspotX { get; }
    public uint HotspotY { get; }
    /// <summary>Every sampled pixel is transparent.</summary>
    public bool Blank { get; }

    /// <summary>Whether these tiles are of this cursor at this scale and filter.</summary>
    public bool Samples(NativeImage cursor, double scaleX, double scaleY, NativeScalingFilter filter) =>
        ReferenceEquals(Image, cursor) && ScaleX == scaleX && ScaleY == scaleY && Filter == filter;

    /// <summary>
    /// The tiles of the 256-pixel grid that cover a region of the cursor. Tiles
    /// of the previous call with the same rectangle are reused; an empty region
    /// gives no tiles.
    /// </summary>
    public (IReadOnlyList<NativeCursorTile> Tiles, int Reused) Render(NativePixelRect region)
    {
        ObjectDisposedException.ThrowIf(sampler.IsClosed, this);
        var right = Math.Min(Width, region.X + region.Width);
        var bottom = Math.Min(Height, region.Y + region.Height);
        var tiles = new List<NativeCursorTile>();
        var current = new Dictionary<NativePixelRect, NativeCursorTile>();
        var reused = 0;
        if (region.Width > 0 && region.Height > 0 && region.X < right && region.Y < bottom)
            for (var y = region.Y / TileSize * TileSize; y < bottom; y += TileSize)
                for (var x = region.X / TileSize * TileSize; x < right; x += TileSize)
                {
                    var rect = new NativePixelRect(x, y, Math.Min(TileSize, Width - x), Math.Min(TileSize, Height - y));
                    if (previous.TryGetValue(rect, out var tile)) reused++;
                    else tile = RenderTile(rect);
                    tiles.Add(tile);
                    current[rect] = tile;
                }
        previous = current;
        return (tiles, reused);
    }

    private NativeCursorTile RenderTile(NativePixelRect rect)
    {
        var rgba = new byte[checked((int)(rect.Width * rect.Height * 4))];
        var part = Abi.Init<tidyvnc_cursor_tile>();
        part.x = rect.X; part.y = rect.Y; part.width = rect.Width; part.height = rect.Height;
        var error = Abi.Init<tidyvnc_error>();
        fixed (byte* p = rgba)
        {
            var span = new tidyvnc_mutable_bytes { data = p, length = (ulong)rgba.Length };
            Abi.Check(NativeMethods.tidyvnc_cursor_renderer_render(sampler.Raw, &part, span, &error), &error);
        }
        return new NativeCursorTile(rect, rgba);
    }

    public void Dispose()
    {
        previous = new();
        sampler.Dispose();
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
    /// Whether a remote cursor at the view's scale is larger than the largest cursor Windows accepts, so it
    /// is drawn as a software cursor over the desktop (DESKTOP.md section 3) instead of an HCURSOR.
    /// </summary>
    public static bool NeedsSoftware(uint remoteWidth, uint remoteHeight, double scaleX, double scaleY, uint maxWidth, uint maxHeight) =>
        Math.Ceiling(remoteWidth * scaleX) > maxWidth || Math.Ceiling(remoteHeight * scaleY) > maxHeight;

    /// <summary>
    /// A software cursor's top-left in logical units: the hotspot on the device pixel under the pointer
    /// (macOS NativeCursorRenderer), so the cursor's pixels stay on the device-pixel grid.
    /// </summary>
    public static (double X, double Y) SoftwareOrigin(double pointX, double pointY, double backingScale, uint hotspotX, uint hotspotY) =>
        ((Math.Floor(pointX * backingScale) - hotspotX) / backingScale, (Math.Floor(pointY * backingScale) - hotspotY) / backingScale);

    /// <summary>
    /// The part of a software cursor inside the clip (the desktop's visible rectangle, logical units), as
    /// whole cursor device pixels rounded outwards; empty when none of it is visible (macOS clipping).
    /// </summary>
    public static NativePixelRect VisibleRegion(uint width, uint height, (double X, double Y) origin, double backingScale,
                                                (double X, double Y, double Width, double Height) clip)
    {
        var q = backingScale;
        double left = Math.Max(origin.X, clip.X), top = Math.Max(origin.Y, clip.Y);
        double right = Math.Min(origin.X + width / q, clip.X + clip.Width), bottom = Math.Min(origin.Y + height / q, clip.Y + clip.Height);
        if (!(right > left && bottom > top)) return new NativePixelRect(0, 0, 0, 0);
        var x0 = Math.Clamp(Math.Floor((left - origin.X) * q), 0, width);
        var y0 = Math.Clamp(Math.Floor((top - origin.Y) * q), 0, height);
        var x1 = Math.Clamp(Math.Ceiling((right - origin.X) * q), x0, width);
        var y1 = Math.Clamp(Math.Ceiling((bottom - origin.Y) * q), y0, height);
        return new NativePixelRect((uint)x0, (uint)y0, (uint)(x1 - x0), (uint)(y1 - y0));
    }
}
