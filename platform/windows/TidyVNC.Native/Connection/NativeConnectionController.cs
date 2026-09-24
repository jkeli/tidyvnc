// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;
using TidyVNC.Native.Credentials;
using TidyVNC.Native.Documents;
using TidyVNC.Native.Storage;
using TidyVNC.Native.Trust;
using TidyVNC.Native.Tunnel;

namespace TidyVNC.Native;

/// <summary>When a settings editor may stay open.</summary>
public enum NativeEditorScope
{
    /// <summary>Needs the live connection (input, scaling, encoding, information, remote resize).</summary>
    Connected,
    /// <summary>Edits the next attempt (security, connection options); closes when one starts.</summary>
    Disconnected,
    /// <summary>Either state (fullscreen displays, resize policy).</summary>
    Any,
}

/// <summary>A connection problem shown once per attempt generation; Retry is offered only when it may repeat.</summary>
public sealed record NativeConnectionProblem(Guid Id, ulong Generation, NativeConnectionIssue Issue);

/// <summary>
/// An accepted incoming connection (macOS ReverseConnectionRequest). The
/// peer's source port is an observation, not a destination: nothing about it
/// is saved or restored.
/// </summary>
public sealed record NativeReverseRequest(NativeListener Listener, NativeIncomingPeer Peer, NativePreparedSessionDefaults? Prepared = null,
                                          NativeLaunchCredentialInputs? Credentials = null)
{
    public string Endpoint => (Peer.Address.Host.Contains(':', StringComparison.Ordinal) ? $"[{Peer.Address.Host}]" : Peer.Address.Host) + "::" + Peer.Address.Port;
}

/// <summary>What a connection window is created from; every part is optional.</summary>
public sealed record NativeConnectionRequest
{
    public Guid? ProfileId { get; init; }
    public NativeInvocationLayer? Invocation { get; init; }
    public NativeDocumentOpenRequest? Document { get; init; }
    public NativeReverseRequest? Reverse { get; init; }
    /// <summary>Connect as soon as the command line's address is installed.</summary>
    public bool ConnectOnReady { get; init; }
    public NativeLaunchCredentialInputs? LaunchCredentials { get; init; }
}

/// <summary>The app-wide services a connection window uses (tests substitute private ones).</summary>
public sealed record NativeConnectionServices(NativeRuntime Runtime, NativePreferencesStore Preferences)
{
    public NativeProfileHistoryStore? Profiles { get; init; }
    public NativeRecentHistory? History { get; init; }
    public NativeCredentialStore? Credentials { get; init; }
    public NativeLegacyTrustFiles? LegacyTrust { get; init; }
    public NativeTrustStore? Certificates { get; init; }
    public NativeTrustStore? HostKeys { get; init; }
    public INativeDocumentReader? DocumentReader { get; init; }
    public Func<NativeSetupDisplays>? Displays { get; init; }
    public INativePasswordFileReader? PasswordFileReader { get; init; }
    /// <summary>Starts a tunnel for one attempt (tests substitute a fake).</summary>
    public Func<NativeSshGateway, string, NativeSshInteraction, NativeSessionConfiguration, CancellationToken, Task<INativeTunnel>>? TunnelFactory { get; init; }
}

/// <summary>A running tunnel for one attempt: the relay endpoint, its route and its end.</summary>
public interface INativeTunnel : IAsyncDisposable
{
    string LocalEndpoint { get; }
    string RouteIdentity { get; }
    Task<NativeSshTunnelError?> Ended { get; }
}

/// <summary>
/// One connection window's controller (ConnectionModel.swift): address and
/// gateway editing, connect/cancel/disconnect/retry, the SSH tunnel for one
/// attempt, reverse admission, problem presentation with the AlertOnFatalError
/// policy, history, and ordered close. Settings dialogs register as the
/// single open editor so connection admission and dialogs never overlap.
/// UI thread only; the window binds to its observable properties.
/// </summary>
public sealed partial class NativeConnectionController : ObservableObject, IDisposable
{
    private readonly NativeConnectionServices services;
    private readonly NativeReverseRequest? reverse;
    private readonly bool startupAlertOnFatalError;
    private bool reverseAttempted, destinationPublished, suppressProblem, connectOnReady;
    private NativeConnectionProblem? retryProblem;
    private ulong? reportedGeneration;
    private NativeConnectionDestination? attemptDestination;
    private TunnelAttempt? tunnel;
    private Task? operation, cleanup;
    private CancellationTokenSource? cancel;
    private object? editor;
    private Task? editorCleanup;

