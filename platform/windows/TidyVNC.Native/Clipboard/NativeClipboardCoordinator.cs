// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;

namespace TidyVNC.Native.Clipboard;

/// <summary>A clipboard problem shown on the affected connection (the app localizes it).</summary>
public enum NativeClipboardNotice
{
    /// <summary>The local clipboard could not be sent (not plain text of at most 256 KiB, or unavailable).</summary>
    LocalNotSent,
    /// <summary>The transfer failed; copying again retries.</summary>
    TransferFailed,
    /// <summary>The remote clipboard text could not be accepted.</summary>
    RemoteRejected,
    /// <summary>The remote clipboard could not be written on this PC.</summary>
    RemoteNotWritten,
}

/// <summary>
/// The app-wide clipboard router (SERVICES.md section 6; NativeClipboardCoordinator
/// on macOS). Text goes only to the one connection whose desktop is focused
/// in the active app, is connected and not view-only; ambiguous focus routes
/// nothing. A local change is offered when it happens (clipboard listener)
/// and again when focus returns, if it changed meanwhile. Remote text is
/// written with provenance, and text carrying this process's provenance is
/// never sent back. One operation owns all clipboard access at a time; any
/// routing change invalidates pending work. UI thread only.
/// </summary>
public sealed class NativeClipboardCoordinator : IDisposable
{
    public const int MaximumBytes = 256 * 1024;

    private sealed class Registration(NativeSession session, Action<NativeClipboardNotice?> report)
    {
        public NativeSession Session { get; } = session;
        public Action<NativeClipboardNotice?> Report { get; } = report;
        public PropertyChangedEventHandler? Handler { get; set; }
        /// <summary>Only state transitions route; frame and counter updates do not.</summary>
        public NativeSessionState State { get; set; } = session.Snapshot.State;
    }

    private sealed record RemoteJob(NativeSession Session, NativeClipboardUpdate Update, ulong Epoch);

    private static readonly string[] RoutingProperties =
    [
        nameof(NativeSession.IsFocused), nameof(NativeSession.IsClosing), nameof(NativeSession.IsViewOnly),
        nameof(NativeSession.ClipboardSendEnabled), nameof(NativeSession.ClipboardReceiveEnabled),
    ];

    private readonly IUiDispatcher dispatcher;
    private readonly INativeClipboardAccess clipboard;
    private readonly List<Registration> registrations = [];
    private NativeSession? active;
    private bool applicationActive = true, stopped, reconciliationQueued, sendEnabled, pollRequested;
    private ulong epoch;
    private uint? observedChange;
    private RemoteJob? pendingRemote;
    private Task? operation;
    private CancellationTokenSource? operationCancel;
    private readonly Action changed;

    public NativeClipboardCoordinator(IUiDispatcher dispatcher, INativeClipboardAccess clipboard)
    {
        this.dispatcher = dispatcher;
        this.clipboard = clipboard;
        changed = () => dispatcher.TryEnqueue(Poll);
        clipboard.Changed += changed;
    }

    /// <summary>The operation in flight (tests and close await it).</summary>
    public Task Operation => operation ?? Task.CompletedTask;

    public void Register(NativeSession session, Action<NativeClipboardNotice?>? onStatus = null)
    {
        UiThread.Require(dispatcher);
        if (stopped || registrations.Any(r => ReferenceEquals(r.Session, session))) return;
        var entry = new Registration(session, onStatus ?? (_ => { }));
        entry.Handler = (_, change) =>
        {
            if (change.PropertyName is { } name && RoutingProperties.Contains(name)) RoutingChanged();
            else if (change.PropertyName == nameof(NativeSession.Snapshot))
            {
                if (session.Snapshot.State == entry.State) return;
                entry.State = session.Snapshot.State;
                RoutingChanged();
            }
            // Registration never replays a cached remote copy over a newer local one.
            else if (change.PropertyName == nameof(NativeSession.Clipboard) && session.Clipboard is { } update) Receive(update, session);
        };
        session.PropertyChanged += entry.Handler;
        registrations.Add(entry);
        ScheduleReconciliation();
    }

    public void Unregister(NativeSession session)
    {
        UiThread.Require(dispatcher);
        foreach (var entry in registrations.Where(r => ReferenceEquals(r.Session, session)).ToList())
        {
            session.PropertyChanged -= entry.Handler;
            registrations.Remove(entry);
        }
        Reconcile();
    }

