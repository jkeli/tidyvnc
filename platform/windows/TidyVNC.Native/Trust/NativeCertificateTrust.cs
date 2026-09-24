// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native.Trust;

public enum NativeTrustNotice { Forgotten, ForgottenHostKey }

/// <summary>
/// One per connection window (NativeCertificateTrust on macOS; TRUST.md,
/// SERVICES.md section 5). For a certificate or server-key prompt the core
/// may let the user override, it checks the saved decision for this
/// destination first: a match answers the prompt; a forgotten or changed
/// entry stops there (a forget never revives a broader legacy exception).
/// With no saved entry, a certificate is looked up in the legacy files and a
/// match answers the prompt. Otherwise the dialog offers Connect once, a
/// confirmed Save exception and connect, and Cancel. Verification itself
/// stays in the core. UI thread only.
/// </summary>
public sealed partial class NativeCertificateTrust : ObservableObject
{
    private readonly IUiDispatcher dispatcher;
    private readonly NativeLegacyTrustFiles? legacy;
    private readonly NativeTrustStore? certificates, hostKeys;
    private NativeSession? target;
    private NativeTrustScope? scope, hostScope;
    private NativePrompt? latest;
    private Task? work;
    private CancellationTokenSource? workCancel;
    private ulong epoch;
    private bool suspended, stopped;

    [ObservableProperty] public partial NativeKnownHostsMatch? Inspection { get; private set; }
    [ObservableProperty] public partial NativeSavedTrustInspection? SavedInspection { get; private set; }
    [ObservableProperty] public partial NativeStorageError? SavedIssue { get; private set; }
    [ObservableProperty] public partial NativeLegacyTrustError? Issue { get; private set; }
    [ObservableProperty] public partial NativeTrustNotice? Notice { get; private set; }
    [ObservableProperty] public partial bool NeedsReload { get; private set; }
    [ObservableProperty] public partial bool IsWorking { get; private set; }

    public NativeCertificateTrust(IUiDispatcher dispatcher, NativeLegacyTrustFiles? legacy = null, NativeTrustStore? certificates = null,
                                  NativeTrustStore? hostKeys = null)
    {
        if (certificates is { Kind: not NativeTrustKind.Certificate } || hostKeys is { Kind: not NativeTrustKind.HostKey })
            throw new ArgumentException("Trust store kinds do not match");
        this.dispatcher = dispatcher;
        this.legacy = legacy;
        this.certificates = certificates;
        this.hostKeys = hostKeys;
    }

    public Task Work => work ?? Task.CompletedTask;

    public void Bind(NativeSession session)
    {
        UiThread.Require(dispatcher);
        if (target is { } previous) previous.PropertyChanged -= OnSessionChanged;
        target = session;
        session.PropertyChanged += OnSessionChanged;
    }

    private void OnSessionChanged(object? sender, PropertyChangedEventArgs change)
    {
        if (ReferenceEquals(sender, target) && change.PropertyName == nameof(NativeSession.Prompt)) Inspect(target!.Prompt);
    }

    public void BeginAttempt(string? endpoint = null, string routeIdentity = "")
    {
        UiThread.Require(dispatcher);
        suspended = false;
        scope = hostScope = null;
        if (endpoint is { Length: > 0 })
        {
            try
            {
                scope = NativeTrustScope.Create(endpoint, routeIdentity, NativeTrustKind.Certificate);
                hostScope = NativeTrustScope.Create(endpoint, routeIdentity, NativeTrustKind.HostKey);
            }
            catch (NativeIdentityFailure) { scope = hostScope = null; }
        }
        Inspect(null);
    }

    private void Inspect(NativePrompt? request)
    {
        ++epoch;
        workCancel?.Cancel();
        latest = request;
        Inspection = null; Issue = null; SavedInspection = null; SavedIssue = null; Notice = null; NeedsReload = false;
        if (work is null) StartIfNeeded();
    }

    private bool Current(NativePrompt request, ulong ticket, CancellationToken token)
        => !stopped && !suspended && epoch == ticket && !token.IsCancellationRequested && target is { IsClosing: false } session &&
           session.Generation == request.Generation && session.Prompt is { } prompt && prompt.Id == request.Id && prompt.Generation == request.Generation;

    private NativeTrustStore? StoreFor(NativePrompt request) => request.Kind == NativePrompt.PromptKind.HostKey ? hostKeys : certificates;
    private NativeTrustScope? ScopeFor(NativePrompt request) => request.Kind == NativePrompt.PromptKind.HostKey ? hostScope : scope;

