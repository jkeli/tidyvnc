// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using CommunityToolkit.Mvvm.ComponentModel;
using TidyVNC.Native.Documents;
using TidyVNC.Native.Platform;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native;

public enum NativeSessionDefaultsPurpose { Connection, Listener }

/// <summary>
/// Settings approved for one new session, shareable by incoming windows
/// without rereading stores or files (macOS NativePreparedSessionDefaults).
/// No session, credential owner or restoration payload.
/// </summary>
public sealed record NativePreparedSessionDefaults(NativeSessionConfiguration Configuration, NativeSettings Inherited, NativeSessionSetup Setup);

/// <summary>A connection file awaiting review: its resolution and the displays it was resolved against.</summary>
public sealed record NativeDocumentReview(Guid Id, NativeSessionSetup Setup, NativeSetupDisplays Displays, IReadOnlyDictionary<int, string>? MonitorMapping);

/// <summary>Monitor numbers from the command line or a file that need a display each.</summary>
public sealed record NativeMonitorMappingRequest(Guid Id, NativeOptionSource Layer, IReadOnlyList<int> Numbers,
                                                 IReadOnlyDictionary<int, string> Suggested, NativeSetupDisplays Displays);

/// <summary>
/// One-time defaults loading for one new connection or listener window
/// (macOS NativeSessionDefaults): app defaults, the selected profile, the
/// launch command line and an explicit file are read once, reviewed where
/// needed and turned into one session. There is no subscription that could
/// change an existing connection after a later save. UI thread only.
/// </summary>
public sealed partial class NativeSessionDefaults : ObservableObject, IDisposable
{
    private readonly NativeRuntime runtime;
    private readonly NativePreferencesStore store;
    private readonly NativeProfileHistoryStore? profileStore;
    private readonly Guid? profileId;
    private readonly INativeDocumentReader documentReader;
    private readonly Func<NativeSetupDisplays> displays;
    private readonly NativeSessionDefaultsPurpose purpose;
    private readonly NativePreparedSessionDefaults? initialPreparation;
    private NativeDocumentLayer? documentLayer;
    private IReadOnlyDictionary<int, string>? chosenMapping;
    private Task? operation;
    private CancellationTokenSource? cancellation;
    private bool stopped;

    public NativeInvocationLayer? InvocationRequest { get; }
    public NativeDocumentOpenRequest? DocumentRequest { get; }

    [ObservableProperty] public partial bool IsReady { get; private set; }
    [ObservableProperty] public partial bool IsLoading { get; private set; }
    /// <summary>The app defaults could not be read; Use built-in defaults retries without them.</summary>
    [ObservableProperty] public partial NativeStorageError? Error { get; private set; }
    [ObservableProperty] public partial NativeStorageError? ProfileError { get; private set; }
    [ObservableProperty] public partial NativeSettings Inherited { get; private set; } = NativeSettings.Empty;
    [ObservableProperty] public partial NativeConnectionProfile? Profile { get; private set; }
    [ObservableProperty] public partial NativeSshGateway? SshGateway { get; private set; }
    [ObservableProperty] public partial NativeSessionSetup? Setup { get; private set; }
    [ObservableProperty] public partial NativePreparedSessionDefaults? Prepared { get; private set; }
    [ObservableProperty] public partial NativeDocumentReview? DocumentReview { get; private set; }
    [ObservableProperty] public partial NativeMonitorMappingRequest? MonitorMapping { get; private set; }
    /// <summary>Why the file (or its display mapping) cannot be used yet.</summary>
    [ObservableProperty] public partial NativeText? DocumentIssue { get; private set; }
    /// <summary>Why the command line cannot be applied.</summary>
    [ObservableProperty] public partial NativeText? InvocationIssue { get; private set; }
    /// <summary>Published last, after the address metadata above, so admission never sees a half-set window.</summary>
    [ObservableProperty] public partial NativeSession? Session { get; private set; }

    public NativeSessionDefaults(NativeRuntime runtime, NativePreferencesStore store, NativeProfileHistoryStore? profileStore = null, Guid? profileId = null,
                                 NativeInvocationLayer? invocation = null, NativeDocumentOpenRequest? document = null,
                                 INativeDocumentReader? documentReader = null, Func<NativeSetupDisplays>? displays = null,
                                 NativeSessionDefaultsPurpose purpose = NativeSessionDefaultsPurpose.Connection,
                                 NativePreparedSessionDefaults? prepared = null)
    {
        this.runtime = runtime; this.store = store; this.profileStore = profileStore; this.profileId = profileId;
        InvocationRequest = invocation; DocumentRequest = document;
        this.documentReader = documentReader ?? new NativeDocumentFileReader();
        this.displays = displays ?? (() => NativeSetupDisplays.None);
        this.purpose = purpose; initialPreparation = prepared;
    }

