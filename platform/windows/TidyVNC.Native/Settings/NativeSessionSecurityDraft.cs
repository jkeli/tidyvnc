// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;
using TidyVNC.Native.Trust;

namespace TidyVNC.Native;

/// <summary>
/// A security patch (macOS NativeSecurityPreferences): null inherits;
/// Types is a canonical method list ("" denies every method) and
/// TlsPriority a GnuTLS expression ("" is the library default).
/// </summary>
public sealed record NativeSecurityPatch(string? Types = null, string? TlsPriority = null)
{
    public const int MaximumPriorityBytes = 4096;

    /// <summary>The selection a Types value resolves to; null when it is invalid or unavailable.</summary>
    public NativeSecuritySelection? Selection(NativeSecuritySelection inherited)
    {
        if (Types is null) return inherited;
        try { return new NativeSecuritySelection(Types); }
        catch (NativeError) { return null; }
    }

    /// <summary>Cheap checks usable per keystroke (the GnuTLS preflight runs on Apply).</summary>
    public bool IsPriorityTextValid => TlsPriority is null ||
        (!TlsPriority.Contains('\0', StringComparison.Ordinal) && System.Text.Encoding.UTF8.GetByteCount(TlsPriority) <= MaximumPriorityBytes);
}

public enum NativeSecurityDraftError { Unavailable, InvalidPriority, InvalidValue, UnsupportedValue, Changed, ConnectionChanged, Cancelled }

/// <summary>
/// Security for the next connection of one window (NativeSessionSecurityDraft.swift):
/// editable only while disconnected, preflighted off the UI thread, then
/// applied against the revision it was read at. Never saved.
/// UI thread only.
/// </summary>
public sealed partial class NativeSessionSecurityDraft : ObservableObject, IDisposable
{
    private readonly NativeSession session;
    private readonly Action onApplied;
    private CancellationTokenSource? applying;
    private Task? operation;
    private bool stopped;

    [ObservableProperty] public partial NativeSecurityPatch Preferences { get; set; } = new();
    [ObservableProperty] public partial NativeTrustFiles TrustFiles { get; set; } = new();
    [ObservableProperty] public partial NativeSessionSecurity? Baseline { get; private set; }
    [ObservableProperty] public partial bool IsBusy { get; private set; }
    [ObservableProperty] public partial bool NeedsReload { get; private set; }
    [ObservableProperty] public partial NativeSecurityDraftError? Error { get; private set; }
    [ObservableProperty] public partial bool DidApply { get; private set; }

    public IReadOnlyList<NativeSecurityChoice> Choices { get; }
    /// <summary>This window's initial settings, which an absent override inherits.</summary>
    public NativeSecuritySelection Inherited { get; }
    public string InheritedPriority { get; }
    public NativeTrustFiles InheritedFiles { get; }

    public NativeSessionSecurityDraft(NativeSession session, Action? onApplied = null)
    {
        this.session = session;
        this.onApplied = onApplied ?? (() => { });
        Choices = NativeSecuritySelection.Choices();
        var names = session.InitialSecurityTypes.Select(type => Choices.FirstOrDefault(c => c.Id == type)?.Name
            ?? throw new NativeError(NativeStatus.Unsupported, "Unknown security method"));
        Inherited = new NativeSecuritySelection(string.Join(',', names));
        InheritedPriority = session.InitialTlsPriority;
        InheritedFiles = new NativeTrustFiles(session.InitialCaFile, session.InitialCrlFile);
        session.PropertyChanged += SessionChanged;
    }