    private void StartIfNeeded()
    {
        if (stopped || suspended || latest is not { } request ||
            request.Kind is not (NativePrompt.PromptKind.Certificate or NativePrompt.PromptKind.HostKey) ||
            !new NativeTrustPresentation(request).MayConnectOnce) return;
        var saved = StoreFor(request);
        var destination = ScopeFor(request);
        Start(async (ticket, token) =>
        {
            try
            {
                if (saved is not null)
                {
                    if (destination is null) throw new NativeStorageException(NativeStorageError.Unavailable);
                    var inspection = request.Kind == NativePrompt.PromptKind.HostKey
                        ? await saved.InspectHostKeyAsync(destination, request.Identity, token)
                        : await saved.InspectAsync(destination, request.Identity, token);
                    if (!Current(request, ticket, token)) return;
                    SavedInspection = inspection;
                    if (inspection.State == NativeSavedTrustState.Match) { target!.ReplyTrust(request, true); return; }
                    // Explicit destination decisions win; a forget never revives a legacy exception.
                    if (inspection.State != NativeSavedTrustState.Absent) return;
                }
                if (request.Kind == NativePrompt.PromptKind.HostKey) return;
                if (legacy is null) throw new NativeLegacyTrustException(NativeLegacyTrustError.Unavailable);
                var result = await legacy.LookupAsync(request.ServerName, request.Identity, token);
                if (!Current(request, ticket, token)) return;
                Inspection = result;
                // Only for this pending certificate, after the core's non-overridable policy gate.
                if (result.State == NativeKnownHostsState.Match) target!.ReplyTrust(request, true);
            }
            catch (Exception error) when (error is NativeStorageException or NativeLegacyTrustException or NativeError)
            {
                if (!Current(request, ticket, token)) return;
                if (error is NativeStorageException storage) { SavedIssue = storage.Error; NeedsReload = true; }
                else Issue = (error as NativeLegacyTrustException)?.Error ?? NativeLegacyTrustError.Unavailable;
            }
        });
    }

    private void Start(Func<ulong, CancellationToken, Task> body)
    {
        var ticket = epoch;
        var cancel = new CancellationTokenSource();
        workCancel = cancel;
        IsWorking = true;
        work = Run();

        async Task Run()
        {
            try
            {
                await Task.Yield();
                await body(ticket, cancel.Token);
            }
            finally
            {
                cancel.Dispose();
                if (ReferenceEquals(workCancel, cancel)) workCancel = null;
                work = null;
                IsWorking = false;
                if (epoch != ticket) StartIfNeeded();
            }
        }
    }

    public bool CanConnectOnce(NativePrompt request)
        => !IsWorking && Current(request, epoch, CancellationToken.None) && new NativeTrustPresentation(request).MayConnectOnce;

    /// <summary>The dialog's Connect once: this attempt only, nothing saved.</summary>
    public void ConnectOnce(NativePrompt request)
    {
        UiThread.Require(dispatcher);
        if (!CanConnectOnce(request) || target is null) throw new NativeError(NativeStatus.Stale, "Inactive trust request");
        target.ReplyTrust(request, true);
    }

    public bool CanSave(NativePrompt request)
        => CanConnectOnce(request) && StoreFor(request) is not null && ScopeFor(request) is not null &&
           SavedInspection is { State: not NativeSavedTrustState.Match } && SavedIssue is null && !NeedsReload;

    /// <summary>True when saving replaces a different saved key (the confirmation says so).</summary>
    public bool ReplacesSavedKey => SavedInspection?.State == NativeSavedTrustState.Changed;

    public void Reload()
    {
        UiThread.Require(dispatcher);
        if (work is null && latest is { } request) Inspect(request);
    }

    /// <summary>The confirmed Save exception and connect.</summary>
    public void SaveAndConnect(NativePrompt request) => Change(request, forget: false);

    public void Forget(NativePrompt request) => Change(request, forget: true);