    /// <summary>App activation: losing it unfocuses every desktop, which also invalidates admitted sends.</summary>
    public void SetApplicationActive(bool enabled)
    {
        UiThread.Require(dispatcher);
        applicationActive = enabled;
        if (!enabled)
            foreach (var entry in registrations)
                try { if (entry.Session.IsFocused) entry.Session.SetFocused(false); }
                catch (NativeError) { }
        Reconcile();
    }

    private void CancelOperation()
    {
        operationCancel?.Cancel();
    }

    public void Stop()
    {
        stopped = true;
        clipboard.Changed -= changed;
        pendingRemote = null;
        pollRequested = false;
        CancelOperation();
        active = null;
        foreach (var entry in registrations) entry.Session.PropertyChanged -= entry.Handler;
        registrations.Clear();
    }

    /// <summary>An executing clipboard call cannot be interrupted; close waits for it and discards its result.</summary>
    public async Task CloseAsync()
    {
        Stop();
        await Operation;
    }

    public void Dispose() => Stop();

    private void ScheduleReconciliation()
    {
        if (stopped || reconciliationQueued) return;
        reconciliationQueued = true;
        // Coalesce focus/state changes into one reconciliation on the next turn.
        dispatcher.TryEnqueue(() =>
        {
            reconciliationQueued = false;
            Reconcile();
        });
    }

    private void RoutingChanged()
    {
        // Final-state equality is not proof that pending work still belongs to the same focus interval.
        epoch++;
        pendingRemote = null;
        pollRequested = false;
        CancelOperation();
        observedChange = null;
        ScheduleReconciliation();
    }

    private bool Eligible(NativeSession session)
        => applicationActive && !stopped && session.IsFocused && !session.IsViewOnly && !session.IsClosing &&
           session.Snapshot.State == NativeSessionState.Connected;

    private void Reconcile()
    {
        if (stopped) return;
        var candidates = registrations.Select(r => r.Session).Where(Eligible).ToList();
        // Ambiguous focus never routes clipboard data to an arbitrary session.
        var selected = candidates.Count == 1 ? candidates[0] : null;
        var enabled = selected?.ClipboardSendEnabled == true;
        if (!ReferenceEquals(active, selected) || sendEnabled != enabled)
        {
            active = selected;
            sendEnabled = enabled;
            epoch++;
            observedChange = null;
            pendingRemote = null;
            pollRequested = false;
            CancelOperation();
        }
        PollCurrent();
    }

    /// <summary>A clipboard change notification (or a test's explicit check).</summary>
    public void Poll()
    {
        if (dispatcher.HasThreadAccess) Reconcile();
    }

    /// <summary>App-originated copies (e.g. redacted diagnostics); routing then treats them like any local copy.</summary>
    public async Task CopyLocalAsync(string text)
    {
        UiThread.Require(dispatcher);
        if (stopped) throw new NativeClipboardAccessException(NativeClipboardAccessError.Closed);
        await clipboard.WriteLocalAsync(text, 1 << 20);
        Reconcile();
    }

    private void PollCurrent()
    {
        if (active is not { } session || !Eligible(session) || !sendEnabled) return;
        pollRequested = true;
        StartPending();
    }

    private bool Current(NativeSession session, ulong generation, ulong ticket, CancellationToken token)
        => !token.IsCancellationRequested && ReferenceEquals(active, session) && Eligible(session) && sendEnabled &&
           epoch == ticket && generation == session.Generation;

    private void StartPending()
    {
        // One operation owns all clipboard access; polls collapse to a flag and remote updates to the latest value.
        if (stopped || operation is not null || (pendingRemote is null && !pollRequested)) return;
        var cancel = new CancellationTokenSource();
        operationCancel = cancel;
        operation = Run();

        async Task Run()
        {
            try
            {
                await Task.Yield();
                // Cancelled before it began: leave the pending work to a fresh operation.
                if (cancel.IsCancellationRequested) return;
                if (pendingRemote is { } remote)
                {
                    pendingRemote = null;
                    await WriteRemote(remote, cancel.Token);
                }
                else
                {
                    pollRequested = false;
                    if (active is { } session) await ReadLocal(session, session.Generation, epoch, cancel.Token);
                }
            }
            finally
            {
                if (ReferenceEquals(operationCancel, cancel)) operationCancel = null;
                cancel.Dispose();
                operation = null;
                StartPending();
            }
        }
    }

    private static bool Quiet(Exception error)
        => error is NativeError { Status: NativeStatus.Stale or NativeStatus.NotConnected or NativeStatus.Closing or NativeStatus.Unfocused
                                  or NativeStatus.ViewOnly or NativeStatus.Disabled or NativeStatus.Echo }
           || error is NativeCommandFailure { Result: NativeCommandFailure.ResultKind.Cancelled };

