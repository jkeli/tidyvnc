// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;
using TidyVNC.Native.Platform;

namespace TidyVNC.Native;

public enum NativeFullscreenPhase { Windowed, Entering, Active, Exiting }

/// <summary>
/// One connection window's full-screen policy and intent (macOS
/// NativeFullscreenState without the AppKit window handling; DESKTOP.md
/// section 7). The window's presenter reports its phase; this decides when
/// automatic entry is due: once per connected generation while full screen is
/// wanted. Entering sets that intent and leaving through the window clears
/// it, so a dropped connection that reconnects returns to full screen while a
/// user's exit sticks. UI thread only.
/// </summary>
public sealed partial class NativeFullscreenState : ObservableObject
{
    private readonly Dictionary<NativeFullscreenOption, NativeOptionSource> sources = [];
    private NativeSession? session;
    private bool wantsFullscreen, stopped;
    private bool? nextAttemptOverride;
    private ulong? attemptGeneration, automaticGeneration;

    [ObservableProperty] public partial NativeFullscreenPolicy Policy { get; private set; } = NativeFullscreenPolicy.BuiltIn;
    [ObservableProperty] public partial NativeFullscreenPhase Phase { get; private set; }
    [ObservableProperty] public partial NativeText? Message { get; set; }
    public NativeFullscreenPolicy InitialPolicy { get; private set; } = NativeFullscreenPolicy.BuiltIn;
    public IReadOnlyDictionary<NativeFullscreenOption, NativeOptionSource> Sources => sources;
    /// <summary>Changes with every applied policy; editors opened before it are stale.</summary>
    public Guid Revision { get; private set; } = Guid.NewGuid();
    /// <summary>Raised when automatic entry becomes due; the window calls <see cref="TakeAutomaticEntry"/> when it can present.</summary>
    public event Action? AutomaticEntryDue;

    public NativeSession? Session => session;
    public ulong? Generation => session?.Generation;
    public bool Connected => !stopped && session is { IsClosing: false, Snapshot.State: NativeSessionState.Connected };
    public bool IsStopped => stopped;

    public void Bind(NativeSession value)
    {
        if (stopped || ReferenceEquals(session, value)) return;
        if (session is not null) session.PropertyChanged -= SessionChanged;
        session = value;
        InitialPolicy = value.InitialFullscreenPolicy;
        Policy = InitialPolicy;
        sources.Clear();
        foreach (var (option, source) in value.InitialFullscreenSources) sources[option] = source;
        Revision = Guid.NewGuid();
        wantsFullscreen = InitialPolicy.StartsFullscreen;
        nextAttemptOverride = null; attemptGeneration = null; automaticGeneration = null;
        Message = null;
        value.PropertyChanged += SessionChanged;
        Observe();
    }

