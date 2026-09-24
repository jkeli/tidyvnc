// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;

namespace TidyVNC.Native.Platform;

/// <summary>Small window queries for the app's input routing (CsWin32).</summary>
public static class NativeWindows
{
    /// <summary>The top-level window that owns a (child) window, or zero.</summary>
    public static unsafe IntPtr Root(IntPtr window) =>
        (IntPtr)PInvoke.GetAncestor(new HWND((void*)window), GET_ANCESTOR_FLAGS.GA_ROOT).Value;

    /// <summary>The window's DPI (96 at 100%); per-monitor v2 aware.</summary>
    public static unsafe uint DpiForWindow(IntPtr window) => PInvoke.GetDpiForWindow(new HWND((void*)window));

    /// <summary>
    /// Makes a top-level window owned by another: it stays above its owner,
    /// has no taskbar button of its own and closes with it.
    /// </summary>
    public static unsafe void SetOwner(IntPtr window, IntPtr owner) =>
        PInvoke.SetWindowLongPtr(new HWND((void*)window), WINDOW_LONG_PTR_INDEX.GWLP_HWNDPARENT, owner);

    /// <summary>Minimizes a window whatever its presenter (a full-screen window has no Minimize of its own).</summary>
    public static unsafe void Minimize(IntPtr window) => PInvoke.ShowWindow(new HWND((void*)window), SHOW_WINDOW_CMD.SW_MINIMIZE);
}