    private void SessionChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(NativeSession.IsClosing) && session.IsClosing) { Stop(); return; }
        if (e.PropertyName != nameof(NativeSession.Snapshot) || Baseline is not { } baseline || stopped) return;
        var snapshot = session.Snapshot;
        if (snapshot.Generation != baseline.Generation || snapshot.State is not (NativeSessionState.Idle or NativeSessionState.Closed or NativeSessionState.Failed))
        {
            NeedsReload = true; DidApply = false; Error = NativeSecurityDraftError.ConnectionChanged;
        }
        Notify();
    }

    partial void OnPreferencesChanged(NativeSecurityPatch value) => Notify();
    partial void OnTrustFilesChanged(NativeTrustFiles value) => Notify();

    /// <summary>Where the initial settings came from; "connection override" once this window applied one.</summary>
    public (NativeOptionSource Methods, NativeOptionSource Priority)? Sources => Baseline is null ? null
        : Baseline.Revision > 1 ? (NativeOptionSource.Session, NativeOptionSource.Session) : (session.InitialSecuritySource, session.InitialTlsPrioritySource);

    private (string Types, string Priority) Resolved
    {
        get
        {
            var types = Preferences.Types ?? Inherited.Canonical;
            try { types = new NativeSecuritySelection(types).Canonical; } catch (NativeError) { }
            return (types, Preferences.TlsPriority ?? InheritedPriority);
        }
    }

    private NativeTrustFiles ResolvedFiles => new(TrustFiles.CaFile ?? InheritedFiles.CaFile ?? "", TrustFiles.CrlFile ?? InheritedFiles.CrlFile ?? "");

    private bool Disconnected => session.Snapshot.State is NativeSessionState.Idle or NativeSessionState.Closed or NativeSessionState.Failed;

    public bool CanReload => !stopped && !IsBusy && !session.IsClosing && Disconnected;

    public bool HasChanges => Baseline is { } baseline &&
        (baseline.Types != Resolved.Types || baseline.TlsPriority != Resolved.Priority ||
         baseline.CaFile != ResolvedFiles.CaFile || baseline.CrlFile != ResolvedFiles.CrlFile);

    public bool CanApply => CanReload && !NeedsReload && HasChanges && Preferences.Selection(Inherited) is not null &&
                            Preferences.IsPriorityTextValid && ResolvedFiles.IsValid;

    private void Notify()
    {
        OnPropertyChanged(nameof(HasChanges)); OnPropertyChanged(nameof(CanApply)); OnPropertyChanged(nameof(CanReload));
    }

    public void Reload()
    {
        if (!CanReload) return;
        try
        {
            var value = session.SecurityConfiguration();
            if (!value.Editable) throw new NativeError(NativeStatus.Busy, "Not editable while connected");
            Baseline = value;
            Preferences = new NativeSecurityPatch(value.Types == Inherited.Canonical ? null : value.Types,
                                                  value.TlsPriority == InheritedPriority ? null : value.TlsPriority);
            TrustFiles = new NativeTrustFiles(value.CaFile == (InheritedFiles.CaFile ?? "") ? null : value.CaFile,
                                              value.CrlFile == (InheritedFiles.CrlFile ?? "") ? null : value.CrlFile);
            NeedsReload = false; Error = null; DidApply = false;
        }
        catch (NativeError) { Error = NativeSecurityDraftError.Unavailable; NeedsReload = true; }
        Notify();
    }

    public void Apply()
    {
        if (!CanApply || Baseline is not { } expected) return;
        var (types, priority) = Resolved;
        var files = ResolvedFiles;
        IsBusy = true; Error = null; DidApply = false;
        applying?.Dispose();
        applying = new CancellationTokenSource();
        operation = Run(types, priority, files, expected, applying.Token);
        Notify();
    }

    private async Task Run(string types, string priority, NativeTrustFiles files, NativeSessionSecurity expected, CancellationToken token)
    {
        try
        {
            // The GnuTLS preflight may read library configuration: never on the UI thread.
            await Task.Run(() =>
            {
                token.ThrowIfCancellationRequested();
                if (priority.Length != 0) NativeTlsPriority.Validate(priority);
                if (!files.IsValid) throw new ArgumentException("Invalid certificate file path");
                token.ThrowIfCancellationRequested();
            }, token);
            token.ThrowIfCancellationRequested();
            if (!stopped)
            {
                session.SetSecurity(types, priority, files.CaFile ?? "", files.CrlFile ?? "", expected);
                onApplied();
                Baseline = session.SecurityConfiguration();
                Preferences = new NativeSecurityPatch(Preferences.Types is null ? null : types, Preferences.TlsPriority is null ? null : priority);
                NeedsReload = false; DidApply = true;
            }
        }
        catch (Exception error) when (error is OperationCanceledException or NativeError or ArgumentException)
        {
            if (!stopped)
            {
                Error = error switch
                {
                    OperationCanceledException => NativeSecurityDraftError.Cancelled,
                    ArgumentException => NativeSecurityDraftError.InvalidValue,
                    NativeError { Status: NativeStatus.Unsupported } => NativeSecurityDraftError.UnsupportedValue,
                    NativeError { Status: NativeStatus.InvalidArgument or NativeStatus.ResourceLimit } when priority.Length != 0 && !PriorityValid(priority)
                        => NativeSecurityDraftError.InvalidPriority,
                    NativeError { Status: NativeStatus.InvalidArgument } => NativeSecurityDraftError.InvalidValue,
                    _ => NativeSecurityDraftError.Changed,
                };
                if (Error == NativeSecurityDraftError.Changed) NeedsReload = true;
            }
        }
        IsBusy = false; operation = null;
        Notify();
    }

    private static bool PriorityValid(string priority)
    {
        try { NativeTlsPriority.Validate(priority); return true; }
        catch (NativeError) { return false; }
    }

    public void CancelEdits()
    {
        if (IsBusy || stopped || Baseline is not { } baseline) return;
        Preferences = new NativeSecurityPatch(baseline.Types == Inherited.Canonical ? null : baseline.Types,
                                              baseline.TlsPriority == InheritedPriority ? null : baseline.TlsPriority);
        TrustFiles = new NativeTrustFiles(baseline.CaFile == (InheritedFiles.CaFile ?? "") ? null : baseline.CaFile,
                                          baseline.CrlFile == (InheritedFiles.CrlFile ?? "") ? null : baseline.CrlFile);
        DidApply = false;
        if (!NeedsReload) Error = null;
        Notify();
    }

    public void CancelApply() => applying?.Cancel();

    public void Stop()
    {
        if (stopped) return;
        stopped = true;
        session.PropertyChanged -= SessionChanged;
        applying?.Cancel();
        Notify();
    }

    public async Task CloseAsync()
    {
        Stop();
        if (operation is { } running) await running;
    }

    public void Dispose()
    {
        Stop();
        applying?.Dispose();
    }
}
