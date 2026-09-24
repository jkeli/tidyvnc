// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Platform;

namespace TidyVNC;

/// <summary>
/// Routes the UI thread's keyboard messages to the focused desktop view before
/// XAML sees them (DECISIONS.md D12, DESKTOP.md section 5). The hook is enabled
/// only while a desktop view has focus; messages for other windows pass.
/// </summary>
internal sealed class KeyboardRouter : IDisposable
{
    private readonly NativeMessageHook hook;
    private DesktopView? focused;

    public KeyboardRouter()
    {
        hook = new NativeMessageHook(Route);
    }

    public DesktopView? Focused
    {
        get => focused;
        set
        {
            focused = value;
            hook.Enabled = value is not null;
        }
    }

    public bool IsInstalled => hook.IsInstalled;

    private bool Route(TvwKeyMessage message)
    {
        var view = focused;
        if (view is null) return false;
        var root = NativeWindows.Root(new IntPtr(unchecked((long)message.Window)));
        if (root != view.WindowHandle) return false;
        return view.HandleKeyMessage(message);
    }

    public void Dispose() => hook.Dispose();
}
