// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

public sealed class NativeListenOptions
{
    public string Address { get; set; } = "";
    public uint Port { get; set; } = 5500;
    public bool Ipv4 { get; set; } = true;
    public bool Ipv6 { get; set; } = true;
    public uint Backlog { get; set; } = 16;
    public uint PendingCapacity { get; set; } = 8;
    public uint EventCapacity { get; set; } = 32;
    public uint PendingTimeoutMilliseconds { get; set; } = 30_000;
}

public readonly record struct NativeListenerAddress(string Host, uint Port)
{
    internal static unsafe NativeListenerAddress From(tidyvnc_listener_address value)
        => new(NativeText.Fixed(value.host, 64), value.port);

    /// <summary>True for addresses reachable only from this computer (no firewall prompt).</summary>
    public bool IsLoopback => Host is "127.0.0.1" or "::1" || Host.StartsWith("127.", StringComparison.Ordinal);
}

public sealed record NativeIncomingPeer(ulong Id, NativeListenerAddress Address)
{
    internal ulong Listener { get; init; }
}

public enum NativeListenerState : uint { Starting, Listening, Stopping, Closed, Failed }
public enum NativeListenerFailure : uint { None, Cancelled, Bind, Accept, InvalidAddress, Unsupported, EventOverflow, InternalFailure }

public sealed record NativeListenerSnapshot(NativeListenerState State, NativeListenerFailure Failure, int NativeError, uint Pending,
                                            IReadOnlyList<NativeListenerAddress> Addresses)
{
    internal static NativeListenerSnapshot From(tidyvnc_listener_snapshot value)
    {
        var addresses = new List<NativeListenerAddress>();
        for (var i = 0; i < Math.Min(value.address_count, 2u); i++) addresses.Add(NativeListenerAddress.From(value.addresses[i]));
        return new(Enum.IsDefined((NativeListenerState)value.state) ? (NativeListenerState)value.state : NativeListenerState.Failed,
                   Enum.IsDefined((NativeListenerFailure)value.error) ? (NativeListenerFailure)value.error : NativeListenerFailure.InternalFailure,
                   value.native_error, value.pending, addresses);
    }

    public bool Equals(NativeListenerSnapshot? other)
        => other is not null && State == other.State && Failure == other.Failure && NativeError == other.NativeError &&
           Pending == other.Pending && Addresses.SequenceEqual(other.Addresses);

    public override int GetHashCode() => HashCode.Combine(State, Failure, NativeError, Pending, Addresses.Count);
}

/// <summary>
/// Reverse-connection listener (NativeListener.swift). One owner of its event
/// stream; readiness is coalesced like sessions, with no state polling.
/// </summary>
public sealed partial class NativeListener : ObservableObject
{
    private readonly NativeRuntime runtime;
    private readonly NativeHandle handle;
    private readonly NativeHandle? subscription;
    private readonly NativeDelivery? delivery;
    private Task? closeTask;

    [ObservableProperty] public partial NativeListenerSnapshot Snapshot { get; private set; }
    [ObservableProperty] public partial NativeError? DeliveryError { get; private set; }
    public ObservableCollection<NativeIncomingPeer> Incoming { get; } = [];
    public bool IsClosing { get; private set; }