    private void Change(NativePrompt request, bool forget)
    {
        UiThread.Require(dispatcher);
        if (!CanSave(request) || StoreFor(request) is not { } saved || ScopeFor(request) is not { } destination || SavedInspection is not { } inspection) return;
        Notice = null;
        SavedIssue = null;
        Start(async (ticket, token) =>
        {
            try
            {
                var result = forget ? await saved.ForgetAsync(destination, inspection.Revision, CancellationToken.None)
                    : request.Kind == NativePrompt.PromptKind.HostKey
                        ? await saved.SaveHostKeyAsync(destination, request.Identity, inspection.State == NativeSavedTrustState.Changed, inspection.Revision, CancellationToken.None)
                        : await saved.SaveAsync(destination, request.Identity, request.CertificateStatus, inspection.State == NativeSavedTrustState.Changed,
                                                inspection.Revision, CancellationToken.None);
                if (!Current(request, ticket, token)) return;
                Inspection = null;
                SavedInspection = new(forget ? NativeSavedTrustState.Forgotten : NativeSavedTrustState.Match, result.Revision,
                    forget ? null : inspection.ReceivedFingerprint, inspection.ReceivedFingerprint);
                if (forget) Notice = request.Kind == NativePrompt.PromptKind.HostKey ? NativeTrustNotice.ForgottenHostKey : NativeTrustNotice.Forgotten;
                else target!.ReplyTrust(request, true);
            }
            catch (Exception error) when (error is NativeStorageException or NativeError)
            {
                if (!Current(request, ticket, token)) return;
                SavedIssue = (error as NativeStorageException)?.Error ?? NativeStorageError.IOFailure;
                NeedsReload = true;
            }
        });
    }

    /// <summary>The dialog's Cancel (the default button): stops inspecting until the next attempt.</summary>
    public void Cancel()
    {
        UiThread.Require(dispatcher);
        suspended = true;
        Inspect(null);
    }

    public void Stop()
    {
        UiThread.Require(dispatcher);
        stopped = true;
        Cancel();
        if (target is not null) target.PropertyChanged -= OnSessionChanged;
        target = null;
    }

    public async Task CloseAsync()
    {
        Stop();
        await Work;
    }
}

/// <summary>A trust library window's model (NativeTrustLibrary on macOS): list, reload and forget.</summary>
public sealed partial class NativeTrustLibrary(IUiDispatcher dispatcher, NativeTrustStore store) : ObservableObject
{
    private Task? work;
    private bool stopped;

    [ObservableProperty] public partial NativeSavedTrustSnapshot? Snapshot { get; private set; }
    [ObservableProperty] public partial bool IsWorking { get; private set; }
    [ObservableProperty] public partial bool NeedsReload { get; private set; }
    [ObservableProperty] public partial NativeStorageError? Issue { get; private set; }
    [ObservableProperty] public partial bool Forgot { get; private set; }

    public NativeTrustKind Kind => store.Kind;
    public IReadOnlyList<NativeSavedTrustEntry> Entries => Snapshot?.Entries ?? [];
    public Task Work => work ?? Task.CompletedTask;

    private void Start(Func<Task> body)
    {
        IsWorking = true;
        Issue = null;
        Forgot = false;
        work = Run();

        async Task Run()
        {
            try
            {
                await Task.Yield();
                await body();
            }
            catch (NativeStorageException error)
            {
                if (!stopped) { NeedsReload = true; Issue = error.Error; }
            }
            finally
            {
                work = null;
                IsWorking = false;
            }
        }
    }

    public void Reload()
    {
        UiThread.Require(dispatcher);
        if (stopped || work is not null) return;
        Start(async () =>
        {
            var snapshot = await store.ReadSnapshotAsync();
            if (stopped) return;
            Snapshot = snapshot;
            OnPropertyChanged(nameof(Entries));
            NeedsReload = false;
        });
    }

    public void Forget(string id)
    {
        UiThread.Require(dispatcher);
        if (stopped || work is not null || NeedsReload || Snapshot is not { } snapshot ||
            snapshot.Entries.FirstOrDefault(e => e.Id == id) is not { IsForgotten: false } entry) return;
        Forget(entry.Scope, snapshot.Revision);
    }

    public void ForgetDestination(string endpoint, string routeIdentity = "")
    {
        UiThread.Require(dispatcher);
        if (stopped || work is not null || NeedsReload || Snapshot is not { } snapshot) return;
        NativeTrustScope scope;
        try { scope = NativeTrustScope.Create(endpoint, routeIdentity, store.Kind); }
        catch (NativeIdentityFailure) { Issue = NativeStorageError.Corrupt; return; }
        Forget(scope, snapshot.Revision);
    }

    private void Forget(NativeTrustScope scope, Guid? revision) => Start(async () =>
    {
        var result = await store.ForgetAsync(scope, revision);
        if (stopped) return;
        Snapshot = result;
        OnPropertyChanged(nameof(Entries));
        Forgot = true;
    });

    public async Task CloseAsync()
    {
        stopped = true;
        await Work;
    }
}
