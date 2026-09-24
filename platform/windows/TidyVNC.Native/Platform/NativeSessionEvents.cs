// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;

namespace TidyVNC.Native.Platform;

public enum NativeSessionEvent { Locked, Unlocked, Suspending, Resumed }

/// <summary>
/// Session, power and sign-out notifications (SERVICES.md section 13) from
/// a hidden top-level window on its own thread: WTS lock/unlock,
/// suspend/resume, and WM_QUERYENDSESSION/WM_ENDSESSION. Changed is raised
/// on that thread; the app marshals to its UI thread. On sign-out or
/// restart the app's shutdown runs with a shutdown block reason shown, and
/// WM_ENDSESSION waits (bounded) for it; nothing registers for restart, so
/// connections are never restored automatically.
/// </summary>
public sealed unsafe class NativeSessionEvents : IDisposable
{
    private const uint QueryEndSession = 0x0011, EndSession = 0x0016, SessionChange = 0x02B1, PowerBroadcast = 0x0218, Quit = 0x8001;
    private const nuint SessionLock = 7, SessionUnlock = 8;
    private const nuint Suspend = 4, ResumeAutomatic = 0x12, ResumeSuspend = 7;
    private static readonly Dictionary<nint, NativeSessionEvents> Listeners = [];

    private readonly Thread thread;
    private readonly TaskCompletionSource<nint> ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Func<Task>? endSession;
    private readonly TimeSpan endSessionDeadline;
    private HWND window;
    private Task? ending;
    private bool disposed;

    public event Action<NativeSessionEvent>? Changed;

    /// <param name="endSession">Starts the app's shutdown for sign-out or restart; completes when drained.</param>
    /// <param name="blockReason">Shown by Windows while the app drains during sign-out.</param>
    public NativeSessionEvents(Func<Task>? endSession = null, string blockReason = "Closing remote desktop connections", TimeSpan? endSessionDeadline = null)
    {
        this.endSession = endSession;
        this.endSessionDeadline = endSessionDeadline ?? TimeSpan.FromSeconds(5);
        BlockReason = blockReason;
        thread = new Thread(Run) { IsBackground = true, Name = "TidyVNC session events" };
        thread.Start();
        window = new HWND(ready.Task.GetAwaiter().GetResult());
    }

    public string BlockReason { get; }
    /// <summary>True from WM_QUERYENDSESSION until the drain finished (tests).</summary>
    public bool EndingSession => ending is { IsCompleted: false };

    /// <summary>Tests deliver a message as Windows would; returns the window procedure's result.</summary>
    internal nint Deliver(uint message, nuint wParam = 0, nint lParam = 0) => PInvoke.SendMessage(window, message, new WPARAM(wParam), new LPARAM(lParam)).Value;

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static LRESULT WindowProcedure(HWND hwnd, uint message, WPARAM wParam, LPARAM lParam)
    {
        NativeSessionEvents? owner;
        lock (Listeners) Listeners.TryGetValue((nint)hwnd.Value, out owner);
        if (owner is not null)
        {
            try
            {
                switch (message)
                {
                    case Quit:
                        PInvoke.DestroyWindow(hwnd);
                        PInvoke.PostQuitMessage(0);
                        return new LRESULT(0);
                    case SessionChange when wParam.Value == SessionLock:
                        owner.Changed?.Invoke(NativeSessionEvent.Locked);
                        break;
                    case SessionChange when wParam.Value == SessionUnlock:
                        owner.Changed?.Invoke(NativeSessionEvent.Unlocked);
                        break;
                    case PowerBroadcast when wParam.Value == Suspend:
                        owner.Changed?.Invoke(NativeSessionEvent.Suspending);
                        break;
                    case PowerBroadcast when wParam.Value is ResumeAutomatic or ResumeSuspend:
                        owner.Changed?.Invoke(NativeSessionEvent.Resumed);
                        break;
                    case QueryEndSession:
                        owner.BeginEndSession();
                        return new LRESULT(1); // Never veto sign-out; drain while Windows shows the reason.
                    case EndSession:
                        if (wParam.Value != 0) owner.FinishEndSession();
                        else owner.CancelEndSession();
                        return new LRESULT(0);
                }
            }
            catch (Exception error) { System.Diagnostics.Trace.TraceError($"Session event handling failed: {error.GetType().Name}"); }
        }
        return PInvoke.DefWindowProc(hwnd, message, wParam, lParam);
    }

