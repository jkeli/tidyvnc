// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

/// <summary>
/// The app's single UI thread (DECISIONS.md D7). The WinUI app adapts its
/// DispatcherQueue; tests use <see cref="SingleThreadDispatcher"/>.
/// </summary>
public interface IUiDispatcher
{
    /// <summary>True on the dispatcher's own thread.</summary>
    bool HasThreadAccess { get; }
    /// <summary>Queues work without blocking. False when the dispatcher has shut down.</summary>
    bool TryEnqueue(Action action);
}

internal static class UiThread
{
    public static void Require(IUiDispatcher dispatcher)
    {
        if (!dispatcher.HasThreadAccess)
            throw new InvalidOperationException("Native session state belongs to the UI thread");
    }
}

/// <summary>
/// Coalesced readiness delivery to the UI thread (NativeDelivery.swift). The C
/// callback only sets a flag and queues one UI work item; it never touches UI
/// state and returns at once. The UI-thread action drains mailboxes and
/// rechecks subscription identity and generation.
/// </summary>
internal sealed unsafe class NativeDelivery
{
    private readonly object gate = new();
    private readonly IUiDispatcher dispatcher;
    private readonly Action<ulong, ulong> action;
    private bool active = true, queued;
    private ulong generation;
    private int nativeReferences;
    private GCHandle self;
    private List<TaskCompletionSource>? waiters;

    public NativeDelivery(IUiDispatcher dispatcher, Action<ulong, ulong> action)
    {
        this.dispatcher = dispatcher;
        this.action = action;
        self = GCHandle.Alloc(this);
    }

    /// <summary>Callback table for tidyvnc_*_subscribe. The context keeps this object alive until released.</summary>
    public unsafe tidyvnc_callbacks Callbacks()
    {
        var callbacks = Abi.Init<tidyvnc_callbacks>();
        callbacks.context = (void*)GCHandle.ToIntPtr(self);
        callbacks.retain_context = &RetainContext;
        callbacks.release_context = &ReleaseContext;
        callbacks.ready = &Ready;
        return callbacks;
    }

    /// <summary>After a failed subscribe that never retained the context, free it here.</summary>
    public void AbandonUnretained()
    {
        lock (gate)
        {
            if (nativeReferences == 0 && self.IsAllocated) self.Free();
        }
    }

    public void Invalidate()
    {
        lock (gate) active = false;
    }

    public void Signal(ulong subscription, ulong currentGeneration)
    {
        lock (gate)
        {
            if (!active) return;
            generation = currentGeneration;
            if (queued) return;
            queued = true;
        }
        // The queued work owns its own subscription reference, distinct from the
        // session's and from the callback context (as the Swift delivery does).
        NativeHandle? owner = null;
        try { owner = NativeHandle.Retain(subscription); }
        catch (NativeError) { }
        if (!dispatcher.TryEnqueue(() => Deliver(owner)))
        {
            owner?.Dispose();
            lock (gate) queued = false;
        }
    }

    private void Deliver(NativeHandle? subscription)
    {
        try
        {
            ulong current;
            bool live;
            lock (gate) { queued = false; current = generation; live = active; }
            if (!live || subscription is null) return;
            unsafe
            {
                if (NativeMethods.tidyvnc_subscription_validate(subscription.Raw, current, null) != Tidyvnc.TIDYVNC_OK) return;
            }
            action(subscription.Raw, current);
        }
        finally
        {
            subscription?.Dispose();
            FinishWaiters();
        }
    }

    private void FinishWaiters()
    {
        List<TaskCompletionSource>? pending;
        lock (gate) { pending = waiters; waiters = null; }
        if (pending is null) return;
        foreach (var waiter in pending) waiter.TrySetResult();
    }

    /// <summary>Invalidate first; then await any delivery already queued to the UI thread.</summary>
    public Task DrainAsync()
    {
        lock (gate)
        {
            if (!queued) return Task.CompletedTask;
            var waiter = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            (waiters ??= []).Add(waiter);
            return waiter.Task;
        }
    }

    private static NativeDelivery? From(void* context)
        => context == null ? null : GCHandle.FromIntPtr((IntPtr)context).Target as NativeDelivery;

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void RetainContext(void* context)
    {
        var delivery = From(context);
        if (delivery is null) return;
        lock (delivery.gate) delivery.nativeReferences++;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void ReleaseContext(void* context)
    {
        var delivery = From(context);
        if (delivery is null) return;
        lock (delivery.gate)
        {
            if (--delivery.nativeReferences <= 0 && delivery.self.IsAllocated) delivery.self.Free();
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void Ready(void* context, ulong subscription, ulong generation)
    {
        try { From(context)?.Signal(subscription, generation); }
        catch { /* Never throw into the C dispatcher. */ }
    }
}

internal enum NativeDrain { Session, Subscription, Runtime, Listener }

internal static class NativeDrainer
{
    /// <summary>
    /// Control-plane drain polling only (never frame/state polling). Awaiting
    /// keeps the UI thread responsive; the task is not cancelled by callers.
    /// </summary>
    public static async Task WaitAsync(NativeHandle handle, NativeDrain kind)
    {
        while (true)
        {
            var status = Poll(handle, kind);
            if (status == NativeStatus.Ok) return;
            await Task.Delay(2).ConfigureAwait(true);
        }
    }

    private static unsafe NativeStatus Poll(NativeHandle handle, NativeDrain kind)
    {
        var error = Abi.Init<tidyvnc_error>();
        var code = kind switch
        {
            NativeDrain.Session => NativeMethods.tidyvnc_session_poll_drained(handle.Raw, &error),
            NativeDrain.Subscription => NativeMethods.tidyvnc_subscription_poll_drained(handle.Raw, &error),
            NativeDrain.Runtime => NativeMethods.tidyvnc_runtime_poll_drained(handle.Raw, &error),
            _ => NativeMethods.tidyvnc_listener_poll_drained(handle.Raw, &error),
        };
        return Abi.Check(code, &error, NativeStatus.Ok, NativeStatus.Pending);
    }
}
