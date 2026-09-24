// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
namespace TidyVNC.Native.Storage;

/// <summary>
/// Profile and history operations on profiles-history.json (the macOS
/// NativeProfileHistoryStore mutations). Each one reads, checks the caller's
/// revision, changes the record and commits against that revision, so a
/// concurrent writer in this or another process is a Conflict, never a lost
/// update. Recording, removing or clearing history marks it as native.
/// </summary>
public static class NativeProfileHistoryOperations
{
    public static async Task<NativeConnectionProfile> ProfileAsync(this NativeProfileHistoryStore store, Guid id, CancellationToken cancellation = default)
    {
        var snapshot = await store.ReadAsync(cancellation).ConfigureAwait(false);
        return snapshot.Value.Profiles.FirstOrDefault(p => p.Id == id) ?? throw new NativeStorageException(NativeStorageError.NotFound);
    }

    public static Task<NativeRecordSnapshot<NativeProfileHistory>> UpsertProfileAsync(this NativeProfileHistoryStore store, NativeConnectionProfile profile,
                                                                                      Guid? expected, CancellationToken cancellation = default)
    {
        if (profile.Name.Trim().Length == 0 || profile.Name.Contains('\0', StringComparison.Ordinal) || System.Text.Encoding.UTF8.GetByteCount(profile.Name) > 256)
            throw new NativeStorageException(NativeStorageError.Invalid);
        Validate(profile.Destination, allowEmpty: true);
        return store.MutateAsync(expected, initializesHistory: false, value =>
        {
            var existing = value.Profiles.FirstOrDefault(p => p.Id == profile.Id);
            var profiles = existing is not null ? value.Profiles.Replace(existing, profile) : value.Profiles.Add(profile);
            if (profiles.Length > NativeProfileHistoryStore.ProfileCapacity) throw new NativeStorageException(NativeStorageError.ResourceLimit);
            return value with { Profiles = profiles };
        }, cancellation);
    }

    public static Task<NativeRecordSnapshot<NativeProfileHistory>> DeleteProfileAsync(this NativeProfileHistoryStore store, Guid id, Guid? expected,
                                                                                      CancellationToken cancellation = default)
        => store.MutateAsync(expected, initializesHistory: false, value =>
        {
            var profile = value.Profiles.FirstOrDefault(p => p.Id == id) ?? throw new NativeStorageException(NativeStorageError.NotFound);
            return value with { Profiles = value.Profiles.Remove(profile) };
        }, cancellation);

    /// <summary>Moves (or adds) the destination to the front, keeping the latest 20.</summary>
    public static Task<NativeRecordSnapshot<NativeProfileHistory>> RecordRecentAsync(this NativeProfileHistoryStore store, NativeConnectionDestination destination,
                                                                                     Guid? expected, CancellationToken cancellation = default)
    {
        Validate(destination, allowEmpty: false);
        return store.MutateAsync(expected, initializesHistory: true, value => value with
        {
            RecentConnections = [destination, .. value.RecentConnections.Where(d => !d.Equals(destination)).Take(NativeProfileHistoryStore.HistoryCapacity - 1)],
        }, cancellation);
    }

    public static Task<NativeRecordSnapshot<NativeProfileHistory>> RemoveRecentAsync(this NativeProfileHistoryStore store, NativeConnectionDestination destination,
                                                                                     Guid? expected, CancellationToken cancellation = default)
        => store.MutateAsync(expected, initializesHistory: true, value => value.RecentConnections.Contains(destination)
            ? value with { RecentConnections = value.RecentConnections.Remove(destination) }
            : throw new NativeStorageException(NativeStorageError.NotFound), cancellation);

    public static Task<NativeRecordSnapshot<NativeProfileHistory>> ClearHistoryAsync(this NativeProfileHistoryStore store, Guid? expected,
                                                                                     CancellationToken cancellation = default)
        => store.MutateAsync(expected, initializesHistory: true, value => value with { RecentConnections = [] }, cancellation);

    /// <summary>Storage admission for an address and gateway; the connection flow still parses the address itself.</summary>
    private static void Validate(NativeConnectionDestination destination, bool allowEmpty)
    {
        var endpoint = destination.Endpoint;
        if (endpoint.Length == 0 ? !allowEmpty : NativeEndpoint.Issue(endpoint) is not null)
            throw new NativeStorageException(NativeStorageError.Invalid);
        if (destination.SshGateway is not null && endpoint.Length != 0 && !NativeSessionSetup.IsTunnelTarget(endpoint))
            throw new NativeStorageException(NativeStorageError.Invalid);
    }

    /// <summary>
    /// Starts native history once (F13-F14): with the imported registry
    /// entries, or empty when the import was skipped. Refused (Conflict) once
    /// history has been initialized or used.
    /// </summary>
    public static Task<NativeRecordSnapshot<NativeProfileHistory>> ImportHistoryAsync(this NativeProfileHistoryStore store,
        IReadOnlyList<NativeConnectionDestination> imported, bool fromRegistry, Guid? expected, CancellationToken cancellation = default)
    {
        foreach (var destination in imported) Validate(destination, allowEmpty: false);
        if (imported.Count > NativeProfileHistoryStore.HistoryCapacity) throw new NativeStorageException(NativeStorageError.ResourceLimit);
        return store.MutateAsync(expected, initializesHistory: false, value =>
        {
            if (!value.CanImportHistory) throw new NativeStorageException(NativeStorageError.Conflict);
            return value with
            {
                RecentConnections = [.. imported],
                HistoryState = fromRegistry ? NativeHistoryState.Registry : NativeHistoryState.Native,
            };
        }, cancellation);
    }

    private static async Task<NativeRecordSnapshot<NativeProfileHistory>> MutateAsync(this NativeProfileHistoryStore store, Guid? expected, bool initializesHistory,
                                                                                     Func<NativeProfileHistory, NativeProfileHistory> change, CancellationToken cancellation)
    {
        var current = await store.ReadAsync(cancellation).ConfigureAwait(false);
        if (current.Revision != expected) throw new NativeStorageException(NativeStorageError.Conflict);
        var value = change(current.Value);
        if (initializesHistory && value.HistoryState == NativeHistoryState.Uninitialized) value = value with { HistoryState = NativeHistoryState.Native };
        return await store.CommitAsync(value, expected, cancellation).ConfigureAwait(false);
    }
}
