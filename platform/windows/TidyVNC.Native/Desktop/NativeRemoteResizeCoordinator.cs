// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;
using TidyVNC.Native.Platform;

namespace TidyVNC.Native.Desktop;

/// <summary>A desktop view's size for automatic resizing: effective pixels, its scale and the scaling it shows.</summary>
public readonly record struct NativeResizeViewport(double Width, double Height, double Scale, bool Unscaled, bool DevicePixels, bool Available);

/// <summary>
/// Automatic remote resize for one connection (macOS
/// NativeRemoteResizeCoordinator; REMOTE-RESIZE.md, PARITY D06-D07). One
/// geometry source is authoritative: the window's desktop view, or, while
/// full screen spans displays, the canvas of its surfaces (window updates are
/// remembered but not used meanwhile). Requests wait 100 ms for the geometry
/// to settle, one runs at a time, and a size is never requested twice for
/// the same geometry. The initial size is requested once per connection
/// when resizing is enabled; after a manual request, automatic resizing
/// waits for the geometry to change. UI thread only.
/// </summary>
public sealed partial class NativeRemoteResizeCoordinator : ObservableObject, IDisposable
{
    private abstract record Geometry(bool Available);
    private sealed record WindowGeometry(NativeResizeViewport Viewport) : Geometry(Viewport.Available);
    private sealed record CanvasGeometry(NativeDisplayLayout Layout, bool Unscaled, bool IsAvailable) : Geometry(IsAvailable);
    private sealed record Target(uint Width, uint Height, ulong Generation, Guid Revision, bool Initial, Guid Owner, NativeDisplayLayout? Canvas);

    private NativeSession? session;
    private Guid? owner, canvasOwner;
    private NativeResizeViewport? viewport;
    private CanvasGeometry? canvasGeometry;
    private CancellationTokenSource? delay;
    private Task? operation;
    private bool wakeQueued, stopped, initialAttempted;
    private ulong generation;
    private NativeRemoteResizePolicy initialPolicy = NativeRemoteResizePolicy.BuiltIn;
    private Geometry? initialViewport, manualViewport;
    private Target? lastAttempt;

    /// <summary>Why the last automatic resize did not happen, or null.</summary>
    [ObservableProperty] public partial NativeText? Message { get; private set; }

    /// <summary>How long the geometry must stay unchanged before a request (tests shorten it).</summary>
    public TimeSpan Settle { get; init; } = TimeSpan.FromMilliseconds(100);

    private Geometry? Current => canvasOwner is null ? viewport is { } value ? new WindowGeometry(value) : null : canvasGeometry;
    private Guid? GeometryOwner => canvasOwner ?? owner;

    public void Bind(NativeSession value)
    {
        if (stopped || ReferenceEquals(session, value)) return;
        Unbind();
        session = value;
        generation = 0;
        value.PropertyChanged += SessionChanged;
        value.ManualResizeRequested += ManualRequest;
        Schedule();
    }

    private void Unbind()
    {
        if (session is null) return;
        session.PropertyChanged -= SessionChanged;
        session.ManualResizeRequested -= ManualRequest;
        session = null;
    }

