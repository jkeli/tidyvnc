// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;

namespace TidyVNC.Native;

public enum NativeConnectionDraftError { Unavailable, Changed, ConnectionChanged }

/// <summary>
/// Shared access and Retry for a window's next connection (macOS
/// NativeConnectionDraft; PARITY D09-D10). Editable while disconnected;
/// null inherits the window's initial setting. UI thread only.
/// </summary>
public sealed partial class NativeConnectionDraft : ObservableObject
{
    private readonly NativeSession session;
    private bool stopped;

    [ObservableProperty] public partial bool? Shared { get; set; }
    [ObservableProperty] public partial bool? ReconnectOnError { get; set; }
    [ObservableProperty] public partial NativeConnectionOptions? Baseline { get; private set; }
    [ObservableProperty] public partial NativeConnectionDraftError? Error { get; private set; }
    [ObservableProperty] public partial bool NeedsReload { get; private set; }
    [ObservableProperty] public partial bool DidApply { get; private set; }
    public bool InitialShared { get; }
    public bool InitialReconnectOnError { get; }

    public NativeConnectionDraft(NativeSession session)
    {
        this.session = session;
        InitialShared = session.InitialShared; InitialReconnectOnError = session.InitialReconnectOnError;
        session.PropertyChanged += SessionChanged;
        PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(Shared) or nameof(ReconnectOnError)) Notify();
        };
    }

    private void SessionChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(NativeSession.IsClosing) && session.IsClosing) { Stop(); return; }
        if (e.PropertyName != nameof(NativeSession.Snapshot) || Baseline is not { } baseline || stopped) return;
        if (baseline.Generation != session.Snapshot.Generation || !Disconnected)
        {
            NeedsReload = true; DidApply = false; Error = NativeConnectionDraftError.ConnectionChanged;
            Notify();
        }
    }

    private bool Disconnected => session.Snapshot.State is NativeSessionState.Idle or NativeSessionState.Closed or NativeSessionState.Failed;
    public bool HasChanges => Baseline is { } baseline &&
        (baseline.Shared != (Shared ?? InitialShared) || baseline.ReconnectOnError != (ReconnectOnError ?? InitialReconnectOnError));
    public bool CanReload => !stopped && !session.IsClosing && Disconnected;
    public bool CanApply => CanReload && !NeedsReload && HasChanges;

    private void Notify()
    {
        OnPropertyChanged(nameof(HasChanges)); OnPropertyChanged(nameof(CanReload)); OnPropertyChanged(nameof(CanApply));
    }

    public void Reload()
    {
        if (!CanReload) return;
        try
        {
            var value = session.ConnectionOptions();
            if (!value.Editable) throw new NativeError(NativeStatus.Busy, "Connection still active");
            Baseline = value;
            Shared = value.Shared == InitialShared ? null : value.Shared;
            ReconnectOnError = value.ReconnectOnError == InitialReconnectOnError ? null : value.ReconnectOnError;
            NeedsReload = false; Error = null; DidApply = false;
        }
        catch (NativeError) { Error = NativeConnectionDraftError.Unavailable; NeedsReload = true; }
        Notify();
    }

    public void Apply()
    {
        if (!CanApply || Baseline is not { } baseline) return;
        try
        {
            session.SetConnectionOptions(Shared ?? InitialShared, ReconnectOnError ?? InitialReconnectOnError, baseline);
            Baseline = session.ConnectionOptions();
            DidApply = true; Error = null;
        }
        catch (NativeError) { NeedsReload = true; Error = NativeConnectionDraftError.Changed; }
        Notify();
    }

    public void Stop()
    {
        if (stopped) return;
        stopped = true;
        session.PropertyChanged -= SessionChanged;
        Notify();
    }
}

/// <summary>
/// A window's remote resize policy (macOS NativeRemoteResizePolicyDraft;
/// PARITY D05-D08): automatic resizing and the initial size for the next
/// connection, applied against the policy revision it was opened at.
/// </summary>
public sealed partial class NativeRemoteResizePolicyDraft : ObservableObject
{
    private readonly NativeSession session;
    private readonly Guid revision;
    private readonly NativeRemoteResizePolicy baseline;
    private bool stopped;

    [ObservableProperty] public partial bool Enabled { get; set; }
    [ObservableProperty] public partial string InitialSize { get; set; }
    /// <summary>Set when the policy changed elsewhere; the dialog must be reopened.</summary>
    [ObservableProperty] public partial bool Changed { get; private set; }
    public IReadOnlyDictionary<NativeResizeOption, NativeOptionSource> Sources { get; }

    public NativeRemoteResizePolicyDraft(NativeSession session)
    {
        this.session = session;
        Sources = new Dictionary<NativeResizeOption, NativeOptionSource>(session.ResizeSources);
        baseline = session.ResizePolicy; revision = session.ResizePolicyRevision;
        Enabled = baseline.Enabled; InitialSize = baseline.InitialSize;
        session.PropertyChanged += SessionChanged;
        PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(Enabled) or nameof(InitialSize))
            {
                OnPropertyChanged(nameof(CanApply)); OnPropertyChanged(nameof(IsValid));
            }
        };
    }

    private void SessionChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(NativeSession.ResizePolicy) && session.ResizePolicyRevision != revision) Changed = true;
        if (e.PropertyName == nameof(NativeSession.IsClosing) && session.IsClosing) Cancel();
        OnPropertyChanged(nameof(CanApply));
    }

    public bool IsValid => NativeRemoteResizePolicy.IsValid(Enabled, InitialSize);

    public NativeOptionSource Source(NativeResizeOption option)
    {
        if (option == NativeResizeOption.Enabled && Enabled != baseline.Enabled) return NativeOptionSource.Session;
        if (option == NativeResizeOption.InitialSize && (!IsValid || new NativeRemoteResizePolicy(true, InitialSize).InitialSize != baseline.InitialSize))
            return NativeOptionSource.Session;
        return Sources.GetValueOrDefault(option, NativeOptionSource.Compiled);
    }

    public bool CanApply => !stopped && !session.IsClosing && session.ResizePolicyRevision == revision && IsValid &&
                            new NativeRemoteResizePolicy(Enabled, InitialSize) != baseline;

    public void RestoreInitial()
    {
        if (stopped) return;
        Enabled = session.InitialResizePolicy.Enabled;
        InitialSize = session.InitialResizePolicy.InitialSize;
    }

    public bool Apply()
    {
        if (!CanApply) return false;
        try
        {
            session.SetResizePolicy(new NativeRemoteResizePolicy(Enabled, InitialSize), revision);
            Cancel();
            return true;
        }
        catch (NativeError) { Changed = true; return false; }
    }

    public void Cancel()
    {
        if (stopped) return;
        stopped = true;
        session.PropertyChanged -= SessionChanged;
        OnPropertyChanged(nameof(CanApply));
    }
}