    /// <summary>The displays a resolution maps monitor numbers to: legacy order (x, then y) and every connected display.</summary>
    public static NativeSetupDisplays DisplaysOf(NativeDisplaySnapshot snapshot)
    {
        var available = snapshot.Displays.Select(d => d.Id).ToList();
        IReadOnlyList<string> legacy;
        try
        {
            var ordered = NativeMonitorNumbering.Order([.. snapshot.Displays.Select((d, i) => new NativeMonitorOrigin((uint)i, (int)d.Bounds.X, (int)d.Bounds.Y))]);
            legacy = [.. ordered.Select(i => snapshot.Displays[(int)i].Id)];
        }
        catch (Exception error) when (error is NativeMonitorNumberingFailure or NativeError)
        {
            legacy = []; // Mirrors and missing displays need an explicit mapping.
        }
        return new NativeSetupDisplays(legacy, available);
    }

    public void Load() => BeginLoad(useBuiltIns: false);

    /// <summary>After an app-defaults read failure: continue with built-in defaults (the profile must still be read).</summary>
    public void UseBuiltInDefaults()
    {
        if (!stopped && !IsLoading && !IsReady && Error is not null) BeginLoad(useBuiltIns: true);
    }

    private void BeginLoad(bool useBuiltIns)
    {
        UiThread.Require(runtime.Dispatcher);
        if (stopped || IsReady || operation is not null) return;
        IsLoading = true; Error = null; ProfileError = null; DocumentIssue = null; DocumentReview = null;
        InvocationIssue = null; MonitorMapping = null; documentLayer = null; chosenMapping = null;
        cancellation?.Dispose();
        cancellation = new CancellationTokenSource();
        operation = LoadAsync(useBuiltIns, cancellation.Token);
    }

    private async Task LoadAsync(bool useBuiltIns, CancellationToken token)
    {
        try
        {
            if (initialPreparation is { } ready)
            {
                Setup = ready.Setup;
                Install(ready.Inherited, null, ready.Configuration);
                return;
            }
            NativeSettings settings;
            try { settings = useBuiltIns ? NativeSettings.Empty : (await store.ReadAsync(token)).Value.Settings; }
            catch (NativeStorageException error) { if (!stopped) Error = error.Error; return; }
            NativeConnectionProfile? profile = null;
            if (profileId is { } id)
            {
                try
                {
                    if (profileStore is null) throw new NativeStorageException(NativeStorageError.Unavailable);
                    profile = await profileStore.ProfileAsync(id, token);
                }
                catch (NativeStorageException error) { if (!stopped) ProfileError = error.Error; return; }
            }
            if (stopped || token.IsCancellationRequested) return;
            Inherited = settings; Profile = profile;
            // The command line is checked before any file IO (its display mapping waits for the file).
            _ = InvocationRequest?.Assignments().ToList();
            if (DocumentRequest is { } request)
            {
                byte[] data;
                try { data = await documentReader.ReadAsync(request.Path, token); }
                catch (Exception error) when (error is NativeDocumentOpenException or OperationCanceledException)
                {
                    DocumentFailed(error);
                    return;
                }
                if (stopped || token.IsCancellationRequested) return;
                try
                {
                    using var document = new NativeConnectionDocument(data);
                    documentLayer = NativeDocumentLayer.Create(document, System.IO.Path.GetDirectoryName(request.Path) ?? "",
                        purpose == NativeSessionDefaultsPurpose.Listener ? NativeDocumentEndpointUse.ListenPort : NativeDocumentEndpointUse.Connection);
                }
                catch (Exception error) when (error is NativeDocumentFailure or NativeSetupFailure)
                {
                    DocumentFailed(error);
                    return;
                }
                ReviewDocument(null);
            }
            else Resolve(null);
        }
        catch (NativeSetupFailure failure) { if (!stopped) InvocationIssue = failure.Text; }
        catch (NativeStorageException error) { if (!stopped) Error = error.Error; }
        catch (OperationCanceledException) { }
        finally
        {
            IsLoading = false;
            operation = null;
        }
    }

