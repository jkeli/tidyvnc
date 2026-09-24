// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Immutable;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;

namespace TidyVNC.Native;

public enum NativeListenerPhase { Idle, Starting, Listening, Stopping, Stopped, Failed }

public enum NativeListenerIssue { InvalidPort, NoFamily, Bind, Overflow, Stopped, Delivery, StartFailed, Unavailable, OpenFailed }

/// <summary>
/// The Listen for connections window's model (macOS ListenerModel; PARITY
/// L07, L08, W12): a port and address families, start and stop, and the
/// incoming connections to accept into a new connection window or reject. A
/// failed or stopped listener finishes closing before its port is bound
/// again. UI thread only.
/// </summary>
public sealed partial class NativeListenerModel : ObservableObject
{
    private readonly NativeRuntime runtime;
    private readonly Func<NativeReverseRequest, bool> open;
    private readonly bool alertOnFatalError;
    private NativeListener? listener;
    private Task? cleanup;
    private ulong epoch;
    private bool launchPending, closing;

    [ObservableProperty] public partial string Port { get; set; } = "5500";
    [ObservableProperty] public partial bool Ipv4 { get; set; } = true;
    [ObservableProperty] public partial bool Ipv6 { get; set; } = true;
    [ObservableProperty] public partial NativeListenerPhase Phase { get; private set; }
    [ObservableProperty] public partial ImmutableArray<NativeIncomingPeer> Incoming { get; private set; } = [];
    [ObservableProperty] public partial ImmutableArray<NativeListenerAddress> Addresses { get; private set; } = [];
    [ObservableProperty] public partial ImmutableHashSet<ulong> Reserved { get; private set; } = [];
    [ObservableProperty] public partial NativeListenerIssue? Issue { get; private set; }
    /// <summary>With AlertOnFatalError off, a failure closes the window silently (the retained -listen behaviour).</summary>
    [ObservableProperty] public partial bool ClosesAfterFailure { get; private set; }

