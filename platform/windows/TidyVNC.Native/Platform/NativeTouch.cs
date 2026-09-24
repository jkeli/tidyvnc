// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
namespace TidyVNC.Native.Platform;

/// <summary>One retained fake event from a touch gesture: a pointer move, a button or a key.</summary>
public readonly record struct NativeTouchAction(NativeTouchAction.ActionKind Kind, bool Press, int Button, uint KeySym, double X, double Y)
{
    public enum ActionKind { Motion = 0, Button = 1, Key = 2 }
}

/// <summary>
/// Touch gestures on the desktop view (DESKTOP.md section 6; the retained
/// vncviewer/GestureHandler and BaseTouchHandler in tidyvnc_windows.dll):
/// touches in, the retained mouse and key events out. When
/// <see cref="Deadline"/> is set the owner calls <see cref="Timeout"/> at or
/// after it (long press, pinch/scroll decision). One per view, UI thread only.
/// </summary>
public sealed unsafe class NativeTouch : IDisposable
{
    private const int Capacity = 64;
    private enum Phase : uint { Begin = 0, Update = 1, End = 2, Timeout = 3, Drain = 4 }
    private IntPtr handle;
    private readonly Func<ulong> clock;

    /// <param name="clock">Milliseconds, monotonic (Environment.TickCount64 by default).</param>
    public NativeTouch(Func<ulong>? clock = null)
    {
        this.clock = clock ?? (() => (ulong)Environment.TickCount64);
        IntPtr value;
        WindowsResult.Check(WindowsMethods.tvw_touch_create(this.clock(), &value), "Creating the touch gesture engine");
        handle = value;
    }

    private IntPtr Handle => handle != IntPtr.Zero ? handle : throw new ObjectDisposedException(nameof(NativeTouch));

    /// <summary>The time the owner must call <see cref="Timeout"/>, in the clock's milliseconds, or null.</summary>
    public ulong? Deadline { get; private set; }

    public IReadOnlyList<NativeTouchAction> Begin(int id, double x, double y) => Run(Phase.Begin, id, x, y);
    public IReadOnlyList<NativeTouchAction> Update(int id, double x, double y) => Run(Phase.Update, id, x, y);
    public IReadOnlyList<NativeTouchAction> End(int id) => Run(Phase.End, id, 0, 0);
    public IReadOnlyList<NativeTouchAction> Timeout() => Run(Phase.Timeout, 0, 0, 0);

    private List<NativeTouchAction> Run(Phase phase, int id, double x, double y)
    {
        var buffer = stackalloc TvwTouchAction[Capacity];
        var actions = new List<NativeTouchAction>();
        TvwTouchResult result;
        WindowsResult.Check(WindowsMethods.tvw_touch_handle(Handle, (uint)phase, id, x, y, clock(), buffer, Capacity, &result), "Handling a touch");
        for (;;)
        {
            for (var i = 0; i < result.count; i++)
                actions.Add(new NativeTouchAction((NativeTouchAction.ActionKind)buffer[i].kind, buffer[i].press != 0, buffer[i].button,
                                                  buffer[i].keysym, buffer[i].x, buffer[i].y));
            if (result.more == 0) break;
            WindowsResult.Check(WindowsMethods.tvw_touch_handle(Handle, (uint)Phase.Drain, 0, 0, 0, clock(), buffer, Capacity, &result),
                                "Handling a touch");
        }
        Deadline = result.deadline_ms == ulong.MaxValue ? null : result.deadline_ms;
        return actions;
    }

    public void Dispose()
    {
        if (handle == IntPtr.Zero) return;
        WindowsMethods.tvw_touch_destroy(handle);
        handle = IntPtr.Zero;
    }
}
