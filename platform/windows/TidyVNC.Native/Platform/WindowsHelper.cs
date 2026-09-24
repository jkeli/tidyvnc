// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace TidyVNC.Native.Platform;

/// <summary>tidyvnc_windows.h structures (platform/windows/Native).</summary>
[StructLayout(LayoutKind.Sequential)]
public struct TvwRect
{
    public int X, Y, Width, Height;
    public TvwRect(int x, int y, int width, int height) { X = x; Y = y; Width = width; Height = height; }
    public readonly bool IsEmpty => Width <= 0 || Height <= 0;
    public readonly int Right => X + Width;
    public readonly int Bottom => Y + Height;
    public readonly TvwRect Union(TvwRect other)
    {
        if (IsEmpty) return other;
        if (other.IsEmpty) return this;
        int left = Math.Min(X, other.X), top = Math.Min(Y, other.Y);
        return new TvwRect(left, top, Math.Max(Right, other.Right) - left, Math.Max(Bottom, other.Bottom) - top);
    }
    public readonly TvwRect Intersect(TvwRect other)
    {
        int left = Math.Max(X, other.X), top = Math.Max(Y, other.Y);
        int right = Math.Min(Right, other.Right), bottom = Math.Min(Bottom, other.Bottom);
        return right > left && bottom > top ? new TvwRect(left, top, right - left, bottom - top) : default;
    }
    public override readonly string ToString() => $"{X},{Y} {Width}x{Height}";
}

[StructLayout(LayoutKind.Sequential)]
internal struct TvwKeyEvent
{
    public uint kind;
    public int system_key_code;
    public uint key_code;
    public uint keysym;
}

[StructLayout(LayoutKind.Sequential)]
public struct TvwKeyMessage
{
    public uint Message;
    public ulong WParam;
    public long LParam;
    public uint Time;
    public uint Reserved;
    /// <summary>The target window (hook messages only).</summary>
    public ulong Window;
}

[StructLayout(LayoutKind.Sequential)]
internal struct TvwKeyResult
{
    public uint consumed, count, timer_pending, timer_delay_ms;
}

[StructLayout(LayoutKind.Sequential)]
internal struct TvwTouchAction
{
    public uint kind, press;
    public int button;
    public uint keysym;
    public double x, y;
}

[StructLayout(LayoutKind.Sequential)]
internal struct TvwTouchResult
{
    public uint count, more;
    public ulong deadline_ms;
}

[StructLayout(LayoutKind.Sequential)]
internal unsafe struct TvwDisplay
{
    public ulong id;
    public int x, y, width, height;
    public int work_x, work_y, work_width, work_height;
    public uint dpi_x, dpi_y, primary, mirrored;
    public ulong monitor;
    public fixed char name[64];
}

internal static unsafe partial class WindowsMethods
{
    private const string Library = "tidyvnc_windows";

    [LibraryImport(Library)] internal static partial int tvw_presenter_create(IntPtr* presenter);
    [LibraryImport(Library)] internal static partial int tvw_presenter_attach(IntPtr presenter, IntPtr panel);
    [LibraryImport(Library)] internal static partial int tvw_presenter_resize(IntPtr presenter, uint width, uint height, float scaleX, float scaleY);
    [LibraryImport(Library)] internal static partial int tvw_presenter_clear(IntPtr presenter, TvwRect* area);
    [LibraryImport(Library)] internal static partial int tvw_presenter_upload(IntPtr presenter, byte* bgra, uint stride, TvwRect* area);
    [LibraryImport(Library)] internal static partial int tvw_presenter_present(IntPtr presenter, TvwRect* dirty, uint count);
    [LibraryImport(Library)] internal static partial int tvw_presenter_read(IntPtr presenter, TvwRect* area, byte* bgra, uint stride);
    [LibraryImport(Library)] internal static partial void tvw_presenter_destroy(IntPtr presenter);