    private async Task ReadLocal(NativeSession session, ulong generation, ulong ticket, CancellationToken token)
    {
        if (!Current(session, generation, ticket, token)) return;
        uint? sampled = null;
        try
        {
            var change = await clipboard.CurrentChangeAsync();
            if (!Current(session, generation, ticket, token) || observedChange == change) return;
            sampled = change;
            var content = await clipboard.ReadAsync(change, MaximumBytes);
            if (!Current(session, generation, ticket, token)) return;
            var latest = await clipboard.CurrentChangeAsync();
            if (!Current(session, generation, ticket, token)) return;
            if (latest != change) { pollRequested = true; return; }
            observedChange = change;
            if (content is { Kind: NativeClipboardContentKind.Text, Text: { } text })
            {
                await session.OfferClipboardAsync(text, changeId: change, expectedGeneration: generation);
                if (Current(session, generation, ticket, token)) Report(session, null);
            }
            else await session.ClearClipboardAsync(generation);
        }
        catch (NativeClipboardAccessException error) when (error.Error == NativeClipboardAccessError.Changed)
        {
            // Retried on the next change rather than spinning against an unstable owner.
        }
        catch (Exception error) when (Quiet(error)) { }
        catch (Exception error) when (error is NativeClipboardAccessException or NativeError or NativeCommandFailure)
        {
            if (!Current(session, generation, ticket, token)) return;
            // A failure from an obsolete snapshot must not clear a newer offer or report on another connection.
            if (sampled is not { } change) return;
            uint latest;
            try { latest = await clipboard.CurrentChangeAsync(); }
            catch (NativeClipboardAccessException) { return; }
            if (latest != change || !Current(session, generation, ticket, token)) return;
            observedChange = change;
            if (error is NativeClipboardAccessException)
            {
                Report(session, NativeClipboardNotice.LocalNotSent);
                try { await session.ClearClipboardAsync(generation); }
                catch (Exception clear) when (clear is NativeError or NativeCommandFailure) { }
            }
            else Report(session, NativeClipboardNotice.TransferFailed);
        }
    }

    private void Receive(NativeClipboardUpdate update, NativeSession session)
    {
        if (stopped) return;
        var candidates = registrations.Select(r => r.Session).Where(Eligible).ToList();
        if (candidates.Count != 1 || !ReferenceEquals(candidates[0], session)) return;
        if (update.Kind == NativeClipboardUpdate.UpdateKind.Rejected) { Report(session, NativeClipboardNotice.RemoteRejected); return; }
        if (update.Kind != NativeClipboardUpdate.UpdateKind.Text || update.Text is null) return;
        try { session.ValidateClipboard(update.Route, sending: false); }
        catch (NativeError) { return; }
        // Settle routing first, so a queued reconciliation for this same focus
        // change cannot discard text that arrived just before it ran.
        if (!ReferenceEquals(active, session)) Reconcile();
        epoch++;
        CancelOperation();
        pollRequested = false;
        pendingRemote = new RemoteJob(session, update, epoch);
        StartPending();
    }

    private async Task WriteRemote(RemoteJob job, CancellationToken token)
    {
        var session = job.Session;
        if (stopped || token.IsCancellationRequested || epoch != job.Epoch || !Eligible(session) || job.Update.Text is not { } text) return;
        try
        {
            session.ValidateClipboard(job.Update.Route, sending: false);
            var change = await clipboard.WriteRemoteAsync(text.Text, job.Update.Route.SessionIdentity, job.Update.Route.Generation, MaximumBytes);
            if (stopped || token.IsCancellationRequested || epoch != job.Epoch || !Eligible(session)) return;
            session.ValidateClipboard(job.Update.Route, sending: false);
            observedChange = change;
            Report(session, null);
        }
        catch (NativeClipboardAccessException error) when (error.Error == NativeClipboardAccessError.Changed) { observedChange = null; }
        catch (NativeError error) when (Quiet(error)) { }
        catch (Exception error) when (error is NativeClipboardAccessException or NativeError)
        {
            if (!stopped && !token.IsCancellationRequested && epoch == job.Epoch && Eligible(session)) Report(session, NativeClipboardNotice.RemoteNotWritten);
        }
    }

    private void Report(NativeSession session, NativeClipboardNotice? notice)
        => registrations.FirstOrDefault(r => ReferenceEquals(r.Session, session))?.Report(notice);
}
