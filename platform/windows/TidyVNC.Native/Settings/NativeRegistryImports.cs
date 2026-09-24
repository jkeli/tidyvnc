// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Immutable;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.Win32;
using TidyVNC.Native.Platform;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native;

public enum NativeImportIssue
{
    /// <summary>The registry source could not be read or is not representable.</summary>
    SourceUnreadable,
    /// <summary>The native record changed since the review; nothing was replaced.</summary>
    Changed,
    /// <summary>The native record could not be read (corrupt, newer schema) or accessed.</summary>
    Unavailable,
    /// <summary>The write could not be confirmed.</summary>
    Failed,
    /// <summary>Omitted or converted settings must be acknowledged before importing.</summary>
    AcknowledgementRequired,
}

/// <summary>An imported monitor number and the connected display it was mapped to (null: none, so omitted).</summary>
public sealed record NativeImportedMonitor(int Number, string? Display);

/// <summary>A defaults import ready for approval: exactly what will be written.</summary>
public sealed record NativeDefaultsImportReview(
    Guid Id, NativeRegistrySource Source, NativeSettings Settings, IReadOnlyList<NativeImportAssignment> Imported,
    IReadOnlyList<NativeImportNotice> Notices, IReadOnlyList<string> Skipped, IReadOnlyList<NativeImportedMonitor> Monitors,
    bool ReplacesExisting, Guid? Revision)
{
    /// <summary>Omitted, unknown or converted values need an explicit acknowledgement (macOS review rules).</summary>
    public bool NeedsAcknowledgement => Notices.Count > 0 || Skipped.Count > 0 || Monitors.Count > 0;
}

/// <summary>
/// Import connection defaults from the FLTK viewer's registry (macOS
/// NativeDefaultsImportState; PARITY F09-F12): choose TidyVNC or TigerVNC
/// settings, review the core's import projection with omitted and converted
/// values acknowledged, and write preferences.json marked as imported from
/// the registry, against the revision that was read. The registry is never
/// written. UI thread only.
/// </summary>
public sealed partial class NativeDefaultsImport : ObservableObject
{
    private readonly NativePreferencesStore store;
    private readonly Func<NativeDisplaySnapshot> displays;
    private readonly RegistryKey? root;
    private Task? operation;
    private bool stopped;

    [ObservableProperty] public partial IReadOnlyList<NativeRegistryImportSource> Sources { get; private set; } = [];
    [ObservableProperty] public partial NativeDefaultsImportReview? Review { get; private set; }
    [ObservableProperty] public partial bool IsBusy { get; private set; }
    [ObservableProperty] public partial NativeImportIssue? Issue { get; private set; }
    [ObservableProperty] public partial bool Imported { get; private set; }

    /// <param name="root">The registry root (tests and isolated state roots use their own); null is the user's.</param>
    public NativeDefaultsImport(NativePreferencesStore store, Func<NativeDisplaySnapshot> displays, RegistryKey? root = null)
    {
        this.store = store; this.displays = displays; this.root = root;
        Refresh();
    }