    /// <summary>Resolves without a file; a command-line monitor selection may need a mapping first.</summary>
    private void Resolve(IReadOnlyDictionary<int, string>? mapping)
    {
        var available = displays();
        try
        {
            var setup = NativeSessionSetup.Resolve(Inherited, Profile, InvocationRequest, displays: available, mapping: mapping);
            Setup = setup;
            Install(Inherited, Profile, setup.Configuration());
        }
        catch (NativeSetupFailure failure) when (failure.Problem == NativeSetupProblem.DisplayMappingRequired)
        {
            MonitorMapping = Request(failure, available, mapping ?? InvocationRequest?.MonitorMapping);
        }
    }

    private void ReviewDocument(IReadOnlyDictionary<int, string>? mapping)
    {
        var available = displays();
        try
        {
            var setup = NativeSessionSetup.Resolve(Inherited, Profile, InvocationRequest, documentLayer, available, mapping);
            DocumentReview = new NativeDocumentReview(Guid.NewGuid(), setup, available, setup.ExplicitMonitorMapping ? setup.MonitorMapping : null);
            DocumentIssue = null;
        }
        catch (NativeSetupFailure failure) when (failure.Problem == NativeSetupProblem.DisplayMappingRequired)
        {
            MonitorMapping = Request(failure, available, mapping ?? chosenMapping);
        }
        catch (Exception error) when (error is NativeSetupFailure or NativeStorageException) { DocumentFailed(error); }
    }

    private static NativeMonitorMappingRequest Request(NativeSetupFailure failure, NativeSetupDisplays available, IReadOnlyDictionary<int, string>? previous)
    {
        var suggested = new Dictionary<int, string>();
        foreach (var number in failure.MonitorNumbers)
        {
            var id = previous is not null ? previous.GetValueOrDefault(number)
                : number >= 1 && number <= available.Legacy.Count ? available.Legacy[number - 1] : null;
            if (id is not null && available.Available.Contains(id)) suggested[number] = id;
        }
        return new NativeMonitorMappingRequest(Guid.NewGuid(), failure.Layer, failure.MonitorNumbers, suggested, available);
    }

    /// <summary>Opens the mapping again for a reviewed file (Change display assignments…).</summary>
    public void EditDocumentMapping(Guid id)
    {
        UiThread.Require(runtime.Dispatcher);
        if (stopped || IsLoading || IsReady || DocumentReview?.Id != id || documentLayer is null) return;
        var review = DocumentReview;
        if (review.Setup.MonitorNumbers.Count == 0) return;
        var available = displays();
        var suggested = review.Setup.MonitorMapping.Where(p => available.Available.Contains(p.Value)).ToDictionary(p => p.Key, p => p.Value);
        MonitorMapping = new NativeMonitorMappingRequest(Guid.NewGuid(), review.Setup.MonitorSource ?? NativeOptionSource.Document,
            review.Setup.MonitorNumbers, suggested, available);
        DocumentReview = null; DocumentIssue = null;
    }

    /// <summary>Applies a display for every monitor number (from the command line or the file).</summary>
    public void ResolveMapping(Guid id, IReadOnlyDictionary<int, string> assignments)
    {
        UiThread.Require(runtime.Dispatcher);
        if (stopped || IsLoading || IsReady || Session is not null || MonitorMapping is not { } request || request.Id != id) return;
        var available = displays();
        if (!assignments.Keys.Order().SequenceEqual(request.Numbers.Order()) || assignments.Values.Any(v => !available.Available.Contains(v)))
        {
            var text = new NativeText("document.choose.a.connected.display.for.every.monitor.number.before.continuing");
            if (documentLayer is null) InvocationIssue = text; else DocumentIssue = text;
            return;
        }
        MonitorMapping = null;
        chosenMapping = new Dictionary<int, string>(assignments);
        try
        {
            if (documentLayer is not null) ReviewDocument(chosenMapping);
            else Resolve(chosenMapping);
        }
        catch (NativeSetupFailure failure) { InvocationIssue = failure.Text; }
    }

    public void CancelMapping(Guid id)
    {
        UiThread.Require(runtime.Dispatcher);
        if (stopped || IsReady || MonitorMapping?.Id != id) return;
        MonitorMapping = null;
        if (documentLayer is not null)
        {
            documentLayer = null;
            DocumentIssue = NativeDocumentTexts.Cancelled;
        }
        else InvocationIssue = new NativeText("document.command.line.display.selection.was.cancelled");
    }

