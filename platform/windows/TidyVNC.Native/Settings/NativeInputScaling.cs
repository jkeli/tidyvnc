// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;
using TidyVNC.Native.Desktop;

namespace TidyVNC.Native;

public enum NativeInputIssue { Changed, Closed, Failed }

public sealed class NativeInputException(NativeInputIssue issue) : Exception($"Input settings: {issue}")
{
    public NativeInputIssue Issue { get; } = issue;
}

/// <summary>
/// A connection's input policy (macOS NativeInputState). The session stays
/// authoritative for view-only and middle-button emulation; an editor
/// copied before a later change or a replacement connection cannot
/// overwrite it (revision and generation checks). UI thread only.
/// </summary>
public sealed partial class NativeInputState : ObservableObject
{
    private NativeSession? session;
    private (ulong Generation, NativeSessionState State)? observed;
    private bool stopped, applying;

    [ObservableProperty] public partial NativeInputSettings Value { get; private set; } = NativeInputSettings.BuiltIn;
    /// <summary>The cursor shape kept while the fallback is hidden (so turning it back on restores it).</summary>
    [ObservableProperty] public partial NativeCursorFallback InactiveCursor { get; private set; } = NativeCursorFallback.Dot;
    public Dictionary<NativeInputOption, NativeOptionSource> Sources { get; private set; } = [];
    internal Guid Revision { get; private set; } = Guid.NewGuid();
    internal ulong? Generation => session?.Generation;
    internal bool Available => !stopped && session is { IsClosing: false, Snapshot.State: NativeSessionState.Connected };

    public void Bind(NativeSession value, NativeCursorFallback inactiveCursor = NativeCursorFallback.Dot)
    {
        if (stopped || ReferenceEquals(session, value)) return;
        if (session is not null) session.PropertyChanged -= SessionChanged;
        session = value;
        Revision = Guid.NewGuid();
        Sources = new Dictionary<NativeInputOption, NativeOptionSource>(value.InitialInputSources)
        {
            [NativeInputOption.ViewOnly] = value.ViewOnlySource,
            [NativeInputOption.EmulateMiddle] = value.MiddleButtonSource,
        };
        InactiveCursor = value.InitialInput.CursorFallback == NativeCursorFallback.Hidden
            ? inactiveCursor == NativeCursorFallback.System ? NativeCursorFallback.System : NativeCursorFallback.Dot
            : value.InitialInput.CursorFallback;
        Value = value.InitialInput with { ViewOnly = value.IsViewOnly, EmulateMiddle = value.EmulatesMiddleButton };
        observed = (value.Snapshot.Generation, value.Snapshot.State);
        value.PropertyChanged += SessionChanged;
    }

    private void SessionChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (session is null || applying) return;
        switch (e.PropertyName)
        {
            case nameof(NativeSession.IsViewOnly) when Value.ViewOnly != session.IsViewOnly:
                Revision = Guid.NewGuid(); Sources[NativeInputOption.ViewOnly] = NativeOptionSource.Session;
                Value = Value with { ViewOnly = session.IsViewOnly };
                break;
            case nameof(NativeSession.EmulatesMiddleButton) when Value.EmulateMiddle != session.EmulatesMiddleButton:
                Revision = Guid.NewGuid(); Sources[NativeInputOption.EmulateMiddle] = NativeOptionSource.Session;
                Value = Value with { EmulateMiddle = session.EmulatesMiddleButton };
                break;
            // Frames and counters update the snapshot constantly; only a new attempt or state is a change.
            case nameof(NativeSession.Snapshot) when observed != (session.Snapshot.Generation, session.Snapshot.State):
                observed = (session.Snapshot.Generation, session.Snapshot.State);
                Revision = Guid.NewGuid();
                break;
        }
    }

    internal void Apply(NativeInputSettings candidate, Guid revision, ulong? generation)
    {
        if (!Available || session is null) throw new NativeInputException(NativeInputIssue.Closed);
        if (Revision != revision || session.Generation != generation) throw new NativeInputException(NativeInputIssue.Changed);
        if (((uint)candidate.ShortcutModifiers & ~15u) != 0) throw new NativeInputException(NativeInputIssue.Failed);
        applying = true;
        try
        {
            if (session.IsViewOnly != candidate.ViewOnly || session.EmulatesMiddleButton != candidate.EmulateMiddle)
            {
                try { session.SetInputPolicy(candidate.ViewOnly, candidate.EmulateMiddle); }
                catch (NativeError) { throw new NativeInputException(NativeInputIssue.Failed); }
            }
        }
        finally { applying = false; }
        if (Value.ViewOnly != candidate.ViewOnly) Sources[NativeInputOption.ViewOnly] = NativeOptionSource.Session;
        if (Value.EmulateMiddle != candidate.EmulateMiddle) Sources[NativeInputOption.EmulateMiddle] = NativeOptionSource.Session;
        if (Value.ShortcutModifiers != candidate.ShortcutModifiers) Sources[NativeInputOption.ShortcutModifiers] = NativeOptionSource.Session;
        if (Value.FullscreenSystemKeys != candidate.FullscreenSystemKeys) Sources[NativeInputOption.FullscreenSystemKeys] = NativeOptionSource.Session;
        if (Value.CursorFallback != candidate.CursorFallback) Sources[NativeInputOption.CursorFallback] = NativeOptionSource.Session;
        if (candidate.CursorFallback != NativeCursorFallback.Hidden) InactiveCursor = candidate.CursorFallback;
        Revision = Guid.NewGuid();
        Value = candidate;
    }

    public void Stop()
    {
        stopped = true;
        Revision = Guid.NewGuid();
        if (session is not null) session.PropertyChanged -= SessionChanged;
        session = null;
    }
}