    public void Refresh()
    {
        try { Sources = [.. NativeRegistryImport.Available(root).Where(s => s.HasDefaults)]; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { Sources = []; }
    }

    public void Begin(NativeRegistrySource source)
    {
        if (stopped || IsBusy) return;
        IsBusy = true; Issue = null; Imported = false; Review = null;
        operation = Prepare(source);
    }

    private async Task Prepare(NativeRegistrySource source)
    {
        try
        {
            var saved = await store.ReadAsync();
            if (stopped) return;
            NativeRegistryDefaults? defaults;
            try { defaults = NativeRegistryImport.Defaults(source, root); }
            catch (Exception error) when (error is NativeImportFailure or IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                Issue = NativeImportIssue.SourceUnreadable;
                return;
            }
            if (defaults is null) { Issue = NativeImportIssue.SourceUnreadable; return; }
            Review = Build(source, defaults, saved);
        }
        catch (NativeStorageException) { if (!stopped) Issue = NativeImportIssue.Unavailable; }
        catch (Exception error) when (error is ArgumentException or NativeConfigFailure or NativeError)
        {
            if (!stopped) Issue = NativeImportIssue.SourceUnreadable;
        }
        finally
        {
            IsBusy = false; operation = null;
        }
    }

    private NativeDefaultsImportReview Build(NativeRegistrySource source, NativeRegistryDefaults defaults, NativeRecordSnapshot<NativePreferencesRecord> saved)
    {
        var parameters = new Dictionary<string, string>(StringComparer.Ordinal);
        var imported = new List<NativeImportAssignment>();
        var notices = defaults.Projection.Notices.ToList();
        var monitors = new List<NativeImportedMonitor>();
        foreach (var assignment in defaults.Projection.Assignments)
        {
            if (assignment.Name == "FullScreenSelectedMonitors")
            {
                // Monitor numbers become stable display IDs through the retained numbering of the connected displays.
                var legacy = NativeSessionDefaults.DisplaysOf(displays()).Legacy;
                foreach (var item in assignment.Value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                    if (int.TryParse(item, NumberStyles.None, CultureInfo.InvariantCulture, out var number) && number >= 1)
                        monitors.Add(new NativeImportedMonitor(number, number <= legacy.Count ? legacy[number - 1] : null));
                continue;
            }
            if (!NativeSettings.Allowed.Contains(assignment.Name))
            {
                notices.Add(new NativeImportNotice(assignment.Line, assignment.Name, NativeImportNoticeKind.PlatformOnly));
                continue;
            }
            parameters[assignment.Name] = assignment.Value;
            imported.Add(assignment);
        }
        var selected = monitors.Where(m => m.Display is not null).Select(m => m.Display!).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal);
        var settings = NativeSettings.Create(parameters, selected);
        return new NativeDefaultsImportReview(Guid.NewGuid(), source, settings, imported, notices, defaults.SkippedValues, monitors,
            saved.IsStored, saved.Revision);
    }

    /// <summary>Writes exactly the reviewed settings; a review with omissions needs them acknowledged.</summary>
    public void Approve(Guid id, bool acknowledged)
    {
        if (stopped || IsBusy || Review is not { } review || review.Id != id) return;
        if (review.NeedsAcknowledgement && !acknowledged) { Issue = NativeImportIssue.AcknowledgementRequired; return; }
        IsBusy = true; Issue = null;
        operation = Commit(review);
    }

    private async Task Commit(NativeDefaultsImportReview review)
    {
        try
        {
            await store.CommitAsync(new NativePreferencesRecord(review.Settings, NativeImportOrigin.Registry), review.Revision);
            // A write that was accepted stays a success even if the window closed meanwhile.
            if (!stopped) { Imported = true; Review = null; }
        }
        catch (NativeStorageException error)
        {
            if (!stopped)
            {
                Review = null;
                Issue = error.Error switch
                {
                    NativeStorageError.Conflict => NativeImportIssue.Changed,
                    NativeStorageError.Corrupt or NativeStorageError.FutureSchema or NativeStorageError.UnsupportedFields or NativeStorageError.Denied
                        or NativeStorageError.Unavailable => NativeImportIssue.Unavailable,
                    _ => NativeImportIssue.Failed,
                };
            }
        }
        finally
        {
            IsBusy = false; operation = null;
        }
    }

    public void Cancel()
    {
        if (IsBusy) return;
        Review = null; Issue = null;
    }

    public async Task CloseAsync()
    {
        stopped = true;
        if (operation is { } running) await running;
    }
}

/// <summary>A history import ready for approval.</summary>
public sealed record NativeHistoryImportReview(Guid Id, NativeRegistrySource Source, IReadOnlyList<string> Endpoints, uint Duplicates,
                                               uint OmittedOlder, Guid? Revision);

/// <summary>
/// Import recent connections from the FLTK viewer's registry history (macOS
/// history import; PARITY F13-F14): offered only while native history has
/// never been used; Import or Skip marks it initialized so the offer does not
/// return. The registry is never written. UI thread only.
/// </summary>
public sealed partial class NativeHistoryImport : ObservableObject
{
    private readonly NativeProfileHistoryStore store;
    private readonly RegistryKey? root;
    private Task? operation;
    private bool stopped;

    [ObservableProperty] public partial IReadOnlyList<NativeRegistryImportSource> Sources { get; private set; } = [];
    [ObservableProperty] public partial NativeHistoryImportReview? Review { get; private set; }
    [ObservableProperty] public partial bool IsBusy { get; private set; }
    [ObservableProperty] public partial NativeImportIssue? Issue { get; private set; }
    [ObservableProperty] public partial bool Finished { get; private set; }

    public NativeHistoryImport(NativeProfileHistoryStore store, RegistryKey? root = null)
    {
        this.store = store; this.root = root;
        try { Sources = [.. NativeRegistryImport.Available(root).Where(s => s.HasHistory)]; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { Sources = []; }
    }

    public void Begin(NativeRegistrySource source)
    {
        if (stopped || IsBusy) return;
        IsBusy = true; Issue = null; Review = null; Finished = false;
        operation = Prepare(source);
    }

    private async Task Prepare(NativeRegistrySource source)
    {
        try
        {
            var saved = await store.ReadAsync();
            if (stopped) return;
            if (!saved.Value.CanImportHistory) { Issue = NativeImportIssue.Changed; return; }
            NativeHistoryProjection? projection;
            try { projection = NativeRegistryImport.History(source, root); }
            catch (Exception error) when (error is NativeImportFailure or IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                Issue = NativeImportIssue.SourceUnreadable;
                return;
            }
            if (projection is null) { Issue = NativeImportIssue.SourceUnreadable; return; }
            Review = new NativeHistoryImportReview(Guid.NewGuid(), source, projection.Endpoints, projection.Duplicates, projection.OmittedOlder, saved.Revision);
        }
        catch (NativeStorageException) { if (!stopped) Issue = NativeImportIssue.Unavailable; }
        finally
        {
            IsBusy = false; operation = null;
        }
    }

    /// <summary>Import the reviewed connections (newest first), or skip them; either way native history begins.</summary>
    public void Complete(Guid id, bool import)
    {
        if (stopped || IsBusy || Review is not { } review || review.Id != id) return;
        IsBusy = true; Issue = null;
        operation = Commit(review, import);
    }

    private async Task Commit(NativeHistoryImportReview review, bool import)
    {
        try
        {
            var destinations = import ? review.Endpoints.Select(e => new NativeConnectionDestination(e, null)).ToList() : [];
            await store.ImportHistoryAsync(destinations, fromRegistry: import, review.Revision);
            if (!stopped) { Finished = true; Review = null; }
        }
        catch (NativeStorageException error)
        {
            if (!stopped)
            {
                Review = null;
                Issue = error.Error == NativeStorageError.Conflict ? NativeImportIssue.Changed : NativeImportIssue.Failed;
            }
        }
        finally
        {
            IsBusy = false; operation = null;
        }
    }

    public void Cancel()
    {
        if (IsBusy) return;
        Review = null; Issue = null;
    }

    public async Task CloseAsync()
    {
        stopped = true;
        if (operation is { } running) await running;
    }
}