    private void SessionChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(NativeSession.IsClosing) && session?.IsClosing == true) { Stop(); return; }
        if (e.PropertyName == nameof(NativeSession.Snapshot)) Observe();
    }

    private void Observe()
    {
        if (session is null) return;
        var snapshot = session.Snapshot;
        if (snapshot.State != NativeSessionState.Connected) automaticGeneration = null;
        if (snapshot.State is not (NativeSessionState.Idle or NativeSessionState.Closed or NativeSessionState.Failed) &&
            attemptGeneration != snapshot.Generation)
        {
            attemptGeneration = snapshot.Generation;
            if (nextAttemptOverride is { } next) { wantsFullscreen = next; nextAttemptOverride = null; }
        }
        if (snapshot.State == NativeSessionState.Connected && wantsFullscreen && automaticGeneration is null && Phase == NativeFullscreenPhase.Windowed)
        {
            automaticGeneration = snapshot.Generation;
            AutomaticEntryDue?.Invoke();
        }
    }

    /// <summary>One attempt per connection: true if automatic entry is due now for the current generation.</summary>
    public bool TakeAutomaticEntry()
    {
        if (!Connected || automaticGeneration != Generation || Phase != NativeFullscreenPhase.Windowed) return false;
        automaticGeneration = ulong.MaxValue; // Taken; a new connection clears it.
        return true;
    }

    /// <summary>Whether automatic entry is waiting for the window to be able to present.</summary>
    public bool AutomaticEntryPending => Connected && automaticGeneration is { } generation && generation == Generation;

    /// <summary>The presenter's transitions: entering records the intent, a user exit clears it.</summary>
    public void SetPhase(NativeFullscreenPhase value)
    {
        if (stopped) return;
        if (value == NativeFullscreenPhase.Entering) wantsFullscreen = true;
        if (value == NativeFullscreenPhase.Exiting) wantsFullscreen = false;
        Phase = value;
    }

    /// <summary>Full screen ended without an exit request: a disconnect keeps the intent, anything else clears it.</summary>
    public void Ended(bool disconnected)
    {
        if (!disconnected) wantsFullscreen = false;
        Phase = NativeFullscreenPhase.Windowed;
    }

    /// <summary>An automatic attempt that failed does not repeat for this connection.</summary>
    public void AutomaticEntryFailed(NativeText message)
    {
        wantsFullscreen = false;
        Message = message;
    }

    internal void Apply(NativeFullscreenPolicy candidate, Guid expected, ulong generation)
    {
        if (!Connected || Phase != NativeFullscreenPhase.Windowed || Revision != expected || Generation != generation)
            throw new NativeError(NativeStatus.Stale, "Full-screen settings changed");
        if (candidate.StartsFullscreen != Policy.StartsFullscreen)
        {
            sources[NativeFullscreenOption.StartsFullscreen] = NativeOptionSource.Session;
            nextAttemptOverride = candidate.StartsFullscreen;
        }
        if (candidate.Mode != Policy.Mode) sources[NativeFullscreenOption.Mode] = NativeOptionSource.Session;
        if (!candidate.SelectedDisplays.SequenceEqual(Policy.SelectedDisplays)) sources[NativeFullscreenOption.SelectedDisplays] = NativeOptionSource.Session;
        Revision = Guid.NewGuid();
        Policy = candidate;
        Message = null;
    }

    public void Stop()
    {
        if (stopped) return;
        stopped = true;
        if (session is not null) session.PropertyChanged -= SessionChanged;
        automaticGeneration = null;
        AutomaticEntryDue = null;
        OnPropertyChanged(nameof(Connected));
    }
}

/// <summary>
/// Full-screen display settings for one connection (macOS
/// NativeFullscreenDraft; PARITY D02-D05): whether it starts full screen, the
/// displays it uses, and a review of the arrangement. Applying needs the same
/// connection, a windowed desktop and a reviewed, mappable arrangement.
/// </summary>
public sealed partial class NativeFullscreenDraft : ObservableObject
{
    private readonly NativeFullscreenState state;
    private readonly NativeDisplayService displays;
    private readonly Func<string?> currentDisplay;
    private readonly Func<bool> devicePixels;
    private readonly Guid revision;
    private readonly ulong? generation;
    private readonly NativeFullscreenPolicy baseline;
    private readonly Dictionary<NativeFullscreenOption, NativeOptionSource> sources;
    private ulong? reviewed;
    private bool stopped;

    [ObservableProperty] public partial bool StartsFullscreen { get; set; }
    [ObservableProperty] public partial NativeFullscreenMode Mode { get; set; }
    [ObservableProperty] public partial IReadOnlySet<string> SelectedDisplays { get; set; }
    [ObservableProperty] public partial bool Changed { get; private set; }

    public NativeFullscreenDraft(NativeFullscreenState state, NativeDisplayService displays, Func<string?> currentDisplay, Func<bool> devicePixels)
    {
        this.state = state; this.displays = displays; this.currentDisplay = currentDisplay; this.devicePixels = devicePixels;
        baseline = state.Policy; revision = state.Revision; generation = state.Generation;
        sources = new Dictionary<NativeFullscreenOption, NativeOptionSource>(state.Sources);
        StartsFullscreen = baseline.StartsFullscreen; Mode = baseline.Mode;
        SelectedDisplays = baseline.SelectedDisplays.ToHashSet(StringComparer.Ordinal);
        displays.Refresh();
        reviewed = displays.Snapshot.Generation;
        displays.PropertyChanged += DisplaysChanged;
        state.PropertyChanged += StateChanged;
    }

    private void DisplaysChanged(object? sender, PropertyChangedEventArgs e) => Notify();
    private void StateChanged(object? sender, PropertyChangedEventArgs e) => Notify();

    private void Notify()
    {
        OnPropertyChanged(nameof(Snapshot)); OnPropertyChanged(nameof(Validation)); OnPropertyChanged(nameof(CanApply));
        OnPropertyChanged(nameof(NeedsReview)); OnPropertyChanged(nameof(Missing)); OnPropertyChanged(nameof(ChosenDisplays));
    }