    public NativeSessionDefaults Defaults { get; }
    public NativeAuthenticationCredentials Credentials { get; }
    public NativeCertificateTrust Trust { get; }
    public NativeSshInteraction SshInteraction { get; }
    /// <summary>This connection's input policy and scaling (the Input and Scaling dialogs edit them).</summary>
    public NativeInputState Input { get; } = new();
    public NativeScalingState Scaling { get; } = new();
    public NativeRecentHistory? History { get; }
    public bool IsReverse => reverse is not null;
    public NativeSession? Session => Defaults.Session;
    public IUiDispatcher Dispatcher => services.Runtime.Dispatcher;

    [ObservableProperty] public partial string Endpoint { get; set; } = "";
    [ObservableProperty] public partial NativeEndpointIssue? EndpointIssue { get; private set; } = NativeEndpointIssue.Required;
    [ObservableProperty] public partial string SshGatewayText { get; set; } = "";
    [ObservableProperty] public partial NativeText? GatewayIssue { get; private set; }
    [ObservableProperty] public partial bool Busy { get; private set; }
    [ObservableProperty] public partial bool Closing { get; private set; }
    /// <summary>A fatal message shown as an alert (no Retry).</summary>
    [ObservableProperty] public partial NativeText? Message { get; private set; }
    [ObservableProperty] public partial NativeConnectionProblem? ConnectionProblem { get; private set; }
    /// <summary>AlertOnFatalError=off and the failure cannot be retried: the window closes.</summary>
    [ObservableProperty] public partial bool ClosesAfterFailure { get; private set; }
    [ObservableProperty] public partial bool ShowsStatistics { get; private set; }
    /// <summary>The attempt's address: credential prompts name this, not a later edit.</summary>
    [ObservableProperty] public partial string? AttemptEndpoint { get; private set; }

    /// <summary>The session is installed and its address published (the window attaches its desktop).</summary>
    public event Action<NativeSession>? SessionReady;

    public NativeConnectionController(NativeConnectionServices services, NativeConnectionRequest? request = null)
    {
        request ??= new NativeConnectionRequest();
        this.services = services;
        reverse = request.Reverse;
        connectOnReady = request.ConnectOnReady;
        var dispatcher = services.Runtime.Dispatcher;
        startupAlertOnFatalError = reverse?.Prepared?.Configuration.AlertOnFatalError ?? request.Invocation?.AlertOnFatalError ?? true;
        History = reverse is null ? services.History : null;
        var launch = reverse is not null ? reverse.Credentials
            : request.LaunchCredentials ?? (request.Invocation is { } invocation
                ? SafeFileOnly(invocation) : null);
        // Incoming connections never save: no credential or trust stores.
        Credentials = new NativeAuthenticationCredentials(dispatcher, reverse is null ? services.Credentials : null, launch, services.PasswordFileReader);
        Trust = new NativeCertificateTrust(dispatcher, reverse is null ? services.LegacyTrust : null,
            reverse is null ? services.Certificates : null, reverse is null ? services.HostKeys : null);
        SshInteraction = new NativeSshInteraction(dispatcher);
        Defaults = new NativeSessionDefaults(services.Runtime, services.Preferences, services.Profiles, request.ProfileId, reverse is null ? request.Invocation : null,
            request.Document, services.DocumentReader, services.Displays, prepared: reverse?.Prepared);
        Defaults.PropertyChanged += DefaultsChanged;
        Credentials.PropertyChanged += (_, _) => OnPropertyChanged(nameof(CanConnect));
        Trust.PropertyChanged += (_, _) => OnPropertyChanged(nameof(CanConnect));
        Defaults.Load();
    }

    private static NativeLaunchCredentialInputs? SafeFileOnly(NativeInvocationLayer invocation)
    {
        try { return NativeLaunchCredentialInputs.FileOnly(invocation.Invocation, invocation.WorkingDirectory); }
        catch (NativeLaunchCredentialException) { return null; }
    }

    private bool AlertOnFatalError => Session?.AlertOnFatalError ?? startupAlertOnFatalError;

