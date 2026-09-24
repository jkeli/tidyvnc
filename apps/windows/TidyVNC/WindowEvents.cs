// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Foundation;

namespace TidyVNC;

/// <summary>
/// Window event handlers that do not keep a closed window alive (W6.11). A handler on a window's own event
/// (Closed, Activated, or its AppWindow's) that captures the window forms a cycle through the native event
/// source that the collector cannot see, because a Window is not reference-tracked; left attached, it kept
/// every closed window with its XAML tree and composition resources for the rest of the run (about 70
/// handles per connection window). These subscribe and remove themselves when the window closes.
/// </summary>
internal static class WindowEvents
{
    /// <summary>Runs <paramref name="action"/> once when the window closes, after removing its own handler.</summary>
    public static void OnClosed(this Window window, Action action)
    {
        TypedEventHandler<object, WindowEventArgs>? handler = null;
        handler = (_, _) =>
        {
            window.Closed -= handler;
            action();
        };
        window.Closed += handler;
    }

    /// <summary>Activated, until the window closes.</summary>
    public static void OnActivated(this Window window, TypedEventHandler<object, WindowActivatedEventArgs> handler)
    {
        window.Activated += handler;
        window.OnClosed(() => window.Activated -= handler);
    }

    /// <summary>AppWindow.Closing, until the window closes.</summary>
    public static void OnAppWindowClosing(this Window window, TypedEventHandler<AppWindow, AppWindowClosingEventArgs> handler)
    {
        var appWindow = window.AppWindow;
        appWindow.Closing += handler;
        window.OnClosed(() => appWindow.Closing -= handler);
    }

    /// <summary>AppWindow.Changed, until the window closes.</summary>
    public static void OnAppWindowChanged(this Window window, TypedEventHandler<AppWindow, AppWindowChangedEventArgs> handler)
    {
        var appWindow = window.AppWindow;
        appWindow.Changed += handler;
        window.OnClosed(() => appWindow.Changed -= handler);
    }
}
