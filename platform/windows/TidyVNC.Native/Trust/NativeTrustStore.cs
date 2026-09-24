// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text.Json;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native.Trust;

/// <summary>
/// The destination a trust decision applies to: the core's domain-separated
/// identity of the canonical endpoint and route (NativeTrustScope on macOS).
/// Labels are kept for the management window only; stored scopes are
/// rederived on load and never trusted as labels.
/// </summary>
public sealed class NativeTrustScope : IEquatable<NativeTrustScope>
{
    private NativeTrustScope(string id, string endpoint, string routeIdentity, NativeTrustKind kind)
    {
        Id = id; Endpoint = endpoint; RouteIdentity = routeIdentity; Kind = kind;
    }

    public string Id { get; }
    public string Endpoint { get; }
    public string RouteIdentity { get; }
    public NativeTrustKind Kind { get; }

    /// <summary>Throws <see cref="NativeIdentityFailure"/> for an empty, oversized or invalid endpoint.</summary>
    public static NativeTrustScope Create(string endpoint, string routeIdentity = "", NativeTrustKind kind = NativeTrustKind.Certificate)
    {
        if (endpoint.Length == 0) throw new NativeIdentityFailure(NativeIdentityFailure.Problem.InvalidEndpoint);
        return new(NativeIdentity.TrustScope(endpoint, routeIdentity, kind), endpoint, routeIdentity, kind);
    }

    public bool Equals(NativeTrustScope? other) => other is not null && string.Equals(Id, other.Id, StringComparison.Ordinal);
    public override bool Equals(object? obj) => Equals(obj as NativeTrustScope);
    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(Id);
    public override string ToString() => "NativeTrustScope(<redacted>)";
}

/// <summary>A saved decision; a null identity means forgotten (no fallback to a broader legacy exception).</summary>
public sealed class NativeSavedTrustEntry(NativeTrustScope scope, ImmutableArray<byte>? identity)
{
    public NativeTrustScope Scope { get; } = scope;
    public string Id => Scope.Id;
    public ImmutableArray<byte>? Identity { get; } = identity;
    public bool IsForgotten => Identity is null;
    public string? Fingerprint => Identity is { } key ? NativeTrustFingerprint.Of(key.AsSpan()) : null;
    public override string ToString() => "NativeSavedTrustEntry(<redacted>)";
}

public static class NativeTrustFingerprint
{
    /// <summary>SHA-256, upper-case hex pairs separated by colons (the dialog's and library's format).</summary>
    public static string Of(ReadOnlySpan<byte> bytes)
        => string.Join(':', SHA256.HashData(bytes).ToArray().Select(b => b.ToString("X2", System.Globalization.CultureInfo.InvariantCulture)));
}

public enum NativeSavedTrustState { Absent, Forgotten, Match, Changed }

public sealed record NativeSavedTrustInspection(NativeSavedTrustState State, Guid? Revision, string? SavedFingerprint, string ReceivedFingerprint)
{
    public override string ToString() => $"NativeSavedTrustInspection({State}, <redacted>)";
}

public sealed record NativeSavedTrustSnapshot(Guid? Revision, ImmutableArray<NativeSavedTrustEntry> Entries);

/// <summary>
/// trust\certificates.json (X.509 SPKI decisions) or trust\server-keys.json
/// (RSA-AES server keys): destination-scoped accept/forget decisions with the
/// macOS NativeTrustStore's kinds, capacity and matching rules (SERVICES.md
/// section 5), on the shared record store (schema 1, revision, lock, atomic
/// replace, owner-only DACL). No certificate ever enters a Windows store.
/// </summary>
public sealed class NativeTrustStore : NativeRecordStore<ImmutableArray<NativeSavedTrustEntry>>
{
    public const int Capacity = 256;
    public const int MaximumIdentityBytes = 65536;

    public NativeTrustStore(NativeTrustKind kind, string stateDirectory)
        : base(System.IO.Path.Combine(stateDirectory, "trust"), kind == NativeTrustKind.Certificate ? "certificates.json" : "server-keys.json")
    {
        Kind = kind;
    }

    public NativeTrustStore(NativeTrustKind kind) : this(kind, NativeStateRoot.Directory) { }

    public NativeTrustKind Kind { get; }
    private string KindName => Kind == NativeTrustKind.Certificate ? "x509-spki" : "rsa-aes";
    private string IdentityField => Kind == NativeTrustKind.Certificate ? "spki" : "hostKey";