    // ---- Address and gateway --------------------------------------------------------------

    partial void OnEndpointChanged(string value)
    {
        EndpointIssue = NativeEndpoint.Issue(value);
        Credentials.EndpointChanged(value);
        UpdateGatewayIssue();
        OnPropertyChanged(nameof(CanConnect));
    }

    partial void OnSshGatewayTextChanged(string value)
    {
        UpdateGatewayIssue();
        if (destinationPublished)
            Credentials.BindLaunchEndpoint(Endpoint, value.Length == 0 ? "" : SshGateway?.IntentIdentity ?? "invalid-ssh-gateway");
        OnPropertyChanged(nameof(CanConnect));
    }

    public NativeSshGateway? SshGateway
    {
        get
        {
            if (SshGatewayText.Length == 0) return null;
            try { return NativeSshGateway.Parse(SshGatewayText); }
            catch (NativeError) { return null; }
        }
    }

    private void UpdateGatewayIssue()
    {
        if (SshGatewayText.Length == 0) { GatewayIssue = null; return; }
        if (SshGateway is null) { GatewayIssue = NativeTunnelTexts.InvalidRequest; return; }
        GatewayIssue = EndpointIssue is null && !NativeSessionSetup.IsTunnelTarget(Endpoint) ? NativeTunnelTexts.UnsupportedTarget : null;
    }

    public NativeConnectionDestination Destination => new(Endpoint, SshGateway);

    public bool CanEditDestination => !IsReverse && !Busy && !Closing && Session is { IsClosing: false } session &&
                                      session.Snapshot.State is NativeSessionState.Idle or NativeSessionState.Closed or NativeSessionState.Failed;

    /// <summary>A recent connection fills the address and gateway without connecting.</summary>
    public void SelectDestination(NativeConnectionDestination value)
    {
        if (!CanEditDestination) return;
        Endpoint = value.Endpoint;
        SshGatewayText = value.SshGateway?.CanonicalUri ?? "";
    }

    private void DefaultsChanged(object? sender, PropertyChangedEventArgs change)
    {
        if (change.PropertyName != nameof(NativeSessionDefaults.Session) || Defaults.Session is not { } session) return;
        Trust.Bind(session);
        Credentials.Bind(session);
        Input.Bind(session, Defaults.Setup?.InactiveCursor ?? NativeCursorFallback.Dot);
        Scaling.Bind(session);
        if (reverse is not null) Endpoint = reverse.Endpoint;
        else if (Defaults.Setup is { } setup && (setup.Endpoint.Length != 0 || Defaults.DocumentRequest is not null)) Endpoint = setup.Endpoint;
        else if (Defaults.Profile is { } profile) Endpoint = profile.Endpoint;
        SshGatewayText = reverse is null ? Defaults.SshGateway?.CanonicalUri ?? "" : "";
        destinationPublished = true;
        Credentials.BindLaunchEndpoint(Endpoint, SshGateway?.IntentIdentity ?? "");
        session.PropertyChanged += SessionChanged;
        SessionReady?.Invoke(session);
        OnPropertyChanged(nameof(Session));
        OnPropertyChanged(nameof(CanConnect));
        // Publication precedes readiness: connect once after this admission completes,
        // unless close or an address edit revoked it first.
        var address = Endpoint;
        if (reverse is not null || (connectOnReady && address.Length != 0 && Defaults.DocumentRequest is null))
            Dispatcher.TryEnqueue(() =>
            {
                if (ReferenceEquals(Session, session) && (reverse is not null || Endpoint == address) && CanConnect) Connect();
            });
    }

    private void SessionChanged(object? sender, PropertyChangedEventArgs change)
    {
        if (!ReferenceEquals(sender, Session) || Session is not { } session) return;
        if (change.PropertyName == nameof(NativeSession.Snapshot))
        {
            var snapshot = session.Snapshot;
            if (snapshot.State != NativeSessionState.Connected) ShowsStatistics = false;
            CloseEditorFor(snapshot.State);
            if (tunnel is { Admitted: true } attempt && snapshot.Generation != attempt.InitialGeneration &&
                snapshot.State is NativeSessionState.Closed or NativeSessionState.Failed) FinishTunnel(attempt);
            if (NativeConnectionIssues.From(snapshot) is { } issue) Report(issue, snapshot.Generation);
            OnPropertyChanged(nameof(CanConnect));
            OnPropertyChanged(nameof(CanEditDestination));
        }
        else if (change.PropertyName is nameof(NativeSession.IsClosing) or nameof(NativeSession.Prompt))
        {
            OnPropertyChanged(nameof(CanConnect));
        }
    }

