// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TidyVNC;

/// <summary>A dialog a window wants shown: a stable key, how to build it, and what its result means.</summary>
internal sealed record DialogRequest(string Key, Func<ContentDialog> Create, Action<ContentDialogResult> Completed, Action? Superseded = null);

/// <summary>
/// One ContentDialog per window at a time (UX.md section 5). The window
/// computes the dialog it wants from its state, in the macOS sheet priority
/// order; when that changes, the shown dialog is withdrawn (its result is not
/// applied; a settings dialog gets its Superseded action, which cancels it)
/// and the new one is shown. Late results for a withdrawn dialog are ignored.
/// </summary>
internal sealed class DialogPresenter(Func<XamlRoot?> root, Func<DialogRequest?> desired)
{
    private sealed class Shown(DialogRequest request, ContentDialog dialog)
    {
        public DialogRequest Request { get; } = request;
        public ContentDialog Dialog { get; } = dialog;
        public bool Withdrawn { get; set; }
        public TaskCompletionSource Closed { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private Shown? shown;
    private bool running, again, stopped;

    private static readonly object WithdrawnTag = new();

    /// <summary>True while the presenter is taking this dialog down; its Closing handler must not refuse.</summary>
    public static bool IsWithdrawn(ContentDialog dialog) => ReferenceEquals(dialog.Tag, WithdrawnTag);

    /// <summary>The key of the dialog on screen (tests and automation).</summary>
    public string? Current => shown?.Request.Key;

    public void Update()
    {
        if (stopped) return;
        if (running) { again = true; return; }
        _ = Run();
    }

    private async Task Run()
    {
        running = true;
        try
        {
            do
            {
                again = false;
                var next = stopped ? null : desired();
                if (shown is { } current)
                {
                    if (next?.Key == current.Request.Key) continue;
                    current.Withdrawn = true;
                    current.Dialog.Tag = WithdrawnTag;
                    current.Request.Superseded?.Invoke();
                    current.Dialog.Hide();
                    await current.Closed.Task;
                    continue; // The state may have changed while it closed.
                }
                if (next is null || root() is not { } xamlRoot) continue;
                var dialog = next.Create();
                dialog.XamlRoot = xamlRoot;
                var entry = new Shown(next, dialog);
                shown = entry;
                _ = Present(entry);
            }
            while (again);
        }
        finally { running = false; }
    }

    private async Task Present(Shown entry)
    {
        ContentDialogResult result;
        try { result = await entry.Dialog.ShowAsync(); }
        catch (Exception error) when (error is InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            // Another dialog owns the XamlRoot (for example a file dialog's parent); retry later.
            result = ContentDialogResult.None;
            entry.Withdrawn = true;
        }
        if (ReferenceEquals(shown, entry)) shown = null;
        entry.Closed.TrySetResult();
        if (!entry.Withdrawn && !stopped) entry.Request.Completed(result);
        Update();
    }

    /// <summary>The window is closing: withdraw everything and show nothing more.</summary>
    public void Close()
    {
        stopped = true;
        if (shown is { } current) { current.Withdrawn = true; current.Dialog.Tag = WithdrawnTag; current.Dialog.Hide(); }
    }
}

internal static class WindowSizes
{
    /// <summary>Default and minimum sizes in effective pixels (UX.md section 2), scaled to the window's display.</summary>
    public static void Apply(AppWindow window, int width, int height, int minimumWidth, int minimumHeight)
    {
        var scale = Math.Max(1.0, GetScale(window));
        window.Resize(new Windows.Graphics.SizeInt32((int)(width * scale), (int)(height * scale)));
        if (window.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)(minimumWidth * scale);
            presenter.PreferredMinimumHeight = (int)(minimumHeight * scale);
        }
    }

    private static double GetScale(AppWindow window)
    {
        var dpi = TidyVNC.Native.Platform.NativeWindows.DpiForWindow(Microsoft.UI.Win32Interop.GetWindowFromWindowId(window.Id));
        return dpi > 0 ? dpi / 96.0 : 1.0;
    }
}
