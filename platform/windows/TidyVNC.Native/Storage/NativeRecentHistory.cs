// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Immutable;
using CommunityToolkit.Mvvm.ComponentModel;

namespace TidyVNC.Native.Storage;

/// <summary>
/// The app-wide recent connections owner (NativeRecentHistory.swift). A
/// successful connection only enqueues its destination; store IO runs one
/// operation at a time off the connection path. A failed record keeps the
/// destination pending (the latest 20) without an automatic retry loop.
/// UI thread only.
/// </summary>
public sealed partial class NativeRecentHistory(IUiDispatcher dispatcher, NativeProfileHistoryStore store) : ObservableObject
{
    private abstract record Request;
    private sealed record ReadRequest : Request;
    private sealed record RecordRequest(NativeConnectionDestination Destination) : Request;
    private sealed record RemoveRequest(NativeConnectionDestination Destination, Guid? Revision) : Request;
    private sealed record ClearRequest(Guid? Revision) : Request;

    private readonly List<NativeConnectionDestination> pending = []; // Oldest first.
    private Guid? revision;
    private Task? operation;
    private bool refreshPending, stopped, importEligible;

    [ObservableProperty] public partial ImmutableArray<NativeConnectionDestination> Connections { get; private set; } = [];
    [ObservableProperty] public partial bool IsBusy { get; private set; }
    [ObservableProperty] public partial NativeStorageError? Error { get; private set; }
    [ObservableProperty] public partial bool HasLoaded { get; private set; }
    [ObservableProperty] public partial bool ImportOfferDismissed { get; private set; }

    public bool CanEdit => !stopped && !IsBusy && HasLoaded && Error is null;
    /// <summary>History has never been written and holds nothing: the first-use import offer applies.</summary>
    public bool CanImportHistory => CanEdit && importEligible;

    public void DismissImportOffer() => ImportOfferDismissed = true;

    public void Reload()
    {
        UiThread.Require(dispatcher);
        if (stopped) return;
        if (operation is not null) { refreshPending = true; return; }
        Begin(new ReadRequest());
    }

    public void RecordSuccessful(NativeConnectionDestination destination)
    {
        UiThread.Require(dispatcher);
        if (stopped) return;
        if (destination.Endpoint.Length == 0 || destination.Endpoint.Contains('\0', StringComparison.Ordinal) ||
            System.Text.Encoding.UTF8.GetByteCount(destination.Endpoint) > 4096)
        {
            Error = NativeStorageError.Invalid;
            return;
        }
        pending.Remove(destination);
        pending.Add(destination);
        if (pending.Count > NativeProfileHistoryStore.HistoryCapacity) pending.RemoveRange(0, pending.Count - NativeProfileHistoryStore.HistoryCapacity);
        Advance();
    }

    public void Remove(NativeConnectionDestination destination)
    {
        UiThread.Require(dispatcher);
        if (!CanEdit || !Connections.Contains(destination)) return;
        Begin(new RemoveRequest(destination, revision));
    }

    public void Clear()
    {
        UiThread.Require(dispatcher);
        if (!CanEdit || Connections.IsEmpty) return;
        Begin(new ClearRequest(revision));
    }

    private void Advance()
    {
        if (stopped || operation is not null || Error is not null) return;
        if (pending.Count != 0)
        {
            var next = pending[0];
            pending.RemoveAt(0);
            Begin(new RecordRequest(next));
        }
        else if (refreshPending)
        {
            refreshPending = false;
            Begin(new ReadRequest());
        }
    }

    private void Begin(Request request)
    {
        IsBusy = true; Error = null;
        OnPropertyChanged(nameof(CanEdit));
        operation = RunAsync(request);
    }

    private async Task RunAsync(Request request)
    {
        try
        {
            var snapshot = request switch
            {
                RecordRequest record => await Record(record.Destination),
                RemoveRequest remove => await store.RemoveRecentAsync(remove.Destination, remove.Revision),
                ClearRequest clear => await store.ClearHistoryAsync(clear.Revision),
                _ => await store.ReadAsync(),
            };
            if (!stopped)
            {
                revision = snapshot.Revision;
                Connections = snapshot.Value.RecentConnections;
                HasLoaded = true;
                importEligible = snapshot.Value.CanImportHistory;
            }
        }
        catch (NativeStorageException error)
        {
            if (!stopped)
            {
                importEligible = false;
                Error = error.Error;
                refreshPending = false; // No automatic retry loop after a failure.
                if (request is RecordRequest record && !pending.Contains(record.Destination))
                {
                    pending.Insert(0, record.Destination);
                    if (pending.Count > NativeProfileHistoryStore.HistoryCapacity) pending.RemoveAt(pending.Count - 1);
                }
                if (request is ReadRequest) { HasLoaded = false; Connections = []; revision = null; }
            }
        }
        operation = null;
        IsBusy = false;
        OnPropertyChanged(nameof(CanEdit));
        OnPropertyChanged(nameof(CanImportHistory));
        Advance();
    }

    private async Task<NativeRecordSnapshot<NativeProfileHistory>> Record(NativeConnectionDestination destination)
    {
        var current = await store.ReadAsync();
        return await store.RecordRecentAsync(destination, current.Revision);
    }

    public void Stop()
    {
        if (stopped) return;
        stopped = true; importEligible = false; pending.Clear(); refreshPending = false;
    }

    public async Task CloseAsync()
    {
        Stop();
        if (operation is { } running) await running;
    }
}