/// <summary>The Input dialog's editor (macOS NativeInputDraft; PARITY I01-I13, K01-K06).</summary>
public sealed partial class NativeInputDraft : ObservableObject
{
    private readonly NativeInputState? state;
    private readonly Guid revision;
    private readonly ulong? generation;
    private readonly NativeInputSettings baseline;

    [ObservableProperty] public partial NativeShortcutModifiers ShortcutModifiers { get; set; }
    [ObservableProperty] public partial bool FullscreenSystemKeys { get; set; }
    [ObservableProperty] public partial bool EmulateMiddle { get; set; }
    [ObservableProperty] public partial bool ViewOnly { get; set; }
    [ObservableProperty] public partial NativeCursorFallback CursorFallback { get; set; }
    [ObservableProperty] public partial NativeInputIssue? Issue { get; private set; }
    [ObservableProperty] public partial bool Finished { get; private set; }
    public IReadOnlyDictionary<NativeInputOption, NativeOptionSource> Sources { get; }

    public NativeInputDraft(NativeInputState state)
    {
        this.state = state;
        revision = state.Revision; generation = state.Generation; baseline = state.Value;
        Sources = new Dictionary<NativeInputOption, NativeOptionSource>(state.Sources);
        ShortcutModifiers = baseline.ShortcutModifiers; FullscreenSystemKeys = baseline.FullscreenSystemKeys;
        ViewOnly = baseline.ViewOnly; EmulateMiddle = baseline.EmulateMiddle; CursorFallback = baseline.CursorFallback;
        PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(Issue) or nameof(Finished) or nameof(CanApply)) return;
            Issue = null;
            OnPropertyChanged(nameof(CanApply));
        };
    }

    private NativeInputSettings Candidate => new(ViewOnly, EmulateMiddle, ShortcutModifiers, FullscreenSystemKeys, CursorFallback);

    public NativeOptionSource Source(NativeInputOption option)
    {
        var changed = option switch
        {
            NativeInputOption.ViewOnly => ViewOnly != baseline.ViewOnly,
            NativeInputOption.EmulateMiddle => EmulateMiddle != baseline.EmulateMiddle,
            NativeInputOption.ShortcutModifiers => ShortcutModifiers != baseline.ShortcutModifiers,
            NativeInputOption.FullscreenSystemKeys => FullscreenSystemKeys != baseline.FullscreenSystemKeys,
            _ => CursorFallback != baseline.CursorFallback,
        };
        return changed ? NativeOptionSource.Session : Sources.GetValueOrDefault(option, NativeOptionSource.Compiled);
    }

    public bool CanApply => !Finished && state?.Available == true && Candidate != baseline;

    public bool Apply()
    {
        if (Finished) return false;
        if (state is null) { Issue = NativeInputIssue.Closed; return false; }
        try
        {
            state.Apply(Candidate, revision, generation);
            Finished = true;
            return true;
        }
        catch (NativeInputException error)
        {
            Issue = error.Issue;
            return false;
        }
    }

    public void Cancel() => Finished = true;
}

public enum NativeScalingIssue { Invalid, Dimensions, Changed, Closed }

public sealed class NativeScalingException(NativeScalingIssue issue) : Exception($"Scaling: {issue}")
{
    public NativeScalingIssue Issue { get; } = issue;
}

/// <summary>
/// A connection's scaling (macOS NativeScalingState). Desktop surfaces
/// register a validator; a value is applied only when every surface can
/// render it. UI thread only.
/// </summary>
public sealed partial class NativeScalingState : ObservableObject
{
    private readonly List<Func<NativeScaling, bool>> validators = [];
    private bool stopped;

    [ObservableProperty] public partial NativeScaling Value { get; private set; } = NativeScaling.BuiltIn;
    public Dictionary<NativeScalingOption, NativeOptionSource> Sources { get; private set; } = [];
    internal Guid Revision { get; private set; } = Guid.NewGuid();
    internal bool Stopped => stopped;

