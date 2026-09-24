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
}