    private void BeginEndSession()
    {
        if (ending is not null || endSession is null) return;
        fixed (char* reason = BlockReason) PInvoke.ShutdownBlockReasonCreate(window, reason);
        ending = Task.Run(endSession);
    }

    /// <summary>The session ends when this returns: give the drain a bounded chance to finish.</summary>
    private void FinishEndSession()
    {
        try { ending?.Wait(endSessionDeadline); }
        catch (AggregateException) { }
        PInvoke.ShutdownBlockReasonDestroy(window);
    }

    /// <summary>Another application vetoed the sign-out; the app is already closing its windows and keeps going.</summary>
    private void CancelEndSession() => PInvoke.ShutdownBlockReasonDestroy(window);

    private void Run()
    {
        HWND created;
        nint power = 0;
        try
        {
            var name = "TidyVNC.Session." + Environment.ProcessId + "." + Environment.CurrentManagedThreadId;
            fixed (char* className = name)
            {
                var windowClass = new WNDCLASSEXW { cbSize = (uint)sizeof(WNDCLASSEXW), lpfnWndProc = &WindowProcedure, lpszClassName = className };
                if (PInvoke.RegisterClassEx(&windowClass) == 0) throw new InvalidOperationException("Session window class");
            }
            // Top-level (hidden): WM_QUERYENDSESSION and power broadcasts never reach message-only windows.
            created = PInvoke.CreateWindowEx(WINDOW_EX_STYLE.WS_EX_TOOLWINDOW, name, null, WINDOW_STYLE.WS_POPUP, 0, 0, 0, 0, HWND.Null, null, null, null);
            if (created.IsNull) throw new InvalidOperationException("Session window");
            lock (Listeners) Listeners[(nint)created.Value] = this;
            PInvoke.WTSRegisterSessionNotification(created, 0); // NOTIFY_FOR_THIS_SESSION
            // Modern Standby delivers suspend/resume only to registered recipients.
            if (Power.PowerRegisterSuspendResumeNotification(1 /* DEVICE_NOTIFY_WINDOW_HANDLE */, (nint)created.Value, out var registration) == 0)
                power = registration;
            ready.SetResult((nint)created.Value);
        }
        catch (Exception error)
        {
            ready.SetException(error);
            return;
        }
        MSG message;
        while (PInvoke.GetMessage(&message, HWND.Null, 0, 0) > 0)
        {
            PInvoke.TranslateMessage(&message);
            PInvoke.DispatchMessage(&message);
        }
        PInvoke.WTSUnRegisterSessionNotification(created);
        if (power != 0) _ = Power.PowerUnregisterSuspendResumeNotification(power);
        lock (Listeners) Listeners.Remove((nint)created.Value);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        PInvoke.PostMessage(window, Quit, default, default);
        thread.Join(TimeSpan.FromSeconds(5));
    }
}

internal static partial class Power
{
    [LibraryImport("powrprof.dll")]
    internal static partial uint PowerRegisterSuspendResumeNotification(uint flags, nint recipient, out nint registration);

    [LibraryImport("powrprof.dll")]
    internal static partial uint PowerUnregisterSuspendResumeNotification(nint registration);
}

/// <summary>
/// The bell (SERVICES.md section 14): MessageBeep(MB_OK), coalesced so that
/// any number of bells in one delivery turn sound once.
/// </summary>
public sealed class NativeBell(IUiDispatcher dispatcher, Action? sound = null)
{
    private readonly Action sound = sound ?? (() => PInvoke.MessageBeep(MESSAGEBOX_STYLE.MB_OK));
    private int queued;

    public void Ring()
    {
        if (Interlocked.Exchange(ref queued, 1) != 0) return;
        if (!dispatcher.TryEnqueue(() =>
            {
                Volatile.Write(ref queued, 0);
                sound();
            }))
            Volatile.Write(ref queued, 0);
    }
}
