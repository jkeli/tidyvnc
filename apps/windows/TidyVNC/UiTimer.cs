// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.UI.Dispatching;

namespace TidyVNC;

/// <summary>
/// A one-shot timer whose tick runs on the creating thread's DispatcherQueue and which Dispose frees. A
/// DispatcherQueueTimer keeps a waitable timer and a thread-pool wait after it is released (found by the
/// full-screen leak test, W6.11), so objects created per view or per window use this instead: a
/// System.Threading.Timer posts to the UI thread, where only a tick that is due still fires.
/// </summary>
internal sealed partial class UiTimer : IDisposable
{
    private readonly DispatcherQueue queue = DispatcherQueue.GetForCurrentThread();
    private readonly Action tick;
    private readonly Timer timer;
    private long due;
    private bool disposed;

    public UiTimer(Action tick)
    {
        this.tick = tick;
        timer = new Timer(_ => queue.TryEnqueue(Fire));
    }

    public TimeSpan Interval { get; set; }

    public bool IsRunning { get; private set; }

    public void Start()
    {
        if (disposed) return;
        var interval = Interval < TimeSpan.Zero ? TimeSpan.Zero : Interval;
        due = Environment.TickCount64 + (long)interval.TotalMilliseconds;
        IsRunning = true;
        timer.Change(interval, Timeout.InfiniteTimeSpan);
    }

    public void Stop()
    {
        IsRunning = false;
        if (!disposed) timer.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    /// <summary>On the UI thread: a callback from an earlier Start or after Stop does nothing.</summary>
    private void Fire()
    {
        if (disposed || !IsRunning || Environment.TickCount64 < due) return;
        IsRunning = false;
        tick();
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        IsRunning = false;
        timer.Dispose();
    }
}