    /// <summary>Accepts a reviewed file: its ignored fields are acknowledged and the session is created.</summary>
    public void AcceptDocument(Guid id)
    {
        UiThread.Require(runtime.Dispatcher);
        if (stopped || IsLoading || IsReady || Session is not null || DocumentReview is not { } review || review.Id != id) return;
        var current = displays();
        var topologyMatches = review.MonitorMapping is null
            ? current.Legacy.SequenceEqual(review.Displays.Legacy)
            : current.Available.Order().SequenceEqual(review.Displays.Available.Order());
        if (!topologyMatches)
        {
            DocumentReview = null;
            DocumentIssue = NativeDocumentTexts.TopologyChanged;
            if (review.Setup.MonitorNumbers.Count != 0)
                MonitorMapping = new NativeMonitorMappingRequest(Guid.NewGuid(), review.Setup.MonitorSource ?? NativeOptionSource.Document,
                    review.Setup.MonitorNumbers, review.Setup.MonitorMapping.Where(p => current.Available.Contains(p.Value)).ToDictionary(p => p.Key, p => p.Value), current);
            return;
        }
        try
        {
            var configuration = review.Setup.Configuration(review.Setup.Notices.Select(n => n.Line).ToHashSet());
            Setup = review.Setup;
            DocumentReview = null;
            Install(Inherited, Profile, configuration);
            DocumentIssue = null;
        }
        catch (Exception error) when (error is NativeSetupFailure or NativeError or NativeStorageException)
        {
            DocumentReview = null;
            DocumentFailed(error);
        }
    }

    public void CancelDocument(Guid id)
    {
        UiThread.Require(runtime.Dispatcher);
        if (DocumentReview?.Id != id || IsReady) return;
        DocumentReview = null; documentLayer = null;
        DocumentIssue = NativeDocumentTexts.Cancelled;
    }

    private void DocumentFailed(Exception error)
    {
        if (stopped) return;
        switch (error)
        {
            case NativeSetupFailure { Layer: NativeOptionSource.CommandLine } failure: InvocationIssue = failure.Text; break;
            case NativeSetupFailure failure: DocumentIssue = failure.Text; break;
            case NativeDocumentFailure failure: DocumentIssue = NativeDocumentTexts.Text(failure); break;
            case NativeDocumentOpenException open: DocumentIssue = NativeDocumentTexts.Text(open.Error); break;
            case OperationCanceledException: DocumentIssue = NativeDocumentTexts.Cancelled; break;
            default: DocumentIssue = new NativeText("document.the.connection.file.s.settings.could.not.be.applied.check.the.file"); break;
        }
    }

    private void Install(NativeSettings values, NativeConnectionProfile? profile, NativeSessionConfiguration configuration)
    {
        if (Session is not null) throw new NativeStorageException(NativeStorageError.Unavailable);
        var endpoint = Setup?.Endpoint ?? profile?.Endpoint ?? "";
        var gateway = InvocationRequest is not null ? InvocationRequest.Gateway(profile?.SshGateway, endpoint) : profile?.SshGateway;
        if (gateway is not null && purpose == NativeSessionDefaultsPurpose.Listener)
            throw new NativeSetupFailure(NativeSetupProblem.TunnelListenUnsupported, NativeOptionSource.CommandLine, 0);
        // Metadata before the session, so the window installs its address before Connect is possible.
        Profile = profile;
        SshGateway = gateway;
        Inherited = values;
        Prepared = new NativePreparedSessionDefaults(configuration, values, Setup!);
        if (purpose == NativeSessionDefaultsPurpose.Connection) Session = runtime.CreateSession(configuration);
        IsReady = true;
        Error = null;
    }

    /// <summary>A clipboard direction changed for this connection only (never saved).</summary>
    public void SetClipboard(bool? send = null, bool? receive = null)
    {
        UiThread.Require(runtime.Dispatcher);
        if (stopped || !IsReady || Session is not { } session) throw new NativeStorageException(NativeStorageError.Unavailable);
        session.SetClipboardPolicy(send ?? session.ClipboardSendEnabled, receive ?? session.ClipboardReceiveEnabled);
    }

    public void Stop()
    {
        if (stopped) return;
        stopped = true;
        MonitorMapping = null; DocumentReview = null; documentLayer = null;
        cancellation?.Cancel();
    }

    public async Task CloseAsync()
    {
        Stop();
        if (operation is { } running) { try { await running; } catch (OperationCanceledException) { } }
        if (Session is { } session) await session.CloseAsync();
        Dispose();
    }

    public void Dispose()
    {
        Stop();
        cancellation?.Dispose();
    }
}
