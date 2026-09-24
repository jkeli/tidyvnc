// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
namespace TidyVNC.Native.Platform;

/// <summary>An active monitor (SERVICES.md section 7). Rectangles are physical pixels.</summary>
public sealed record NativeDisplay(
    ulong Id, TvwRect Bounds, TvwRect WorkArea, uint DpiX, uint DpiY, bool Primary, bool Mirrored, IntPtr Monitor, string Name)
{
    public double Scale => DpiX / 96.0;
}

public static unsafe class NativeDisplays
{
    public static IReadOnlyList<NativeDisplay> Query()
    {
        for (var capacity = 8u; ; capacity *= 2)
        {
            var buffer = new TvwDisplay[capacity];
            uint count;
            int hr;
            fixed (TvwDisplay* displays = buffer) hr = WindowsMethods.tvw_displays(displays, capacity, &count);
            if (hr == WindowsResult.NotSufficientBuffer && capacity < 1024) continue;
            WindowsResult.Check(hr, "Querying displays");
            var result = new NativeDisplay[count];
            for (var i = 0; i < count; i++)
            {
                ref var d = ref buffer[i];
                string name;
                fixed (char* text = d.name) name = new string(text);
                result[i] = new NativeDisplay(d.id, new TvwRect(d.x, d.y, d.width, d.height),
                    new TvwRect(d.work_x, d.work_y, d.work_width, d.work_height), d.dpi_x, d.dpi_y,
                    d.primary != 0, d.mirrored != 0, new IntPtr(unchecked((long)d.monitor)), name);
            }
            return result;
        }
    }
}

/// <summary>A remote cursor as an HCURSOR (D13). Dispose destroys it.</summary>
public sealed unsafe class NativeCursorHandle : IDisposable
{
    private ulong cursor;

    public NativeCursorHandle(ReadOnlySpan<byte> rgba, uint width, uint height, uint hotspotX, uint hotspotY)
    {
        if ((ulong)rgba.Length < (ulong)width * height * 4) throw new ArgumentException("Cursor pixels are too short", nameof(rgba));
        ulong value;
        fixed (byte* pixels = rgba)
            WindowsResult.Check(WindowsMethods.tvw_cursor_create(pixels, width, height, hotspotX, hotspotY, &value), "Creating a cursor");
        cursor = value;
    }

    public IntPtr Handle => new(unchecked((long)cursor));

    public static (uint Width, uint Height) Limits
    {
        get
        {
            uint width, height;
            WindowsMethods.tvw_cursor_limits(&width, &height);
            return (width, height);
        }
    }

    public void Dispose()
    {
        if (cursor == 0) return;
        WindowsMethods.tvw_cursor_destroy(cursor);
        cursor = 0;
    }
}