    // ---- Editors (settings dialogs) --------------------------------------------------------

    private NativeEditorScope editorScope;
    private Func<Task>? editorClose;

    /// <summary>The open settings dialog's draft, if any; only one at a time.</summary>
    public object? Editor => editor;

    /// <summary>
    /// Registers an open editor; false when another is open or still draining.
    /// A Connected editor closes when the connection ends, a Disconnected one
    /// when an attempt starts (macOS closes the same sheets on the same
    /// transitions). <paramref name="close"/> stops the draft and completes
    /// when any cancelled apply has drained; the next editor waits for it.
    /// </summary>
    public bool BeginEditor(object draft, NativeEditorScope scope, Func<Task> close)
    {
        UiThread.Require(Dispatcher);
        if (editor is not null || editorCleanup is not null || Closing) return false;
        editor = draft; editorScope = scope; editorClose = close;
        OnPropertyChanged(nameof(Editor));
        OnPropertyChanged(nameof(CanConnect));
        return true;
    }

    /// <summary>Ends an editor (its dialog closed, was superseded or the connection changed).</summary>
    public void EndEditor(object draft)
    {
        UiThread.Require(Dispatcher);
        if (!ReferenceEquals(editor, draft)) return;
        var close = editorClose;
        editor = null; editorClose = null;
        if (close?.Invoke() is { IsCompleted: false } drain)
        {
            editorCleanup = drain;
            _ = DrainEditor(drain);
        }
        OnPropertyChanged(nameof(Editor));
        OnPropertyChanged(nameof(CanConnect));
    }

    private async Task DrainEditor(Task drain)
    {
        try { await drain; } catch (Exception error) when (error is NativeError or OperationCanceledException or NativeCommandFailure) { }
        if (ReferenceEquals(editorCleanup, drain)) editorCleanup = null;
        OnPropertyChanged(nameof(Editor));
        OnPropertyChanged(nameof(CanConnect));
    }

    private void CloseEditorFor(NativeSessionState state)
    {
        if (editor is not { } open) return;
        var idle = state is NativeSessionState.Idle or NativeSessionState.Closed or NativeSessionState.Failed;
        if ((editorScope == NativeEditorScope.Connected && state != NativeSessionState.Connected) ||
            (editorScope == NativeEditorScope.Disconnected && !idle)) EndEditor(open);
    }

    /// <summary>No editor, prompt, pending work or close: a dialog may open.</summary>
    public bool EditorsIdle => editor is null && editorCleanup is null && !Closing && !Busy && !Credentials.IsWorking && !Trust.IsWorking &&
                               Session is { IsClosing: false, Prompt: null };

    // ---- Connect ---------------------------------------------------------------------------

    public bool CanConnect =>
        (!IsReverse || !reverseAttempted) && Session is { } session && Defaults.IsReady && GatewayIssue is null && tunnel is null &&
        editor is null && editorCleanup is null && !Busy && !Closing && !Credentials.IsWorking && !Trust.IsWorking && EndpointIssue is null &&
        !session.IsClosing && session.Snapshot.State is NativeSessionState.Idle or NativeSessionState.Closed or NativeSessionState.Failed;

    public void Connect()
    {
        UiThread.Require(Dispatcher);
        if (!CanConnect || Session is not { } session) return;
        var destination = Destination;
        var address = Endpoint;
        var gateway = reverse is null ? destination.SshGateway : null;
        suppressProblem = false;
        Busy = true; Message = null; ConnectionProblem = null; retryProblem = null;
        if (reverse is not null) reverseAttempted = true;
        attemptDestination = destination; AttemptEndpoint = address; reportedGeneration = null;
        cancel?.Dispose();
        cancel = new CancellationTokenSource();
        operation = ConnectAsync(session, destination, address, gateway, cancel.Token);
        OnPropertyChanged(nameof(CanConnect));
        OnPropertyChanged(nameof(CanEditDestination));
    }