    private void SessionChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(NativeSession.IsClosing) when session?.IsClosing == true:
                Stop();
                return;
            case nameof(NativeSession.ResizePolicy) when session?.ResizePolicy.Enabled == false:
                CancelDelay();
                Schedule();
                return;
            case nameof(NativeSession.Snapshot) or nameof(NativeSession.IsViewOnly) or nameof(NativeSession.ResizePolicy):
                Schedule();
                return;
        }
    }

    /// <summary>A manual request: keep that size until the geometry changes.</summary>
    private void ManualRequest()
    {
        manualViewport = Current;
        lastAttempt = null;
        CancelDelay();
    }

    /// <summary>The window's desktop view reports its size; the first available view becomes the source.</summary>
    public void Update(Guid source, NativeResizeViewport value)
    {
        if (stopped) return;
        if (owner != source && !(owner is null && canvasOwner is null && value.Available)) return;
        if (owner == source && viewport == value) return;
        owner = source;
        viewport = value;
        Schedule();
    }

    public void Detach(Guid source)
    {
        if (owner != source) return;
        owner = null; viewport = null; lastAttempt = null;
        CancelDelay();
    }

    /// <summary>Full screen across displays takes the geometry over, even while not yet shown.</summary>
    public void BeginCanvas(Guid source)
    {
        if (stopped || canvasOwner == source) return;
        canvasOwner = source; canvasGeometry = null; lastAttempt = null;
        CancelDelay();
        Schedule();
    }

    public void UpdateCanvas(Guid source, NativeDisplayLayout layout, bool unscaled, bool available)
    {
        if (stopped || canvasOwner != source) return;
        var value = new CanvasGeometry(layout, unscaled, available);
        if (canvasGeometry == value) return;
        canvasGeometry = value;
        if (!available) CancelDelay();
        Schedule();
    }

    public void EndCanvas(Guid source)
    {
        if (canvasOwner != source) return;
        canvasOwner = null; canvasGeometry = null; lastAttempt = null;
        CancelDelay();
        Schedule();
    }

    private void CancelDelay()
    {
        delay?.Cancel();
        delay?.Dispose();
        delay = null;
    }

    private void Schedule()
    {
        if (stopped || wakeQueued) return;
        wakeQueued = true;
        _ = Wake();
    }

    private async Task Wake()
    {
        await Task.Yield();
        wakeQueued = false;
        if (!stopped) Reconcile();
    }

    private Target? Compute()
    {
        if (session is not { } s) return null;
        if (generation != s.Generation)
        {
            generation = s.Generation; initialPolicy = s.ResizePolicy;
            initialAttempted = false; initialViewport = null; manualViewport = null; lastAttempt = null; Message = null;
        }
        if (stopped || s.IsClosing || s.Snapshot is not { State: NativeSessionState.Connected, SupportsResize: true, ResizePending: false } ||
            s.IsViewOnly || !s.ResizePolicy.Enabled || Current is not { Available: true } geometry || GeometryOwner is not { } source) return null;
        if (manualViewport is not null)
        {
            if (geometry == manualViewport) return null;
            manualViewport = null; // A later return to that geometry is a new resize.
        }
        if (initialViewport is not null && geometry != initialViewport) initialViewport = null;
        if (!initialAttempted && initialPolicy is { InitialWidth: { } w, InitialHeight: { } h })
            return new Target(w, h, generation, s.ResizePolicyRevision, true, source, null);
        if (geometry == initialViewport) return null;
        if (geometry is CanvasGeometry canvas)
            return canvas.Unscaled ? new Target(canvas.Layout.Width, canvas.Layout.Height, generation, s.ResizePolicyRevision, false, source, canvas.Layout) : null;
        if (geometry is not WindowGeometry { Viewport: { Unscaled: true } view } || !double.IsFinite(view.Width) || !double.IsFinite(view.Height) ||
            !double.IsFinite(view.Scale) || view.Scale <= 0) return null;
        var scale = view.DevicePixels ? view.Scale : 1;
        double width = Math.Floor(view.Width * scale), height = Math.Floor(view.Height * scale);
        if (width is < 1 or > 65535 || height is < 1 or > 65535) return null;
        return new Target((uint)width, (uint)height, generation, s.ResizePolicyRevision, false, source, null);
    }

    private void Reconcile()
    {
        CancelDelay();
        if (operation is not null || Compute() is not { } target || target == lastAttempt) return;
        delay = new CancellationTokenSource();
        _ = Settled(target, delay.Token);
    }

    private async Task Settled(Target target, CancellationToken token)
    {
        try { await Task.Delay(Settle, token); }
        catch (OperationCanceledException) { return; }
        if (stopped || token.IsCancellationRequested || Compute() != target) return;
        CancelDelay();
        Send(target);
    }

    private void Send(Target target)
    {
        if (session is not { } s || operation is not null || Compute() != target) return;
        NativeRemoteLayout requested;
        try
        {
            var current = s.DesktopLayout();
            if (current.Layout.Screens.Count == 0) return;
            var first = current.Layout.Screens[0];
            requested = target.Canvas is { } canvas ? canvas.RemoteLayout(current.Layout)
                : new NativeRemoteLayout(target.Width, target.Height, [new NativeRemoteScreen(first.Id, 0, 0, target.Width, target.Height, first.Flags)]);
            lastAttempt = target;
            if (target.Initial) { initialAttempted = true; initialViewport = Current; }
            if (requested.Equals(current.Layout)) { Schedule(); return; }
        }
        catch (NativeError)
        {
            Message = new NativeText("desktop.resize.the.remote.desktop.layout.is.unavailable.for.automatic.resizing");
            return;
        }
        if (Current is WindowGeometry { Viewport: var measured })
            NativeProcessLogging.Viewport(measured.Width, measured.Height, measured.Scale);
        Message = null;
        operation = Run(s, requested, target);
    }

    private async Task Run(NativeSession s, NativeRemoteLayout requested, Target target)
    {
        try { await s.RequestAutomaticDesktopLayoutAsync(requested, target.Generation); }
        catch (Exception error) when (error is NativeError or NativeCommandFailure or OperationCanceledException)
        {
            if (!stopped && s.Generation == target.Generation && GeometryOwner == target.Owner)
            {
                if (error is NativeError { Status: NativeStatus.Busy })
                {
                    lastAttempt = null;
                    if (target.Initial) { initialAttempted = false; initialViewport = null; }
                }
                else if (error is not OperationCanceledException)
                    Message = new NativeText("desktop.resize.the.automatic.desktop.resize.did.not.complete.you.can.request.a.size");
            }
        }
        operation = null;
        Schedule();
    }

    public void Stop()
    {
        if (stopped) return;
        stopped = true;
        CancelDelay();
        Unbind();
        owner = null; viewport = null; canvasOwner = null; canvasGeometry = null;
    }

    public void Dispose() => Stop();

    /// <summary>Stops and waits for a request already sent (close ordering).</summary>
    public async Task CloseAsync()
    {
        Stop();
        if (operation is { } running) await running;
    }
}