    [LibraryImport(Library)] internal static partial int tvw_keyboard_create(IntPtr* keyboard);
    [LibraryImport(Library)] internal static partial int tvw_keyboard_handle(IntPtr keyboard, TvwKeyMessage* message, TvwKeyEvent* events, uint capacity, TvwKeyResult* result);
    [LibraryImport(Library)] internal static partial int tvw_keyboard_timeout(IntPtr keyboard, TvwKeyEvent* events, uint capacity, TvwKeyResult* result);
    [LibraryImport(Library)] internal static partial void tvw_keyboard_reset(IntPtr keyboard);
    [LibraryImport(Library)] internal static partial void tvw_keyboard_destroy(IntPtr keyboard);
    [LibraryImport(Library)] internal static partial int tvw_keyboard_keysyms(IntPtr keyboard, int systemKeyCode, uint* keysyms, uint capacity, uint* count);
    [LibraryImport(Library)] internal static partial uint tvw_keyboard_led_state();
    [LibraryImport(Library)] internal static partial int tvw_keyboard_set_led_state(uint state);

    [LibraryImport(Library)] internal static partial int tvw_touch_create(ulong nowMs, IntPtr* touch);
    [LibraryImport(Library)] internal static partial int tvw_touch_handle(IntPtr touch, uint phase, int id, double x, double y, ulong nowMs,
                                                                          TvwTouchAction* actions, uint capacity, TvwTouchResult* result);
    [LibraryImport(Library)] internal static partial void tvw_touch_destroy(IntPtr touch);

    [LibraryImport(Library)] internal static partial int tvw_hook_install(delegate* unmanaged[Cdecl]<IntPtr, TvwKeyMessage*, uint> callback, IntPtr context, IntPtr* hook);
    [LibraryImport(Library)] internal static partial void tvw_hook_enable(IntPtr hook, uint enabled);
    [LibraryImport(Library)] internal static partial void tvw_hook_remove(IntPtr hook);
    [LibraryImport(Library)] internal static partial int tvw_capture_start(ulong targetWindow, IntPtr* capture);
    [LibraryImport(Library)] internal static partial void tvw_capture_stop(IntPtr capture);

    [LibraryImport(Library)] internal static partial int tvw_cursor_create(byte* rgba, uint width, uint height, uint hotspotX, uint hotspotY, ulong* cursor);
    [LibraryImport(Library)] internal static partial void tvw_cursor_destroy(ulong cursor);
    [LibraryImport(Library)] internal static partial void tvw_cursor_limits(uint* maxWidth, uint* maxHeight);

    [LibraryImport(Library)] internal static partial void tvw_quiet_crt_reports();

    [LibraryImport(Library)] internal static partial int tvw_displays(TvwDisplay* displays, uint capacity, uint* count);
}

/// <summary>HRESULTs the helper returns, and the conversion to exceptions.</summary>
public static class WindowsResult
{
    public const int NotSufficientBuffer = unchecked((int)0x8007007A);
    public const int DeviceRemoved = unchecked((int)0x887A0005);
    public const int DeviceReset = unchecked((int)0x887A0007);
    public const int DeviceHung = unchecked((int)0x887A0006);
    public const int DriverInternalError = unchecked((int)0x887A0020);
    public const int NotValidState = unchecked((int)0x8007139F);

    /// <summary>The presenter must be recreated (and reattached) after this result.</summary>
    public static bool IsDeviceLost(int hr) =>
        hr is DeviceRemoved or DeviceReset or DeviceHung or DriverInternalError or NotValidState;

    internal static void Check(int hr, string operation)
    {
        if (hr < 0) throw new WindowsHelperException(hr, operation);
    }
}

public sealed class WindowsHelperException(int result, string operation)
    : Exception($"{operation} failed (0x{result:X8})")
{
    public int Result { get; } = result;
    public bool IsDeviceLost => WindowsResult.IsDeviceLost(Result);
}
