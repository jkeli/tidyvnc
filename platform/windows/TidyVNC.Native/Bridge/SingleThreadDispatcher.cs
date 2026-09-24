// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Concurrent;

namespace TidyVNC.Native;

/// <summary>
/// A dedicated thread with a work queue and a matching SynchronizationContext,
/// standing in for the WinUI DispatcherQueue in tests and console hosts. Awaits
/// started on it resume on it, as they do on the app's UI thread.
/// </summary>
public sealed class SingleThreadDispatcher : IUiDispatcher, IDisposable
{
    private readonly BlockingCollection<Action> queue = new();
    private readonly Thread thread;
    private readonly Context context;

    public SingleThreadDispatcher(string name = "TidyVNC UI")
    {
        context = new Context(this);
        thread = new Thread(Run) { IsBackground = true, Name = name };
        thread.Start();
    }

    public bool HasThreadAccess => Thread.CurrentThread == thread;

    public bool TryEnqueue(Action action)
    {
        try { queue.Add(action); return true; }
        catch (InvalidOperationException) { return false; }
    }

    /// <summary>Runs a function on the dispatcher thread and returns its result.</summary>
    public Task<T> InvokeAsync<T>(Func<T> function)
    {
        var result = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!TryEnqueue(() => { try { result.SetResult(function()); } catch (Exception e) { result.SetException(e); } }))
            result.SetException(new ObjectDisposedException(nameof(SingleThreadDispatcher)));
        return result.Task;
    }

    /// <summary>Runs an async function on the dispatcher thread; its continuations stay there.</summary>
    public Task<T> InvokeAsync<T>(Func<Task<T>> function)
        => InvokeAsync<Task<T>>(function).Unwrap();

    public Task InvokeAsync(Func<Task> function)
        => InvokeAsync<Task>(function).Unwrap();

    public Task InvokeAsync(Action action) => InvokeAsync(() => { action(); return true; });

    private void Run()
    {
        SynchronizationContext.SetSynchronizationContext(context);
        foreach (var action in queue.GetConsumingEnumerable())
        {
            try { action(); }
            catch (Exception error) { Unhandled?.Invoke(error); }
        }
    }

    /// <summary>Exceptions escaping queued work (tests assert there are none).</summary>
    public event Action<Exception>? Unhandled;

    public void Dispose()
    {
        queue.CompleteAdding();
        if (!HasThreadAccess) thread.Join(TimeSpan.FromSeconds(10));
    }

    private sealed class Context(SingleThreadDispatcher owner) : SynchronizationContext
    {
        public override void Post(SendOrPostCallback callback, object? state) => owner.TryEnqueue(() => callback(state));

        public override void Send(SendOrPostCallback callback, object? state)
        {
            if (owner.HasThreadAccess) { callback(state); return; }
            owner.InvokeAsync(() => callback(state)).GetAwaiter().GetResult();
        }

        public override SynchronizationContext CreateCopy() => this;
    }
}
