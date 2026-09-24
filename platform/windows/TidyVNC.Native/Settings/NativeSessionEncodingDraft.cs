// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;

namespace TidyVNC.Native;

public enum NativeEncodingDraftError { Unavailable, InvalidValue, UnsupportedValue, Changed, ApplyFailed, Cancelled }

/// <summary>What an encoding draft edits: a live session (tests substitute a fake).</summary>
public interface INativeEncodingTarget
{
    ulong EncodingGeneration { get; }
    bool EncodingEditable { get; }
    NativeEncodingOptions ReadEncoding();
    Task SubmitEncodingAsync(NativeEncodingOptions options, ulong generation, CancellationToken cancellation);
}

/// <summary>
/// One encoding editor for one session generation (NativeSessionEncodingDraft.swift).
/// Only live options can be edited; nothing here touches saved defaults.
/// Apply first checks that nobody else changed the options, and confirms the
/// result afterwards; a cancelled apply is reported as possibly partial.
/// UI thread only.
/// </summary>
public sealed partial class NativeSessionEncodingDraft : ObservableObject, IDisposable
{
    private readonly INativeEncodingTarget? target;
    private readonly NativeSession? session;
    private NativeEncodingOptions? baseline, draft;
    private IReadOnlyDictionary<NativeEncodingOption, NativeEncodingValue> baselineValues = new Dictionary<NativeEncodingOption, NativeEncodingValue>();
    private ulong? generation;
    private CancellationTokenSource? applying;
    private Task? operation;
    private bool stopped;

    [ObservableProperty] public partial IReadOnlyDictionary<NativeEncodingOption, NativeEncodingValue> Values { get; private set; } =
        new Dictionary<NativeEncodingOption, NativeEncodingValue>();
    [ObservableProperty] public partial IReadOnlyList<NativeEncodingSchema> Schema { get; private set; } = [];
    [ObservableProperty] public partial IReadOnlyList<NativeEncodingChoice> Choices { get; private set; } = [];
    [ObservableProperty] public partial bool IsBusy { get; private set; }
    [ObservableProperty] public partial bool IsAvailable { get; private set; }
    [ObservableProperty] public partial bool NeedsReload { get; private set; }
    [ObservableProperty] public partial NativeEncodingDraftError? Error { get; private set; }
    [ObservableProperty] public partial bool DidApply { get; private set; }

    public NativeSessionEncodingDraft(INativeEncodingTarget target) => this.target = target;

    public NativeSessionEncodingDraft(NativeSession session) : this(new SessionTarget(session))
    {
        this.session = session;
        session.PropertyChanged += SessionChanged;
    }

    private sealed class SessionTarget(NativeSession session) : INativeEncodingTarget
    {
        public ulong EncodingGeneration => session.Generation;
        public bool EncodingEditable => !session.IsClosing && session.Snapshot.State == NativeSessionState.Connected;
        public NativeEncodingOptions ReadEncoding() => session.EncodingOptions();
        public async Task SubmitEncodingAsync(NativeEncodingOptions options, ulong generation, CancellationToken cancellation)
        {
            cancellation.ThrowIfCancellationRequested();
            // Awaited to the core's completion even when cancelled: the next editor waits for it.
            try { await session.ApplyEncodingAsync(options, generation, cancellation); }
            catch (NativeCommandFailure failure) when (failure.Result == NativeCommandFailure.ResultKind.Cancelled)
            {
                throw new OperationCanceledException(cancellation);
            }
        }
    }