    protected override int Schema => 1;
    protected override ImmutableArray<NativeSavedTrustEntry> Empty => [];

    protected override ImmutableArray<NativeSavedTrustEntry> Decode(JsonElement record, int schema)
    {
        RequireOnly(record, "kind", "entries");
        if (!record.TryGetProperty("kind", out var kind) || kind.ValueKind != JsonValueKind.String) throw Corrupt();
        if (kind.GetString() != KindName) throw new NativeStorageException(NativeStorageError.UnsupportedFields);
        if (!record.TryGetProperty("entries", out var list) || list.ValueKind != JsonValueKind.Array) throw Corrupt();
        if (list.GetArrayLength() > Capacity) throw new NativeStorageException(NativeStorageError.ResourceLimit);
        var entries = ImmutableArray.CreateBuilder<NativeSavedTrustEntry>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in list.EnumerateArray())
        {
            RequireOnly(item, "scope", "endpoint", "route", "decision", IdentityField);
            string Text(string name) => item.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()! : throw Corrupt();
            NativeTrustScope scope;
            try { scope = NativeTrustScope.Create(Text("endpoint"), Text("route"), Kind); }
            catch (NativeIdentityFailure) { throw Corrupt(); }
            if (scope.Id != Text("scope") || !seen.Add(scope.Id)) throw Corrupt();
            var decision = Text("decision");
            ImmutableArray<byte>? identity = null;
            if (decision == "accept")
            {
                if (!item.TryGetProperty(IdentityField, out var encoded) || encoded.ValueKind != JsonValueKind.String) throw Corrupt();
                var bytes = encoded.GetBytesFromBase64();
                if (bytes.Length is 0 or > MaximumIdentityBytes || Convert.ToBase64String(bytes) != encoded.GetString()) throw Corrupt();
                if (Kind == NativeTrustKind.HostKey) ValidHostKey(bytes, NativeStorageError.Corrupt);
                identity = [.. bytes];
            }
            else if (decision == "forget")
            {
                if (item.TryGetProperty(IdentityField, out _)) throw Corrupt();
            }
            else throw new NativeStorageException(NativeStorageError.UnsupportedFields);
            entries.Add(new NativeSavedTrustEntry(scope, identity));
        }
        return entries.ToImmutable();
    }

    protected override void Encode(Utf8JsonWriter writer, ImmutableArray<NativeSavedTrustEntry> value)
    {
        if (value.Length > Capacity) throw new NativeStorageException(NativeStorageError.ResourceLimit);
        writer.WriteString("kind", KindName);
        writer.WriteStartArray("entries");
        foreach (var entry in value)
        {
            writer.WriteStartObject();
            writer.WriteString("scope", entry.Scope.Id);
            writer.WriteString("endpoint", entry.Scope.Endpoint);
            writer.WriteString("route", entry.Scope.RouteIdentity);
            writer.WriteString("decision", entry.IsForgotten ? "forget" : "accept");
            if (entry.Identity is { } identity) writer.WriteBase64String(IdentityField, identity.AsSpan());
            writer.WriteEndObject();
        }
        writer.WriteEndArray();
    }

    private static void ValidHostKey(byte[] key, NativeStorageError failure)
    {
        try { _ = new NativeHostKey(key); }
        catch (Exception error) when (error is NativeError or ArgumentException) { throw new NativeStorageException(failure); }
    }

    private void RequireKind(NativeTrustScope scope, NativeTrustKind kind)
    {
        if (Kind != kind || scope.Kind != Kind) throw new NativeStorageException(NativeStorageError.UnsupportedFields);
    }

    private static byte[] Spki(ReadOnlySpan<byte> certificate)
    {
        if (certificate.IsEmpty || certificate.Length > MaximumIdentityBytes) throw new NativeStorageException(NativeStorageError.Corrupt);
        try
        {
            using var key = new NativeCertificateKey(certificate);
            return key.Spki.Length is > 0 and <= MaximumIdentityBytes ? key.Spki : throw new NativeStorageException(NativeStorageError.Corrupt);
        }
        catch (NativeError) { throw new NativeStorageException(NativeStorageError.Corrupt); }
    }

    public async Task<NativeSavedTrustSnapshot> ReadSnapshotAsync(CancellationToken cancellation = default)
    {
        var snapshot = await ReadAsync(cancellation).ConfigureAwait(false);
        return new(snapshot.Revision, snapshot.Value);
    }

    /// <summary>Compares the presented certificate's SPKI with the saved decision for this destination.</summary>
    public async Task<NativeSavedTrustInspection> InspectAsync(NativeTrustScope scope, byte[] certificate, CancellationToken cancellation = default)
    {
        RequireKind(scope, NativeTrustKind.Certificate);
        return await Inspect(scope, Spki(certificate), cancellation).ConfigureAwait(false);
    }

    public async Task<NativeSavedTrustInspection> InspectHostKeyAsync(NativeTrustScope scope, byte[] key, CancellationToken cancellation = default)
    {
        RequireKind(scope, NativeTrustKind.HostKey);
        ValidHostKey(key, NativeStorageError.Corrupt);
        return await Inspect(scope, key, cancellation).ConfigureAwait(false);
    }

    private async Task<NativeSavedTrustInspection> Inspect(NativeTrustScope scope, byte[] identity, CancellationToken cancellation)
    {
        var snapshot = await ReadAsync(cancellation).ConfigureAwait(false);
        var entry = snapshot.Value.FirstOrDefault(e => e.Scope.Equals(scope));
        var state = entry is null ? NativeSavedTrustState.Absent
            : entry.Identity is not { } saved ? NativeSavedTrustState.Forgotten
            : saved.AsSpan().SequenceEqual(identity) ? NativeSavedTrustState.Match : NativeSavedTrustState.Changed;
        return new(state, snapshot.Revision, entry?.Fingerprint, NativeTrustFingerprint.Of(identity));
    }

    /// <summary>
    /// Saves an exception for a certificate whose verification status may be
    /// overridden. replacing states that the caller showed a changed key;
    /// it must agree with the record or the result is a Conflict.
    /// </summary>
    public Task<NativeSavedTrustSnapshot> SaveAsync(NativeTrustScope scope, byte[] certificate, uint status, bool replacing, Guid? expected,
                                                    CancellationToken cancellation = default)
    {
        RequireKind(scope, NativeTrustKind.Certificate);
        if (!NativeCertificatePolicy.For(status).MayOverride) throw new NativeStorageException(NativeStorageError.Denied);
        return Mutate(scope, [.. Spki(certificate)], replacing, expected, cancellation);
    }

    public Task<NativeSavedTrustSnapshot> SaveHostKeyAsync(NativeTrustScope scope, byte[] key, bool replacing, Guid? expected,
                                                           CancellationToken cancellation = default)
    {
        RequireKind(scope, NativeTrustKind.HostKey);
        ValidHostKey(key, NativeStorageError.UnsupportedFields);
        return Mutate(scope, [.. key], replacing, expected, cancellation);
    }

    /// <summary>Records a forget decision, which also suppresses the legacy fallback for this destination.</summary>
    public Task<NativeSavedTrustSnapshot> ForgetAsync(NativeTrustScope scope, Guid? expected, CancellationToken cancellation = default)
    {
        RequireKind(scope, Kind);
        return Mutate(scope, null, false, expected, cancellation);
    }

    private async Task<NativeSavedTrustSnapshot> Mutate(NativeTrustScope scope, ImmutableArray<byte>? identity, bool replacing, Guid? expected,
                                                        CancellationToken cancellation)
    {
        var current = await ReadAsync(cancellation).ConfigureAwait(false);
        if (current.Revision != expected) throw new NativeStorageException(NativeStorageError.Conflict);
        var index = -1;
        for (var i = 0; i < current.Value.Length && index < 0; i++)
            if (current.Value[i].Scope.Equals(scope)) index = i;
        var hasKey = index >= 0 && !current.Value[index].IsForgotten;
        if (identity is not null && replacing != hasKey) throw new NativeStorageException(NativeStorageError.Conflict);
        var entry = new NativeSavedTrustEntry(scope, identity);
        var entries = index >= 0 ? current.Value.SetItem(index, entry) : current.Value.Add(entry);
        if (entries.Length > Capacity) throw new NativeStorageException(NativeStorageError.ResourceLimit);
        var committed = await CommitAsync(entries, expected, cancellation).ConfigureAwait(false);
        return new(committed.Revision, committed.Value);
    }
}