    private async Task ConnectAsync(NativeSession session, NativeConnectionDestination destination, string address, NativeSshGateway? gateway,
                                    CancellationToken token)
    {
        TunnelAttempt? attempt = null;
        var connected = false;
        try
        {
            var routeIdentity = "";
            if (gateway is not null)
            {
                SshInteraction.Begin(gateway, address);
                var factory = services.TunnelFactory ?? StartTunnel;
                attempt = tunnel = new TunnelAttempt(await factory(gateway, address, SshInteraction, Defaults.Prepared!.Configuration, token), session.Generation);
                token.ThrowIfCancellationRequested();
                if (Closing) throw new OperationCanceledException();
                routeIdentity = attempt.Tunnel.RouteIdentity;
                _ = WatchTunnel(attempt);
            }
            Trust.BeginAttempt(reverse is null ? address : null, routeIdentity);
            Credentials.BeginAttempt(address, routeIdentity, gateway?.IntentIdentity ?? "");
            NativeCompletion completion;
            if (reverse is not null) completion = await reverse.Listener.AcceptAsync(reverse.Peer, session);
            else if (attempt is not null)
            {
                attempt.Admitted = true;
                completion = await session.ConnectAsync(address, attempt.Tunnel.LocalEndpoint, attempt.Tunnel.RouteIdentity, token);
            }
            else completion = await session.ConnectAsync(address, token);
            token.ThrowIfCancellationRequested();
            connected = !Closing && session.Snapshot.State == NativeSessionState.Connected;
            if (connected && completion.Operation.Generation == session.Generation && completion.Snapshot.State == NativeSessionState.Connected)
                History?.RecordSuccessful(destination);
        }
        catch (OperationCanceledException) { }
        catch (NativeSshTunnelException failure) { ReportFatal(NativeTunnelTexts.Text(failure.Error)); }
        catch (Exception error) when (error is NativeError or NativeCommandFailure)
        {
            if (reverse is not null && error is not NativeCommandFailure)
                ReportFatal(new NativeText("connection.recovery.this.incoming.connection.is.no.longer.available.ask.the.server.to.make"));
            else if (NativeConnectionIssues.From(error) is { } issue)
                Report(issue, (error as NativeCommandFailure)?.Operation.Generation ?? session.Generation);
        }
        if (attempt is not null && !connected)
        {
            await attempt.DrainAsync(session);
            if (ReferenceEquals(tunnel, attempt)) tunnel = null;
        }
        Busy = false;
        operation = null;
        OnPropertyChanged(nameof(CanConnect));
        OnPropertyChanged(nameof(CanEditDestination));
    }

    private static async Task<INativeTunnel> StartTunnel(NativeSshGateway gateway, string endpoint, NativeSshInteraction interaction,
                                                         NativeSessionConfiguration configuration, CancellationToken token)
    {
        string host;
        uint port;
        using (var identity = NativeEndpointIdentity.Create(endpoint, allowUnixSockets: false))
        {
            if (identity.Kind != NativeEndpointIdentity.NativeEndpointKind.Tcp) throw new NativeSshTunnelException(NativeSshTunnelError.ForwardingFailed);
            host = identity.Host; port = identity.Port;
        }
        var options = new NativeSshTunnelOptions { Ipv4 = configuration.Ipv4, Ipv6 = configuration.Ipv6 };
        return new SshTunnel(await NativeSshTunnel.StartAsync(gateway, host, (int)port, interaction, options, cancellation: token));
    }

    private sealed class SshTunnel(NativeSshTunnel tunnel) : INativeTunnel
    {
        public string LocalEndpoint => tunnel.LocalEndpoint;
        public string RouteIdentity => tunnel.RouteIdentity;
        public Task<NativeSshTunnelError?> Ended => tunnel.Ended;
        public ValueTask DisposeAsync() => tunnel.DisposeAsync();
    }

    /// <summary>A tunnel belongs to exactly one attempt; its drain is shared by failure, disconnect and close.</summary>
    private sealed class TunnelAttempt(INativeTunnel tunnel, ulong initialGeneration)
    {
        private Task? drain;
        public INativeTunnel Tunnel { get; } = tunnel;
        public ulong InitialGeneration { get; } = initialGeneration;
        public bool Admitted { get; set; }
        public bool Stopping { get; private set; }