    private void SessionChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (session is null) return;
        if (e.PropertyName == nameof(NativeSession.Snapshot))
            Changed(session.Snapshot.Generation, session.Snapshot.State == NativeSessionState.Connected);
        else if (e.PropertyName == nameof(NativeSession.IsClosing) && session.IsClosing) Changed(null, false);
    }

    private void Changed(ulong? current, bool connected)
    {
        if (stopped) return;
        if (IsAvailable != connected) IsAvailable = connected;
        if (baseline is not null && (!connected || generation != current))
        {
            NeedsReload = true; Error = NativeEncodingDraftError.Changed; DidApply = false;
        }
        Notify();
    }

    private static Dictionary<NativeEncodingOption, NativeEncodingValue> Read(NativeEncodingOptions options) =>
        Enum.GetValues<NativeEncodingOption>().ToDictionary(o => o, options.Value);

    private static bool Same(IReadOnlyDictionary<NativeEncodingOption, NativeEncodingValue> a, IReadOnlyDictionary<NativeEncodingOption, NativeEncodingValue> b) =>
        a.Count == b.Count && a.All(p => b.TryGetValue(p.Key, out var other) && other == p.Value);

    public bool HasChanges => baseline is not null && !Same(Values, baselineValues);
    public bool CanApply => !stopped && !IsBusy && !NeedsReload && HasChanges && target?.EncodingEditable == true && target.EncodingGeneration == generation;
    public bool CanReload => !stopped && !IsBusy && target?.EncodingEditable == true;

    private void Notify()
    {
        OnPropertyChanged(nameof(HasChanges)); OnPropertyChanged(nameof(CanApply)); OnPropertyChanged(nameof(CanReload));
    }

    public void Reload()
    {
        if (stopped || IsBusy) return;
        if (target is not { EncodingEditable: true })
        {
            IsAvailable = false; NeedsReload = true; Error = NativeEncodingDraftError.Unavailable;
            Notify();
            return;
        }
        try
        {
            var current = target.ReadEncoding();
            var fields = Read(current);
            Schema = NativeEncodingOptions.Schema(); Choices = NativeEncodingOptions.Choices();
            baseline = draft = current; baselineValues = fields; Values = fields; generation = target.EncodingGeneration;
            IsAvailable = true; NeedsReload = false; Error = null; DidApply = false;
        }
        catch (NativeError) { NeedsReload = true; Error = NativeEncodingDraftError.Unavailable; }
        Notify();
    }

    public void SetEncoding(NativeEncodingOption option, string value)
    {
        if (stopped || IsBusy || NeedsReload || draft is null || Schema.FirstOrDefault(s => s.Id == option) is not { Live: true } field) return;
        try
        {
            var updated = draft.Applying([new NativeEncodingAssignment(field.Name, value)], NativeOptionSource.Session);
            Values = Read(updated);
            draft = updated; Error = null; DidApply = false;
        }
        catch (NativeError error)
        {
            Error = error.Status == NativeStatus.Unsupported ? NativeEncodingDraftError.UnsupportedValue : NativeEncodingDraftError.InvalidValue;
        }
        Notify();
    }

    public void CancelEdits()
    {
        if (IsBusy || stopped) return;
        draft = baseline; Values = baselineValues; DidApply = false;
        if (!NeedsReload) Error = null;
        Notify();
    }

    public void Apply()
    {
        if (!CanApply || target is null || draft is not { } submitted || generation is not { } expected) return;
        try
        {
            // An observed competing edit; the app admits one encoding editor per connection.
            if (!Same(Read(target.ReadEncoding()), baselineValues))
            {
                NeedsReload = true; Error = NativeEncodingDraftError.Changed;
                Notify();
                return;
            }
        }
        catch (NativeError)
        {
            NeedsReload = true; Error = NativeEncodingDraftError.Unavailable;
            Notify();
            return;
        }
        var submittedValues = Values;
        IsBusy = true; Error = null; DidApply = false;
        applying?.Dispose();
        applying = new CancellationTokenSource();
        operation = Run(target, submitted, submittedValues, expected, applying.Token);
        Notify();
    }

    private async Task Run(INativeEncodingTarget owner, NativeEncodingOptions submitted, IReadOnlyDictionary<NativeEncodingOption, NativeEncodingValue> submittedValues,
                           ulong expected, CancellationToken token)
    {
        try
        {
            // Admission happens on the next turn, so an immediate Cancel apply submits nothing.
            await Task.Yield();
            token.ThrowIfCancellationRequested();
            await owner.SubmitEncodingAsync(submitted, expected, token);
            if (!stopped)
            {
                if (!owner.EncodingEditable || owner.EncodingGeneration != expected || !Same(Read(owner.ReadEncoding()), submittedValues))
                    throw new InvalidOperationException("changed");
                baseline = submitted; baselineValues = submittedValues;
                NeedsReload = false; DidApply = true;
            }
        }
        catch (Exception error) when (error is OperationCanceledException or NativeError or NativeCommandFailure or InvalidOperationException)
        {
            if (!stopped)
            {
                NeedsReload = true;
                Error = error switch
                {
                    OperationCanceledException => NativeEncodingDraftError.Cancelled,
                    InvalidOperationException => NativeEncodingDraftError.Changed,
                    _ => NativeEncodingDraftError.ApplyFailed,
                };
            }
        }
        IsBusy = false; operation = null;
        Notify();
    }

    public void CancelApply() => applying?.Cancel();

    public void Stop()
    {
        if (stopped) return;
        stopped = true; IsAvailable = false;
        if (session is not null) session.PropertyChanged -= SessionChanged;
        applying?.Cancel();
        Notify();
    }

    /// <summary>Stops and waits for a cancelled apply to drain (the next editor waits for it).</summary>
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
