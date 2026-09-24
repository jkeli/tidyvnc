// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using TidyVNC.Native.Platform;

namespace TidyVNC.Native;

public enum NativeRemoteResizeSource { Custom, AllDisplays, SelectedDisplays }

public enum NativeRemoteResizeMessage
{
    Unavailable, LayoutChanged, RequestUnavailable, Applied, Rejected, TimedOut, TooLarge, Incomplete,
}

/// <summary>
/// Resize the remote desktop (macOS NativeRemoteResizeDraft; PARITY D01-D04):
/// a custom size or one remote screen per chosen local display, requested
/// against the layout it was read at; the server's reply completes it.
/// UI thread only.
/// </summary>
public sealed partial class NativeRemoteResizeDraft : ObservableObject, IDisposable
{
    private readonly NativeSession session;
    private readonly NativeDisplayService? displays;
    private ulong? reviewedDisplayGeneration;
    private CancellationTokenSource? requesting;
    private Task? operation;
    private bool stopped;

    [ObservableProperty] public partial NativeRemoteResizeSource Source { get; set; }
    [ObservableProperty] public partial IReadOnlySet<string> SelectedDisplays { get; set; } = new HashSet<string>();
    [ObservableProperty] public partial bool DevicePixels { get; set; }
    [ObservableProperty] public partial string Width { get; set; } = "";
    [ObservableProperty] public partial string Height { get; set; } = "";
    [ObservableProperty] public partial NativeRemoteDesktop? Baseline { get; private set; }
    [ObservableProperty] public partial bool IsBusy { get; private set; }
    [ObservableProperty] public partial bool NeedsReload { get; private set; }
    [ObservableProperty] public partial NativeRemoteResizeMessage? Message { get; private set; }
    /// <summary>The server's numeric result for a rejection.</summary>
    [ObservableProperty] public partial uint RejectionResult { get; private set; }
    [ObservableProperty] public partial bool DidApply { get; private set; }