    public void Bind(NativeSession session)
    {
        if (stopped) return;
        Revision = Guid.NewGuid();
        Sources = new Dictionary<NativeScalingOption, NativeOptionSource>(session.InitialScalingSources);
        Value = session.InitialScaling ?? NativeScaling.BuiltIn;
    }

    /// <summary>A surface's check that it can render a value (backing-store limits).</summary>
    public IDisposable Register(Func<NativeScaling, bool> validator)
    {
        validators.Add(validator);
        return new Registration(() => validators.Remove(validator));
    }

    private sealed class Registration(Action dispose) : IDisposable
    {
        public void Dispose() => dispose();
    }

    internal void Apply(NativeScaling value, Guid expected)
    {
        if (stopped) throw new NativeScalingException(NativeScalingIssue.Closed);
        if (Revision != expected) throw new NativeScalingException(NativeScalingIssue.Changed);
        if (validators.Any(validate => !validate(value))) throw new NativeScalingException(NativeScalingIssue.Dimensions);
        if (Value.Canonical != value.Canonical) Sources[NativeScalingOption.Scaling] = NativeOptionSource.Session;
        if (Value.DevicePixels != value.DevicePixels) Sources[NativeScalingOption.DevicePixels] = NativeOptionSource.Session;
        if (Value.Filter != value.Filter) Sources[NativeScalingOption.Filter] = NativeOptionSource.Session;
        Revision = Guid.NewGuid();
        Value = value;
    }

    public void Stop()
    {
        stopped = true;
        Revision = Guid.NewGuid();
        validators.Clear();
    }
}

/// <summary>The Scaling dialog's editor (macOS NativeScalingDraft; PARITY Z01-Z12).</summary>
public sealed partial class NativeScalingDraft : ObservableObject
{
    private readonly NativeScalingState? state;
    private readonly Guid revision;
    private readonly NativeScaling baseline;
    private readonly Dictionary<NativeScalingMode, string> texts = [];

    [ObservableProperty] public partial NativeScalingMode Mode { get; set; }
    [ObservableProperty] public partial bool DevicePixels { get; set; }
    [ObservableProperty] public partial NativeScalingFilter Filter { get; set; }
    [ObservableProperty] public partial NativeScalingIssue? Issue { get; private set; }
    [ObservableProperty] public partial bool Finished { get; private set; }
    public IReadOnlyDictionary<NativeScalingOption, NativeOptionSource> Sources { get; }

    public NativeScalingDraft(NativeScalingState state)
    {
        this.state = state;
        revision = state.Revision; baseline = state.Value;
        Sources = new Dictionary<NativeScalingOption, NativeOptionSource>(state.Sources);
        Mode = baseline.Mode; DevicePixels = baseline.DevicePixels; Filter = baseline.Filter;
        texts[baseline.Mode] = baseline.Canonical;
        PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(Issue) or nameof(Finished) or nameof(CanApply) or nameof(Candidate) or nameof(Text)) return;
            Issue = null;
            OnPropertyChanged(nameof(Text)); OnPropertyChanged(nameof(Candidate)); OnPropertyChanged(nameof(CanApply));
        };
    }

    /// <summary>The custom value for the current mode (dimensions or percentages); kept per mode.</summary>
    public string Text
    {
        get => texts.TryGetValue(Mode, out var value) ? value : Mode.InitialText();
        set
        {
            texts[Mode] = value;
            Issue = null;
            OnPropertyChanged(); OnPropertyChanged(nameof(Candidate)); OnPropertyChanged(nameof(CanApply));
        }
    }

    public NativeScaling? Candidate =>
        NativeScaling.TryParse(Mode.Custom() ? Text : Mode.InitialText(), DevicePixels, Filter, out var result) &&
        (result!.Mode == Mode || (Mode == NativeScalingMode.Percent && result.Mode == NativeScalingMode.Unscaled)) ? result : null;

    public NativeOptionSource Source(NativeScalingOption option)
    {
        var changed = option switch
        {
            NativeScalingOption.Scaling => Candidate?.Canonical != baseline.Canonical,
            NativeScalingOption.DevicePixels => DevicePixels != baseline.DevicePixels,
            _ => Filter != baseline.Filter,
        };
        return changed ? NativeOptionSource.Session : Sources.GetValueOrDefault(option, NativeOptionSource.Compiled);
    }

    public bool CanApply => !Finished && state?.Stopped == false && Candidate is { } value && value != baseline;

    public bool Apply()
    {
        if (Finished) return false;
        if (state is null) { Issue = NativeScalingIssue.Closed; return false; }
        if (Candidate is not { } value) { Issue = NativeScalingIssue.Invalid; return false; }
        try
        {
            state.Apply(value, revision);
            Finished = true;
            return true;
        }
        catch (NativeScalingException error)
        {
            Issue = error.Issue;
            return false;
        }
    }

    public void Cancel() => Finished = true;
}
