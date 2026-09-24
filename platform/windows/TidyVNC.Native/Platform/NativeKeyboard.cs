// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace TidyVNC.Native.Platform;

/// <summary>One translated key event (the retained KeyboardHandler calls).</summary>
public readonly record struct NativeKeyEvent(bool Press, int SystemKeyCode, uint KeyCode, uint KeySym);

/// <summary>The outcome of one message: whether it was the keyboard's, and a pending AltGr decision.</summary>
public readonly record struct NativeKeyResult(bool Consumed, IReadOnlyList<NativeKeyEvent> Events, TimeSpan? TimerDelay);

/// <summary>
/// The retained Windows keyboard translation (vncviewer/KeyboardWin32 via
/// tidyvnc_windows.dll). One per desktop view, UI thread only. When a result
/// carries a timer delay the owner calls <see cref="Timeout"/> after it
/// unless another message arrives first.
/// </summary>
public sealed unsafe class NativeKeyboard : IDisposable
{
    private const int Capacity = 8;
    private IntPtr handle;

    public NativeKeyboard()
    {
        IntPtr value;
        WindowsResult.Check(WindowsMethods.tvw_keyboard_create(&value), "Creating the keyboard translator");
        handle = value;
    }

    private IntPtr Handle => handle != IntPtr.Zero ? handle : throw new ObjectDisposedException(nameof(NativeKeyboard));

    public NativeKeyResult Translate(in TvwKeyMessage message)
    {
        var events = stackalloc TvwKeyEvent[Capacity];
        TvwKeyResult result;
        fixed (TvwKeyMessage* input = &message)
            WindowsResult.Check(WindowsMethods.tvw_keyboard_handle(Handle, input, events, Capacity, &result), "Translating a key");
        return Convert(events, result);
    }

    public NativeKeyResult Timeout()
    {
        var events = stackalloc TvwKeyEvent[Capacity];
        TvwKeyResult result;
        WindowsResult.Check(WindowsMethods.tvw_keyboard_timeout(Handle, events, Capacity, &result), "Resolving AltGr");
        return Convert(events, result);
    }

    public void Reset() => WindowsMethods.tvw_keyboard_reset(Handle);

    /// <summary>Keysym candidates of a physical key, for shortcut matching.</summary>
    public uint[] KeySyms(int systemKeyCode)
    {
        var keysyms = stackalloc uint[64];
        uint count;
        WindowsResult.Check(WindowsMethods.tvw_keyboard_keysyms(Handle, systemKeyCode, keysyms, 64, &count), "Listing keysyms");
        return new ReadOnlySpan<uint>(keysyms, (int)count).ToArray();
    }

    /// <summary>RFB LED bits of the local keyboard (1 Scroll, 2 Num, 4 Caps).</summary>
    public static uint LedState => WindowsMethods.tvw_keyboard_led_state();

    /// <summary>Toggles local lock keys to match the server (synthesised input).</summary>
    public static void SetLedState(uint state) =>
        WindowsResult.Check(WindowsMethods.tvw_keyboard_set_led_state(state), "Updating keyboard LEDs");

    private static NativeKeyResult Convert(TvwKeyEvent* events, TvwKeyResult result)
    {
        var list = new NativeKeyEvent[result.count];
        for (var i = 0; i < list.Length; i++)
            list[i] = new NativeKeyEvent(events[i].kind == 1, events[i].system_key_code, events[i].key_code, events[i].keysym);
        return new NativeKeyResult(result.consumed != 0, list,
            result.timer_pending != 0 ? TimeSpan.FromMilliseconds(result.timer_delay_ms) : null);
    }

    public void Dispose()
    {
        if (handle == IntPtr.Zero) return;
        WindowsMethods.tvw_keyboard_destroy(handle);
        handle = IntPtr.Zero;
    }
}

/// <summary>
/// The UI-thread WH_GETMESSAGE hook (D12): keyboard messages reach the handler
/// before XAML; returning true replaces the message with WM_NULL. Mouse
/// messages are observed (they cancel AltGr detection) but never swallowed.
/// Install, enable and dispose on the UI thread.
/// </summary>
public sealed unsafe class NativeMessageHook : IDisposable
{
    private readonly Func<TvwKeyMessage, bool> handler;
    private GCHandle self;
    private IntPtr hook;

    public NativeMessageHook(Func<TvwKeyMessage, bool> handler)
    {
        this.handler = handler;
        self = GCHandle.Alloc(this);
        IntPtr value;
        var hr = WindowsMethods.tvw_hook_install(&Callback, GCHandle.ToIntPtr(self), &value);
        if (hr < 0) { self.Free(); WindowsResult.Check(hr, "Installing the keyboard hook"); }
        hook = value;
    }

    public bool Enabled
    {
        set { if (hook != IntPtr.Zero) WindowsMethods.tvw_hook_enable(hook, value ? 1u : 0u); }
    }

    /// <summary>The native handle, for <see cref="NativeKeyboardCapture"/>'s precondition.</summary>
    public bool IsInstalled => hook != IntPtr.Zero;

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static uint Callback(IntPtr context, TvwKeyMessage* message)
    {
        try
        {
            var owner = (NativeMessageHook)GCHandle.FromIntPtr(context).Target!;
            return owner.handler(*message) ? 1u : 0u;
        }
        catch (Exception error)
        {
            // Exceptions must not unwind into the message loop; let the message through.
            System.Diagnostics.Trace.TraceError($"Keyboard hook handler failed: {error}");
            return 0;
        }
    }

    public void Dispose()
    {
        if (hook == IntPtr.Zero) return;
        WindowsMethods.tvw_hook_remove(hook);
        hook = IntPtr.Zero;
        self.Free();
    }
}

/// <summary>
/// Low-level keyboard capture for one window (SERVICES.md section 8), as
/// vncviewer/win32.c. Requires the UI thread's <see cref="NativeMessageHook"/>.
/// </summary>
public sealed unsafe class NativeKeyboardCapture : IDisposable
{
    private IntPtr capture;

    public NativeKeyboardCapture(IntPtr window)
    {
        IntPtr value;
        WindowsResult.Check(WindowsMethods.tvw_capture_start((ulong)window, &value), "Starting keyboard capture");
        capture = value;
    }

    public void Dispose()
    {
        if (capture == IntPtr.Zero) return;
        WindowsMethods.tvw_capture_stop(capture);
        capture = IntPtr.Zero;
    }
}