        public Task DrainAsync(NativeSession session)
        {
            if (drain is not null) return drain;
            Stopping = true;
            return drain = Run(session);
        }

        private async Task Run(NativeSession session)
        {
            if (Admitted) await DrainSession(session);
            await Tunnel.DisposeAsync();
        }
    }

    private static async Task DrainSession(NativeSession session)
    {
        if (session.IsClosing) { await session.CloseAsync(); return; }
        try { await session.DisconnectAsync(); }
        catch (NativeError error) when (error.Status is NativeStatus.Closing or NativeStatus.NotConnected)
        {
            // The worker may already be finishing; its terminal snapshot follows the drain.
            for (var i = 0; i < 1000 && !session.IsClosing &&
                 session.Snapshot.State is not (NativeSessionState.Idle or NativeSessionState.Closed or NativeSessionState.Failed); i++)
                await Task.Delay(10);
            if (session.IsClosing) await session.CloseAsync();
        }
        catch (Exception error) when (error is NativeError or NativeCommandFailure)
        {
            if (session.IsClosing || session.Snapshot.State is not (NativeSessionState.Idle or NativeSessionState.Closed or NativeSessionState.Failed))
                await session.CloseAsync();
        }
    }

    private async Task WatchTunnel(TunnelAttempt attempt)
    {
        var result = await attempt.Tunnel.Ended;
        if (result is null || attempt.Stopping || Closing || !ReferenceEquals(tunnel, attempt)) return;
        if (!AlertOnFatalError) { CloseAfterFailure(); return; }
        suppressProblem = true; ConnectionProblem = null; retryProblem = null;
        Message = new NativeText("connection.recovery.the.ssh.tunnel.closed.check.the.gateway.and.connect.again");
        Trust.Cancel(); Credentials.Clear();
        if (operation is not null) cancel?.Cancel();
        else FinishTunnel(attempt);
    }

    private void FinishTunnel(TunnelAttempt attempt)
    {
        if (Closing || !ReferenceEquals(tunnel, attempt) || operation is not null || Session is not { } session) return;
        Busy = true;
        operation = Finish();
        async Task Finish()
        {
            await attempt.DrainAsync(session);
            if (ReferenceEquals(tunnel, attempt)) tunnel = null;
            Busy = false; operation = null;
            OnPropertyChanged(nameof(CanConnect));
        }
    }

    public void Cancel()
    {
        UiThread.Require(Dispatcher);
        SshInteraction.Cancel();
        if (reverse is not null) { try { reverse.Listener.Reject(reverse.Peer); } catch (NativeError) { } }
        Trust.Cancel(); Credentials.Clear();
        suppressProblem = true; ConnectionProblem = null; retryProblem = null;
        cancel?.Cancel();
    }

    public void Disconnect()
    {
        UiThread.Require(Dispatcher);
        if (Session is not { } session || Closing) return;
        if (Busy) { Cancel(); return; }
        Trust.Cancel(); Credentials.Clear();
        suppressProblem = true; ConnectionProblem = null; retryProblem = null;
        Busy = true; Message = null;
        var attempt = tunnel;
        operation = Run();
        async Task Run()
        {
            try { await session.DisconnectAsync(); }
            catch (Exception error) when (error is NativeError or NativeCommandFailure)
            {
                if (!Closing && NativeConnectionIssues.From(error) is { } issue) Message = issue.Message();
            }
            if (attempt is not null)
            {
                await attempt.DrainAsync(session);
                if (ReferenceEquals(tunnel, attempt)) tunnel = null;
            }
            Busy = false; operation = null;
            OnPropertyChanged(nameof(CanConnect));
            OnPropertyChanged(nameof(CanEditDestination));
        }
    }

    public void Refresh()
    {
        UiThread.Require(Dispatcher);
        if (Session is not { } session || session.Snapshot.State != NativeSessionState.Connected || Closing) return;
        var generation = session.Generation;
        _ = Run();
        async Task Run()
        {
            try { await session.RefreshAsync(); }
            catch (Exception error) when (error is NativeError or NativeCommandFailure)
            {
                if (!Closing && session.Generation == generation && ConnectionProblem is null && NativeConnectionIssues.From(error) is { } issue)
                    Message = issue.Message();
            }
        }
    }

    // ---- Problems ---------------------------------------------------------------------------