    internal unsafe NativeListener(NativeRuntime runtime, NativeListenOptions options)
    {
        this.runtime = runtime;
        var config = Abi.Init<tidyvnc_listener_options>();
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_listener_options_init(&config, &error), &error);
        config.port = options.Port; config.ipv4 = options.Ipv4 ? 1u : 0u; config.ipv6 = options.Ipv6 ? 1u : 0u;
        config.backlog = options.Backlog; config.pending_capacity = options.PendingCapacity;
        config.event_capacity = options.EventCapacity; config.pending_timeout_ms = options.PendingTimeoutMilliseconds;
        var address = NativeText.Utf8(options.Address);
        ulong raw = 0;
        fixed (byte* p = address)
        {
            config.address = NativeText.Span(p, address.Length);
            Abi.Check(NativeMethods.tidyvnc_listener_create(runtime.Handle.Raw, &config, &raw, &error), &error);
        }
        handle = NativeHandle.Adopt(raw);
        var initial = Abi.Init<tidyvnc_listener_snapshot>();
        Abi.Check(NativeMethods.tidyvnc_listener_get_snapshot(raw, &initial, &error), &error);
        Snapshot = NativeListenerSnapshot.From(initial);
        var weak = new WeakReference<NativeListener>(this);
        delivery = new NativeDelivery(runtime.Dispatcher, (_, _) => { if (weak.TryGetTarget(out var listener)) listener.Receive(); });
        var callbacks = delivery.Callbacks();
        ulong subscribed = 0;
        if (NativeMethods.tidyvnc_listener_subscribe(handle.Raw, &callbacks, &subscribed, &error) != Tidyvnc.TIDYVNC_OK)
        {
            delivery.AbandonUnretained();
            _ = NativeMethods.tidyvnc_listener_stop(handle.Raw, null);
            handle.Dispose();
            throw new NativeError(error);
        }
        subscription = NativeHandle.Adopt(subscribed);
        // Consume queued history first, so the first queued Starting event
        // cannot follow an already-Listening snapshot.
        Receive();
    }

    private unsafe void Receive()
    {
        if (IsClosing) return;
        try
        {
            var value = Abi.Init<tidyvnc_listener_event>();
            var error = Abi.Init<tidyvnc_error>();
            while (Abi.Check(NativeMethods.tidyvnc_listener_take_event(handle.Raw, &value, &error), &error, NativeStatus.Ok, NativeStatus.NoChange) == NativeStatus.Ok)
            {
                Snapshot = NativeListenerSnapshot.From(value.snapshot);
                if (value.kind == Tidyvnc.TIDYVNC_LISTENER_INCOMING)
                    Incoming.Add(new NativeIncomingPeer(value.incoming_id, NativeListenerAddress.From(value.peer)) { Listener = handle.Raw });
                else if (value.incoming_id != 0)
                    Remove(value.incoming_id);
                if (Snapshot.State is NativeListenerState.Stopping or NativeListenerState.Closed or NativeListenerState.Failed) Incoming.Clear();
            }
        }
        catch (NativeError problem) { DeliveryError = problem; }
    }

    private void Remove(ulong id)
    {
        for (var i = Incoming.Count - 1; i >= 0; i--) if (Incoming[i].Id == id) Incoming.RemoveAt(i);
    }

    private void Validate(NativeIncomingPeer peer)
    {
        UiThread.Require(runtime.Dispatcher);
        if (IsClosing) throw new NativeError(NativeStatus.Closing, "Listener is closing");
        if (peer.Listener != handle.Raw || !Incoming.Contains(peer))
            throw new NativeError(NativeStatus.Stale, "Incoming connection is no longer available");
    }

    public unsafe void Reject(NativeIncomingPeer peer)
    {
        Validate(peer);
        try
        {
            var error = Abi.Init<tidyvnc_error>();
            Abi.Check(NativeMethods.tidyvnc_listener_reject(handle.Raw, peer.Id, &error), &error);
        }
        finally { Receive(); }
    }

    public Task<NativeCompletion> AcceptAsync(NativeIncomingPeer peer, NativeSession session)
    {
        Validate(peer);
        return session.AcceptIncomingAsync(handle, peer.Id);
    }

    /// <summary>Stops listening; terminal events still arrive and accepted sessions stay open.</summary>
    public unsafe void Stop()
    {
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_listener_stop(handle.Raw, &error), &error);
    }

    internal Task BeginClose()
    {
        if (closeTask is not null) return closeTask;
        IsClosing = true;
        Incoming.Clear();
        delivery?.Invalidate();
        unsafe
        {
            if (subscription is not null) _ = NativeMethods.tidyvnc_subscription_unsubscribe(subscription.Raw, null);
            _ = NativeMethods.tidyvnc_listener_stop(handle.Raw, null);
        }
        closeTask = Close();
        return closeTask;
    }

    private async Task Close()
    {
        Exception? failure = null;
        try { await NativeDrainer.WaitAsync(handle, NativeDrain.Listener).ConfigureAwait(true); } catch (Exception e) { failure = e; }
        if (subscription is not null)
        {
            try { await NativeDrainer.WaitAsync(subscription, NativeDrain.Subscription).ConfigureAwait(true); }
            catch (Exception e) { failure ??= e; }
        }
        if (delivery is not null) await delivery.DrainAsync().ConfigureAwait(true);
        if (failure is not null) throw failure;
    }

    public Task CloseAsync()
    {
        UiThread.Require(runtime.Dispatcher);
        return BeginClose();
    }

    ~NativeListener()
    {
        delivery?.Invalidate();
        unsafe
        {
            if (subscription is { IsClosed: false }) _ = NativeMethods.tidyvnc_subscription_unsubscribe(subscription.Raw, null);
            if (!handle.IsClosed) _ = NativeMethods.tidyvnc_listener_stop(handle.Raw, null);
        }
    }
}