    public NativeRemoteResizeDraft(NativeSession session, NativeDisplayService? displays = null)
    {
        this.session = session;
        this.displays = displays;
        if (displays is not null)
        {
            SelectedDisplays = displays.Snapshot.Displays.Select(d => d.Id).ToHashSet(StringComparer.Ordinal);
            displays.PropertyChanged += DisplaysChanged;
        }
        session.PropertyChanged += SessionChanged;
        PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(Source) or nameof(SelectedDisplays) or nameof(DevicePixels) or nameof(Width) or nameof(Height)) Notify();
        };
    }

    public NativeDisplaySnapshot? DisplaySnapshot => displays?.Snapshot;

    private void DisplaysChanged(object? sender, PropertyChangedEventArgs e)
    {
        OnPropertyChanged(nameof(DisplaySnapshot));
        Notify();
    }

    private void SessionChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(NativeSession.IsClosing) && session.IsClosing) { Stop(); return; }
        if (e.PropertyName == nameof(NativeSession.Snapshot) && Baseline is { } baseline &&
            (session.Snapshot.State != NativeSessionState.Connected || session.Snapshot.Generation != baseline.Snapshot.Generation))
        {
            NeedsReload = true; DidApply = false;
        }
        Notify();
    }

    private void Notify()
    {
        OnPropertyChanged(nameof(CanReload)); OnPropertyChanged(nameof(CanApply)); OnPropertyChanged(nameof(DisplayProblem));
        OnPropertyChanged(nameof(DisplayLayout)); OnPropertyChanged(nameof(NeedsDisplayReload));
    }

    public bool CanReload => !stopped && !IsBusy && session is { IsClosing: false, Snapshot.State: NativeSessionState.Connected };

    private (uint Width, uint Height)? Dimensions =>
        Width.Length != 0 && Height.Length != 0 && Width.All(char.IsAsciiDigit) && Height.All(char.IsAsciiDigit) &&
        uint.TryParse(Width, NumberStyles.None, CultureInfo.InvariantCulture, out var w) &&
        uint.TryParse(Height, NumberStyles.None, CultureInfo.InvariantCulture, out var h) && w is >= 1 and <= 65535 && h is >= 1 and <= 65535
            ? (w, h) : null;

    public bool NeedsDisplayReload => Source != NativeRemoteResizeSource.Custom && DisplaySnapshot?.Generation != reviewedDisplayGeneration;

    public IReadOnlyList<NativeDisplayInfo> ChosenDisplays => DisplaySnapshot is not { } snapshot ? []
        : Source == NativeRemoteResizeSource.AllDisplays ? snapshot.Displays : [.. snapshot.Displays.Where(d => SelectedDisplays.Contains(d.Id))];

    public IReadOnlyList<string> MissingDisplays => DisplaySnapshot is not { } snapshot || Source != NativeRemoteResizeSource.SelectedDisplays ? []
        : [.. SelectedDisplays.Where(id => snapshot.Find(id) is null).Order(StringComparer.Ordinal)];

    public NativeDisplayLayout? DisplayLayout
    {
        get
        {
            if (Source == NativeRemoteResizeSource.Custom || displays is null || DisplaySnapshot?.Error is not null || MissingDisplays.Count != 0) return null;
            try { return new NativeDisplayLayout(ChosenDisplays, DevicePixels); }
            catch (NativeError) { return null; }
        }
    }

    /// <summary>Why the chosen displays cannot be requested (macOS displayMessage).</summary>
    public NativeText? DisplayProblem
    {
        get
        {
            if (Source == NativeRemoteResizeSource.Custom) return null;
            if (NeedsDisplayReload) return new("settings.resize.local.displays.changed.reload.to.review.the.new.arrangement.before.resizing");
            if (displays is null || DisplaySnapshot?.Error is not null) return new("settings.resize.local.display.information.is.unavailable");
            if (MissingDisplays.Count != 0) return new("settings.resize.a.selected.display.is.disconnected.reconnect.it.or.remove.it.from.the");
            if (ChosenDisplays.Count == 0) return new("settings.fullscreen.select.at.least.one.display");
            if (DisplayLayout is null) return new("settings.resize.this.arrangement.cannot.be.mapped.displays.must.not.overlap.or.mirror.and");
            return null;
        }
    }

    private NativeRemoteLayout? ProposedLayout
    {
        get
        {
            if (Baseline is not { } baseline) return null;
            try
            {
                if (Source != NativeRemoteResizeSource.Custom) return DisplayLayout?.RemoteLayout(baseline.Layout);
                if (Dimensions is not { } size || baseline.Layout.Screens.Count == 0) return null;
                var first = baseline.Layout.Screens[0];
                return new NativeRemoteLayout(size.Width, size.Height, [new NativeRemoteScreen(first.Id, 0, 0, size.Width, size.Height, first.Flags)]);
            }
            catch (NativeError) { return null; }
        }
    }

    public bool CanApply
    {
        get
        {
            if (!CanReload || NeedsReload || NeedsDisplayReload || Baseline is not { } baseline || ProposedLayout is not { } proposed ||
                session.Generation != baseline.Snapshot.Generation || !session.Snapshot.SupportsResize || session.Snapshot.ResizePending || session.IsViewOnly)
                return false;
            return !proposed.Equals(baseline.Layout);
        }
    }

    public void Reload()
    {
        if (!CanReload) return;
        try
        {
            displays?.Refresh();
            reviewedDisplayGeneration = DisplaySnapshot?.Generation;
            var current = session.DesktopLayout();
            Baseline = current;
            Width = current.Layout.Width.ToString(CultureInfo.InvariantCulture);
            Height = current.Layout.Height.ToString(CultureInfo.InvariantCulture);
            NeedsReload = false; DidApply = false; Message = null;
        }
        catch (NativeError) { NeedsReload = true; Message = NativeRemoteResizeMessage.Unavailable; }
        Notify();
    }

    public void Apply()
    {
        // Read the OS again right before admission; notifications can lag.
        if (Source != NativeRemoteResizeSource.Custom) displays?.Refresh();
        if (!CanApply || Baseline is not { } baseline || ProposedLayout is not { } layout) return;
        try
        {
            if (!session.DesktopLayout().Layout.Equals(baseline.Layout))
            {
                NeedsReload = true; Message = NativeRemoteResizeMessage.LayoutChanged;
                Notify();
                return;
            }
        }
        catch (NativeError)
        {
            Message = NativeRemoteResizeMessage.RequestUnavailable;
            Notify();
            return;
        }
        IsBusy = true; Message = null; DidApply = false;
        requesting?.Dispose();
        requesting = new CancellationTokenSource();
        operation = Run(layout, baseline.Snapshot.Generation);
        Notify();
    }

    private async Task Run(NativeRemoteLayout layout, ulong generation)
    {
        try
        {
            await session.RequestDesktopLayoutAsync(layout, generation);
            if (!stopped)
            {
                if (session.Generation != generation) throw new NativeError(NativeStatus.Stale, "Connection changed");
                var current = session.DesktopLayout();
                Baseline = current;
                Width = current.Layout.Width.ToString(CultureInfo.InvariantCulture);
                Height = current.Layout.Height.ToString(CultureInfo.InvariantCulture);
                DidApply = true; NeedsReload = false;
                Message = NativeRemoteResizeMessage.Applied;
            }
        }
        catch (Exception error) when (error is NativeCommandFailure or NativeError or OperationCanceledException)
        {
            if (!stopped)
            {
                switch (error)
                {
                    case NativeCommandFailure { Reason: NativeCommandFailure.FailureReason.ServerRejected } rejected:
                        RejectionResult = rejected.NativeResult;
                        Message = NativeRemoteResizeMessage.Rejected;
                        break;
                    case NativeCommandFailure { Reason: NativeCommandFailure.FailureReason.TimedOut }:
                        Message = NativeRemoteResizeMessage.TimedOut;
                        break;
                    case NativeError { Status: NativeStatus.ResourceLimit }:
                        Message = NativeRemoteResizeMessage.TooLarge;
                        break;
                    default:
                        Message = NativeRemoteResizeMessage.Incomplete; NeedsReload = true;
                        break;
                }
            }
        }
        IsBusy = false; operation = null;
        Notify();
    }

    public void Stop()
    {
        if (stopped) return;
        stopped = true;
        session.PropertyChanged -= SessionChanged;
        if (displays is not null) displays.PropertyChanged -= DisplaysChanged;
        requesting?.Cancel();
        Notify();
    }

    /// <summary>A request already sent cannot be undone: close waits for its reply.</summary>
    public async Task CloseAsync()
    {
        Stop();
        if (operation is { } running) await running;
    }

    public void Dispose()
    {
        Stop();
        requesting?.Dispose();
    }
}