    /// <summary>A failure that cannot offer Retry: an alert, or with AlertOnFatalError off, this window closes.</summary>
    public void ReportFatal(NativeText text)
    {
        if (Closing || suppressProblem) return;
        if (AlertOnFatalError) Message = text;
        else CloseAfterFailure();
    }

    public void DismissMessage() => Message = null;

    private void CloseAfterFailure()
    {
        if (Closing) return;
        Message = null;
        RequestClose();
        ClosesAfterFailure = true;
    }

    private void Report(NativeConnectionIssue issue, ulong generation)
    {
        if (Closing || suppressProblem || Session?.Generation != generation || reportedGeneration == generation) return;
        reportedGeneration = generation;
        Message = null;
        var problem = new NativeConnectionProblem(Guid.NewGuid(), generation, issue);
        if (!AlertOnFatalError && !OffersRetry(problem)) { CloseAfterFailure(); return; }
        retryProblem = problem; ConnectionProblem = problem;
    }

    /// <summary>Hides the alert; Cancel (<see cref="DismissProblem"/>) also revokes the retry.</summary>
    public void HideProblem(Guid id)
    {
        if (ConnectionProblem?.Id == id) ConnectionProblem = null;
    }

    public void DismissProblem(Guid id)
    {
        HideProblem(id);
        if (retryProblem?.Id == id) retryProblem = null;
    }

    public bool OffersRetry(NativeConnectionProblem problem) => !IsReverse && problem.Issue.PermitsReconnect() && Session?.ReconnectOnErrorEnabled == true;

    public bool CanRetry(NativeConnectionProblem problem) =>
        retryProblem?.Id == problem.Id && OffersRetry(problem) && CanConnect && Session?.Generation == problem.Generation &&
        Equals(attemptDestination, Destination);

    public void Retry(NativeConnectionProblem problem)
    {
        if (CanRetry(problem)) Connect();
    }

    /// <summary>
    /// New security settings replace what earlier prompts relied on: the
    /// session password, pending trust work and any Retry for the old settings.
    /// </summary>
    public void SecurityApplied()
    {
        UiThread.Require(Dispatcher);
        Credentials.Clear(); Trust.Cancel();
        ConnectionProblem = null; retryProblem = null;
    }

    // ---- Statistics --------------------------------------------------------------------------

    public bool CanToggleStatistics => ShowsStatistics || (!Closing && !Busy && Session?.Information is not null);

    public void ToggleStatistics()
    {
        if (CanToggleStatistics) ShowsStatistics = !ShowsStatistics;
    }

    // ---- Close -------------------------------------------------------------------------------

    /// <summary>Stops everything this window owns; <see cref="CloseAsync"/> awaits the drain.</summary>
    public void RequestClose()
    {
        UiThread.Require(Dispatcher);
        if (cleanup is not null) return;
        if (reverse is not null) { try { reverse.Listener.Reject(reverse.Peer); } catch (NativeError) { } }
        Trust.Stop(); Credentials.Stop(); SshInteraction.Stop();
        Closing = true; ConnectionProblem = null; retryProblem = null; AttemptEndpoint = null; ShowsStatistics = false;
        cancel?.Cancel();
        if (editor is { } open) EndEditor(open);
        Input.Stop(); Scaling.Stop();
        Defaults.Stop();
        var session = Session;
        var attempt = tunnel;
        var running = operation;
        var drain = editorCleanup;
        cleanup = Run();
        async Task Run()
        {
            if (session is not null) { try { await session.CloseAsync(); } catch (NativeError) { } }
            if (running is not null) { try { await running; } catch (OperationCanceledException) { } }
            if (attempt is not null && session is not null) await attempt.DrainAsync(session);
            await Trust.CloseAsync(); await Credentials.CloseAsync();
            if (drain is not null) { try { await drain; } catch (Exception error) when (error is NativeError or OperationCanceledException) { } }
            await Defaults.CloseAsync();
            cancel?.Dispose();
        }
        OnPropertyChanged(nameof(CanConnect));
    }

    public async Task CloseAsync()
    {
        RequestClose();
        await cleanup!;
    }

    /// <summary>Releases what <see cref="CloseAsync"/> has not (call after it).</summary>
    public void Dispose()
    {
        cancel?.Dispose();
        Defaults.Dispose();
    }
}