    protected override void OnPropertyChanged(PropertyChangedEventArgs e)
    {
        base.OnPropertyChanged(e);
        if (e.PropertyName is nameof(StartsFullscreen) or nameof(Mode) or nameof(SelectedDisplays)) Notify();
    }

    public NativeDisplaySnapshot Snapshot => displays.Snapshot;

    private NativeFullscreenPolicy? Candidate
    {
        get
        {
            try { return new NativeFullscreenPolicy(StartsFullscreen, Mode, SelectedDisplays.Order(StringComparer.Ordinal)); }
            catch (ArgumentException) { return null; }
        }
    }

    public NativeOptionSource Source(NativeFullscreenOption option)
    {
        var changed = option switch
        {
            NativeFullscreenOption.StartsFullscreen => StartsFullscreen != baseline.StartsFullscreen,
            NativeFullscreenOption.Mode => Mode != baseline.Mode,
            _ => !SelectedDisplays.SetEquals(baseline.SelectedDisplays),
        };
        return changed ? NativeOptionSource.Session : sources.GetValueOrDefault(option, NativeOptionSource.Compiled);
    }

    public void RestoreInitial()
    {
        if (stopped) return;
        StartsFullscreen = state.InitialPolicy.StartsFullscreen;
        Mode = state.InitialPolicy.Mode;
        SelectedDisplays = state.InitialPolicy.SelectedDisplays.ToHashSet(StringComparer.Ordinal);
    }

    /// <summary>Selected displays that are not connected now, in ID order.</summary>
    public IReadOnlyList<string> Missing => [.. SelectedDisplays.Where(id => Snapshot.Find(id) is null).Order(StringComparer.Ordinal)];

    public IReadOnlyList<NativeDisplayInfo> ChosenDisplays => Mode switch
    {
        NativeFullscreenMode.Current => Snapshot.Resolve([], currentDisplay()).Displays,
        NativeFullscreenMode.All => Snapshot.Displays,
        _ => SelectedDisplays.Count == 0 ? [] : Snapshot.Resolve(SelectedDisplays.Order(StringComparer.Ordinal), currentDisplay()).Displays,
    };

    public bool NeedsReview => Snapshot.Generation != reviewed;

    /// <summary>Why this cannot be applied (macOS validationMessage), or null.</summary>
    public NativeText? Validation
    {
        get
        {
            if (!state.Connected || state.Revision != revision || state.Generation != generation)
                return new("settings.fullscreen.the.connection.changed.close.and.reopen.this.sheet");
            if (NeedsReview) return new("settings.fullscreen.displays.changed.review.the.new.arrangement.before.applying");
            if (Snapshot.Error is not null || Snapshot.Displays.IsEmpty) return new("settings.fullscreen.display.information.is.unavailable");
            if (Mode == NativeFullscreenMode.Selected && SelectedDisplays.Count == 0) return new("settings.fullscreen.select.at.least.one.display");
            if (SelectedDisplays.Count > NativeDisplayService.MaximumDisplays || Candidate is null)
                return new("settings.fullscreen.select.up.to.64.displays.with.valid.saved.identities.remove.unavailable.selections");
            try { _ = new NativeDisplayLayout(ChosenDisplays, devicePixels()); }
            catch (NativeError) { return new("settings.fullscreen.this.display.arrangement.cannot.be.mapped.overlapping.or.mirrored.displays.are.not"); }
            return null;
        }
    }

    public bool CanApply => !stopped && state.Phase == NativeFullscreenPhase.Windowed && Validation is null && Candidate is { } candidate && candidate != baseline;

    public void ReviewDisplays()
    {
        if (stopped) return;
        displays.Refresh();
        reviewed = Snapshot.Generation;
        Notify();
    }

    public bool Apply()
    {
        if (stopped) return false;
        displays.Refresh();
        if (!CanApply || generation is not { } expected || Candidate is not { } candidate) { Notify(); return false; }
        try
        {
            state.Apply(candidate, revision, expected);
            Cancel();
            return true;
        }
        catch (NativeError) { Changed = true; return false; }
    }

    public void Cancel()
    {
        if (stopped) return;
        stopped = true;
        displays.PropertyChanged -= DisplaysChanged;
        state.PropertyChanged -= StateChanged;
        Notify();
    }
}