    /// <param name="open">Opens a connection window for an accepted peer; false when it could not.</param>
    /// <param name="launch">A -listen launch: its port and families, started when the window first appears.</param>
    public NativeListenerModel(NativeRuntime runtime, Func<NativeReverseRequest, bool> open, NativeListenOptions? launch = null, bool alertOnFatalError = true)
    {
        this.runtime = runtime; this.open = open; this.alertOnFatalError = alertOnFatalError;
        if (launch is not null)
        {
            Port = launch.Port.ToString(CultureInfo.InvariantCulture); Ipv4 = launch.Ipv4; Ipv6 = launch.Ipv6;
            launchPending = true;
        }
        PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(Phase)) { OnPropertyChanged(nameof(CanStart)); OnPropertyChanged(nameof(CanStop)); }
            if (e.PropertyName is nameof(Issue) && Issue is not null && Phase == NativeListenerPhase.Failed && !alertOnFatalError && !closing)
            {
                RequestClose();
                ClosesAfterFailure = true;
            }
        };
    }

    public bool CanStart => !closing && cleanup is null && Phase is NativeListenerPhase.Idle or NativeListenerPhase.Stopped or NativeListenerPhase.Failed;
    public bool CanStop => !closing && Phase is NativeListenerPhase.Starting or NativeListenerPhase.Listening;
    public bool IsClosing => closing;

    /// <summary>Only the first appearance starts on behalf of the command line; Stop and close revoke it.</summary>
    public void StartLaunchIfNeeded()
    {
        if (!launchPending || closing) return;
        launchPending = false;
        Start();
    }

    /// <summary>
    /// A -listen launch (macOS NativeInvocationBootstrap): the port is the
    /// operand (5500 without one) and the families follow UseIPv4/UseIPv6.
    /// Null when the invocation does not listen; Invalid when its port or
    /// families cannot be used. A file operand is a listener file to review.
    /// </summary>
    public static (NativeListenOptions? Options, string? Document, bool Invalid) Launch(NativeInvocation invocation, string? workingDirectory)
    {
        if (invocation.Value("listen") != "on") return (null, null, false);
        var options = new NativeListenOptions { Ipv4 = invocation.Value("UseIPv4") != "off", Ipv6 = invocation.Value("UseIPv6") != "off" };
        if (!options.Ipv4 && !options.Ipv6) return (null, null, true);
        if (invocation.Operand is { Length: > 0 } operand)
        {
            if (operand.Contains('\\', StringComparison.Ordinal) || operand.Contains('/', StringComparison.Ordinal))
                return (options, workingDirectory is null ? operand : Path.GetFullPath(operand, workingDirectory), false);
            if (ParsePort(operand) is not { } port) return (null, null, true);
            options.Port = port;
        }
        return (options, null, false);
    }

    /// <summary>A TCP port from 0 to 65535, decimal; 0 chooses an available port.</summary>
    public static uint? ParsePort(string text)
    {
        var value = text.Trim();
        return value.Length is > 0 and <= 5 && value.All(char.IsAsciiDigit) &&
               uint.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var port) && port <= 65535 ? port : null;
    }

    public void Start()
    {
        if (!CanStart) return;
        if (ParsePort(Port) is not { } port) { Issue = NativeListenerIssue.InvalidPort; return; }
        if (!Ipv4 && !Ipv6) { Issue = NativeListenerIssue.NoFamily; return; }
        var options = new NativeListenOptions { Port = port, Ipv4 = Ipv4, Ipv6 = Ipv6 };
        Issue = null; Phase = NativeListenerPhase.Starting; Addresses = []; Incoming = []; Reserved = [];
        // A failed or stopped predecessor finishes closing before its port is bound again.
        var previous = Detach();
        var ticket = ++epoch;
        cleanup = Bind();
        OnPropertyChanged(nameof(CanStart));

        async Task Bind()
        {
            if (previous is not null) { try { await previous.CloseAsync(); } catch (NativeError) { } }
            if (epoch != ticket || closing) return;
            cleanup = null;
            try
            {
                var owner = runtime.CreateListener(options);
                listener = owner;
                owner.PropertyChanged += ListenerChanged;
                owner.Incoming.CollectionChanged += IncomingChanged;
                Observe(owner);
            }
            catch (NativeError)
            {
                Phase = NativeListenerPhase.Failed; Issue = NativeListenerIssue.StartFailed;
            }
            OnPropertyChanged(nameof(CanStart));
        }
    }

    private NativeListener? Detach()
    {
        var owner = listener;
        if (owner is not null)
        {
            owner.PropertyChanged -= ListenerChanged;
            owner.Incoming.CollectionChanged -= IncomingChanged;
        }
        listener = null;
        return owner;
    }

    private void ListenerChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (sender is not NativeListener owner || !ReferenceEquals(owner, listener) || closing) return;
        if (e.PropertyName == nameof(NativeListener.DeliveryError) && owner.DeliveryError is not null)
        {
            if (!alertOnFatalError) Phase = NativeListenerPhase.Failed;
            Issue = NativeListenerIssue.Delivery;
            return;
        }
        Observe(owner);
    }

    private void IncomingChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (listener is not { } owner || closing) return;
        Incoming = [.. owner.Incoming];
        Reserved = Reserved.Intersect(Incoming.Select(p => p.Id));
    }

    private void Observe(NativeListener owner)
    {
        var value = owner.Snapshot;
        Addresses = [.. value.Addresses];
        switch (value.State)
        {
            case NativeListenerState.Starting: Phase = NativeListenerPhase.Starting; break;
            case NativeListenerState.Listening: Phase = NativeListenerPhase.Listening; break;
            case NativeListenerState.Stopping: Phase = NativeListenerPhase.Stopping; break;
            case NativeListenerState.Closed: Phase = NativeListenerPhase.Stopped; break;
            case NativeListenerState.Failed:
                // The phase first: a failure issue closes a silent listener only once it has failed.
                Phase = NativeListenerPhase.Failed;
                Issue = value.Failure switch
                {
                    NativeListenerFailure.Bind => NativeListenerIssue.Bind,
                    NativeListenerFailure.EventOverflow => NativeListenerIssue.Overflow,
                    _ => NativeListenerIssue.Stopped,
                };
                break;
        }
        Incoming = [.. owner.Incoming];
    }

    public bool CanAccept(NativeIncomingPeer peer) => !closing && Phase == NativeListenerPhase.Listening && Incoming.Contains(peer) && !Reserved.Contains(peer.Id);

    /// <summary>Opens a connection window for the peer; the peer is reserved until that window takes it.</summary>
    public void Accept(NativeIncomingPeer peer)
    {
        if (!CanAccept(peer) || listener is not { } owner) return;
        Issue = null;
        Reserved = Reserved.Add(peer.Id);
        if (!open(new NativeReverseRequest(owner, peer)))
        {
            Reserved = Reserved.Remove(peer.Id);
            Issue = NativeListenerIssue.OpenFailed;
        }
    }

    public void Reject(NativeIncomingPeer peer)
    {
        if (!CanAccept(peer) || listener is not { } owner) return;
        try { owner.Reject(peer); }
        catch (NativeError) { Issue = NativeListenerIssue.Unavailable; }
    }

    public void Stop()
    {
        launchPending = false;
        if (!CanStop) return;
        Phase = NativeListenerPhase.Stopping; Incoming = []; Reserved = [];
        var ticket = ++epoch;
        var prior = cleanup;
        var owner = Detach();
        cleanup = Drain();
        OnPropertyChanged(nameof(CanStart));

        async Task Drain()
        {
            if (prior is not null) await prior;
            if (owner is not null) { try { await owner.CloseAsync(); } catch (NativeError) { } }
            if (epoch != ticket) return;
            Incoming = []; Reserved = []; Phase = NativeListenerPhase.Stopped; cleanup = null;
            OnPropertyChanged(nameof(CanStart));
        }
    }

    /// <summary>Closing the window stops listening; pending peers are refused by the listener's close.</summary>
    public void RequestClose()
    {
        if (closing) return;
        launchPending = false;
        if (CanStop) Stop();
        closing = true;
        epoch++;
        var prior = cleanup;
        var owner = Detach();
        Incoming = []; Reserved = [];
        cleanup = Drain();
        OnPropertyChanged(nameof(CanStart)); OnPropertyChanged(nameof(CanStop));

        async Task Drain()
        {
            if (prior is not null) await prior;
            if (owner is not null) { try { await owner.CloseAsync(); } catch (NativeError) { } }
        }
    }

    public async Task CloseAsync()
    {
        RequestClose();
        if (cleanup is { } running) await running;
    }
}
