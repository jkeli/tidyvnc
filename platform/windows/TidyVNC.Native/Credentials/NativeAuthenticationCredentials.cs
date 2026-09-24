// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using System.Security.Cryptography;
using System.Text;
using CommunityToolkit.Mvvm.ComponentModel;

namespace TidyVNC.Native.Credentials;

public enum NativeCredentialNoticeKind
{
    /// <summary>Launch credentials could not be used; FileError says why when a password file failed.</summary>
    LaunchFailure,
    Saved,
    /// <summary>Authentication succeeded but the save failed (StoreError). Never a connection failure.</summary>
    SaveUnconfirmed,
    /// <summary>The server rejected a saved password; the entry was not deleted.</summary>
    SavedPasswordRejected,
    Removed,
    StoreFailure,
    RequestUnavailable,
}

/// <summary>A user-facing notice; the app localizes it. It never carries paths, names or secrets.</summary>
public sealed record NativeCredentialNotice(NativeCredentialNoticeKind Kind, NativeCredentialError? StoreError = null,
                                            NativePasswordFileError? FileError = null);

/// <summary>
/// One controller per connection window (NativeAuthenticationCredentials on
/// macOS; SERVICES.md section 3, CREDENTIAL-INPUTS.md). Owns the retention
/// choice for an entered password (use once, keep for this session's
/// reconnects, remember on this PC, replace the remembered one), explicit
/// use/forget of a saved password, and launch credentials. Nothing is saved
/// until authentication succeeds with a remember choice; a rejected saved
/// password is never retried or deleted automatically; a save failure is a
/// notice. Secrets never enter observable state. UI thread only.
/// </summary>
public sealed partial class NativeAuthenticationCredentials : ObservableObject
{
    private sealed record Candidate(NativeCredentialKey Key, NativeCredentialSecret Secret, ulong Generation, NativeCredentialRetention Retention);

    private readonly IUiDispatcher dispatcher;
    private readonly NativeCredentialStore? store;
    private readonly INativePasswordFileReader passwordFileReader;
    private NativeSession? session;
    private string? endpoint;
    private string routeIdentity = "";
    private bool stopped;
    private ulong epoch;
    private Task? work;
    private CancellationTokenSource? workCancel;
    private Candidate? pending, retained;
    private ulong? savedSubmission;
    private NativeLaunchCredentialPayload? launch;
    private string? launchEndpoint, launchRouteIdentity, launchEffectiveRouteIdentity;
    private NativePrompt? automaticPrompt;

    [ObservableProperty] public partial NativeCredentialNotice? Notice { get; private set; }
    [ObservableProperty] public partial bool IsWorking { get; private set; }
    [ObservableProperty] public partial bool HasSessionCredential { get; private set; }

    /// <summary>Reverse (listening) windows pass no store: they never offer remember.</summary>
    public NativeAuthenticationCredentials(IUiDispatcher dispatcher, NativeCredentialStore? store = null,
                                           NativeLaunchCredentialInputs? launchInputs = null, INativePasswordFileReader? passwordFileReader = null)
    {
        this.dispatcher = dispatcher;
        this.store = store;
        launch = launchInputs?.Claim();
        this.passwordFileReader = passwordFileReader ?? new NativePasswordFileReader();
    }

    public bool SupportsRemembering => store is not null;
    /// <summary>The pending work (tests and window close await it).</summary>
    public Task Work => work ?? Task.CompletedTask;

    private static void Wipe(byte[] bytes) => CryptographicOperations.ZeroMemory(bytes);

    /// <summary>Follows the session's prompt and state; replaces any earlier binding.</summary>
    public void Bind(NativeSession session)
    {
        UiThread.Require(dispatcher);
        if (this.session is { } previous) previous.PropertyChanged -= OnSessionChanged;
        this.session = session;
        session.PropertyChanged += OnSessionChanged;
    }

    private void OnSessionChanged(object? sender, PropertyChangedEventArgs change)
    {
        if (!ReferenceEquals(sender, session) || session is null) return;
        if (change.PropertyName == nameof(NativeSession.Prompt)) Inspect(session.Prompt);
        else if (change.PropertyName == nameof(NativeSession.Snapshot)) Observe(session.Snapshot);
    }

    // ---- Launch credentials ------------------------------------------------------------

    /// <summary>
    /// The resolved command-line or reviewed-document endpoint binds the launch
    /// inputs before editable admission; an empty form binds on its first
    /// explicit connection. A different endpoint or route revokes them.
    /// </summary>
    public void BindLaunchEndpoint(string endpoint, string? routeIdentity = null)
    {
        UiThread.Require(dispatcher);
        if (launch is null || endpoint.Length == 0) return;
        if (launchEndpoint is null) launchEndpoint = endpoint;
        else EndpointChanged(endpoint);
        if (routeIdentity is not null && launch is not null)
        {
            if (launchRouteIdentity is { } expected && !string.Equals(expected, routeIdentity, StringComparison.Ordinal))
            {
                DiscardLaunch();
                ++epoch;
                CancelAutomatic();
            }
            else launchRouteIdentity = routeIdentity;
        }
    }

    public void EndpointChanged(string endpoint)
    {
        UiThread.Require(dispatcher);
        if (launchEndpoint is { } expected && !string.Equals(expected, endpoint, StringComparison.Ordinal))
        {
            DiscardLaunch();
            ++epoch;
            CancelAutomatic();
        }
    }

    private void CancelAutomatic()
    {
        if (automaticPrompt is null) return;
        workCancel?.Cancel();
        automaticPrompt = null;
    }

    private void DiscardLaunch()
    {
        launch?.Clear();
        launch = null;
        launchEndpoint = launchRouteIdentity = launchEffectiveRouteIdentity = null;
    }

    /// <summary>
    /// Answers a current credential prompt from launch inputs, in order: the
    /// environment pair, a matching retained session password (only ahead of a
    /// password file), then the password file (password-only prompts).
    /// </summary>
    private void Inspect(NativePrompt? request)
    {
        if (request is null || request.Kind != NativePrompt.PromptKind.Credentials)
        {
            if (automaticPrompt is not null) { ++epoch; CancelAutomatic(); }
            return;
        }
        if (stopped || IsWorking || launch is not { } source ||
            !(source.HasEnvironment(request.UsernameRequired) || (!request.UsernameRequired && source.File is not null))) return;
        var ticket = epoch;
        automaticPrompt = request;
        Notice = null;
        Start(async token =>
        {
            try
            {
                if (epoch != ticket || !IsCurrent(request) || token.IsCancellationRequested) return;
                if (SubmitImmediateLaunch(request, source)) return;
                if (source.File is not { } file || request.UsernameRequired) return;
                using var block = await passwordFileReader.ReadAsync(file, token);
                if (epoch != ticket || !IsCurrent(request) || token.IsCancellationRequested || session is not { } current) return;
                current.ReplyPasswordFile(request, block.CopyBytes());
                Notice = null;
            }
            catch (Exception error) when (error is NativePasswordFileException or NativeCredentialException or NativeError or NativeIdentityFailure)
            {
                if (epoch != ticket || !IsCurrent(request) || token.IsCancellationRequested) return;
                Notice = new(NativeCredentialNoticeKind.LaunchFailure, FileError: (error as NativePasswordFileException)?.Error);
            }
        });
    }

    private bool SubmitImmediateLaunch(NativePrompt request, NativeLaunchCredentialPayload source)
    {
        if (!IsCurrent(request) || session is not { } current) throw new NativeError(NativeStatus.Stale, "Inactive credential request");
        if (source.HasEnvironment(request.UsernameRequired))
        {
            var user = request.UsernameRequired ? source.Username!.CopyBytes() : [];
            byte[] password;
            try { password = source.Password!.CopyBytes(); }
            catch { Wipe(user); throw; }
            current.ReplyCredentialBytes(request, user, password); // Wipes both.
            pending?.Secret.Clear();
            pending = null;
            ForgetSession();
            savedSubmission = null;
            Notice = null;
            return true;
        }
        // An explicitly retained, nonempty password for this key precedes a launch password file.
        if (!request.UsernameRequired && source.File is not null && retained is { } kept && kept.Key.Equals(Key(request, "")))
        {
            var bytes = kept.Secret.CopyBytes();
            var nonempty = bytes.Length != 0;
            Wipe(bytes);
            if (nonempty)
            {
                retained = null;
                HasSessionCredential = false;
                try { Forward(request, "", kept.Key, kept.Secret, NativeCredentialRetention.Session); }
                catch { kept.Secret.Clear(); throw; }
                return true;
            }
        }
        return false;
    }

    // ---- Attempts and prompts ------------------------------------------------------------

    /// <summary>Starts a connection attempt: binds launch scope and drops session state for a different destination.</summary>
    public void BeginAttempt(string endpoint, string routeIdentity = "", string? requestedRouteIdentity = null)
    {
        UiThread.Require(dispatcher);
        if (stopped || IsWorking) return;
        BindLaunchEndpoint(endpoint, requestedRouteIdentity ?? routeIdentity);
        if (launch is not null)
        {
            if (launchEffectiveRouteIdentity is { } expected && !string.Equals(expected, routeIdentity, StringComparison.Ordinal)) DiscardLaunch();
            else launchEffectiveRouteIdentity = routeIdentity;
        }
        if ((this.endpoint is { } previous && !string.Equals(previous, endpoint, StringComparison.Ordinal)) ||
            !string.Equals(this.routeIdentity, routeIdentity, StringComparison.Ordinal)) ForgetSession();
        pending?.Secret.Clear();
        pending = null;
        savedSubmission = null;
        this.endpoint = endpoint;
        this.routeIdentity = routeIdentity;
        Notice = null;
        ++epoch;
    }

    private bool IsCurrent(NativePrompt request)
        => !stopped && request.Kind == NativePrompt.PromptKind.Credentials && session is { IsClosing: false } current &&
           current.Generation == request.Generation && current.Prompt is { } prompt && prompt.Id == request.Id && prompt.Generation == request.Generation;

    private NativeCredentialKey Key(NativePrompt request, string username)
    {
        if (!IsCurrent(request) || endpoint is null) throw new NativeError(NativeStatus.Stale, "Inactive credential request");
        return NativeCredentialKey.Create(endpoint, routeIdentity, request.SecurityType, request.UsernameRequired,
            request.UsernameRequired ? username : "");
    }

    /// <summary>
    /// Submits entered credentials. Consumes (wipes) both buffers on every
    /// path, including validation failures and stale prompts.
    /// </summary>
    public void Submit(NativePrompt request, byte[] username, byte[] password, NativeCredentialRetention retention = NativeCredentialRetention.UseOnce)
    {
        try
        {
            UiThread.Require(dispatcher);
            if (IsWorking) throw new NativeCredentialException(NativeCredentialError.Busy);
            if (username.Length > NativeCredentialSecret.MaximumBytes) throw new NativeIdentityFailure(NativeIdentityFailure.Problem.TooLong);
            string user;
            try { user = new UTF8Encoding(false, true).GetString(username); }
            catch (DecoderFallbackException) { throw new NativeIdentityFailure(NativeIdentityFailure.Problem.InvalidText); }
            if (retention is NativeCredentialRetention.Remember or NativeCredentialRetention.ReplaceRemembered && store is null)
                throw new NativeCredentialException(NativeCredentialError.Unavailable);
            var key = Key(request, user);
            var secret = NativeCredentialSecret.Consume(password);
            try { Forward(request, user, key, secret, retention); }
            catch { secret.Clear(); throw; }
        }
        finally
        {
            Wipe(username);
            Wipe(password);
        }
    }

    private void Forward(NativePrompt request, string username, NativeCredentialKey key, NativeCredentialSecret secret, NativeCredentialRetention retention)
    {
        if (!IsCurrent(request) || session is not { } current) throw new NativeError(NativeStatus.Stale, "Inactive credential request");
        var user = request.UsernameRequired ? Encoding.UTF8.GetBytes(username) : [];
        byte[] bytes;
        try { bytes = secret.CopyBytes(); }
        catch { Wipe(user); throw; }
        current.ReplyCredentials(request, user, bytes); // Wipes both.
        pending?.Secret.Clear();
        pending = null;
        ForgetSession();
        savedSubmission = null;
        Notice = null;
        if (retention == NativeCredentialRetention.UseOnce) secret.Clear();
        else pending = new Candidate(key, secret, request.Generation, retention);
    }

    public bool CanUseSession(NativePrompt request, string username)
    {
        if (IsWorking || retained is not { } kept) return false;
        try { return kept.Key.Equals(Key(request, username)); }
        catch (Exception error) when (error is NativeError or NativeIdentityFailure) { return false; }
    }

    /// <summary>Explicitly reuses the password retained for this session.</summary>
    public void UseSession(NativePrompt request, string username)
    {
        UiThread.Require(dispatcher);
        if (!CanUseSession(request, username) || retained is not { } kept) throw new NativeError(NativeStatus.Stale, "No matching session credential");
        // Transfer ownership so Forward cannot wipe the value it is submitting.
        retained = null;
        HasSessionCredential = false;
        try { Forward(request, username, kept.Key, kept.Secret, NativeCredentialRetention.Session); }
        catch { kept.Secret.Clear(); throw; }
    }

    public void ForgetSession()
    {
        retained?.Secret.Clear();
        retained = null;
        HasSessionCredential = false;
    }

    /// <summary>Explicitly submits the saved password for this server, method and user.</summary>
    public void UseSaved(NativePrompt request, string username, NativeCredentialRetention retention = NativeCredentialRetention.UseOnce)
    {
        UiThread.Require(dispatcher);
        if (IsWorking || store is not { } credentials) return;
        NativeCredentialKey key;
        try { key = Key(request, username); }
        catch (Exception error) when (error is NativeError or NativeIdentityFailure)
        {
            Notice = new(NativeCredentialNoticeKind.RequestUnavailable);
            return;
        }
        var ticket = epoch;
        Notice = null;
        Start(async token =>
        {
            try
            {
                var secret = await credentials.LookupAsync(key, token);
                var transferred = false;
                try
                {
                    if (epoch != ticket || !IsCurrent(request) || token.IsCancellationRequested) return;
                    // Existing entries are not rewritten; only the explicit session choice extends the lifetime.
                    var selected = retention == NativeCredentialRetention.Session ? NativeCredentialRetention.Session : NativeCredentialRetention.UseOnce;
                    Forward(request, username, key, secret, selected);
                    transferred = selected == NativeCredentialRetention.Session;
                    savedSubmission = request.Generation;
                }
                finally
                {
                    if (!transferred) secret.Clear();
                }
            }
            catch (Exception error) when (error is NativeCredentialException or NativeError)
            {
                if (epoch != ticket || !IsCurrent(request) || token.IsCancellationRequested) return;
                Notice = new(NativeCredentialNoticeKind.StoreFailure, (error as NativeCredentialException)?.Error ?? NativeCredentialError.IOFailure);
            }
        });
    }

    /// <summary>Explicitly deletes the saved password (never automatic recovery from rejection).</summary>
    public void ForgetSaved(NativePrompt request, string username)
    {
        UiThread.Require(dispatcher);
        if (IsWorking || store is not { } credentials) return;
        NativeCredentialKey key;
        try { key = Key(request, username); }
        catch (Exception error) when (error is NativeError or NativeIdentityFailure)
        {
            Notice = new(NativeCredentialNoticeKind.RequestUnavailable);
            return;
        }
        ForgetSession();
        var ticket = epoch;
        Notice = null;
        Start(async token =>
        {
            try
            {
                await credentials.DeleteAsync(key, token);
                if (epoch == ticket && !stopped) Notice = new(NativeCredentialNoticeKind.Removed);
            }
            catch (NativeCredentialException error)
            {
                if (epoch == ticket && !stopped) Notice = new(NativeCredentialNoticeKind.StoreFailure, error.Error);
            }
        });
    }

    /// <summary>Connected commits the pending choice; closed or failed clears it.</summary>
    private void Observe(NativeSnapshot snapshot)
    {
        if (snapshot.State == NativeSessionState.Connected && pending is { } candidate && candidate.Generation == snapshot.Generation)
        {
            pending = null;
            if (candidate.Retention == NativeCredentialRetention.Session)
            {
                retained = candidate;
                HasSessionCredential = true;
            }
            else if (store is { } credentials)
            {
                var ticket = epoch;
                Start(async _ =>
                {
                    try
                    {
                        // Admitted saves complete even if the window starts closing.
                        await credentials.SaveAsync(candidate.Key, candidate.Secret,
                            candidate.Retention == NativeCredentialRetention.ReplaceRemembered ? NativeCredentialSaveMode.Replace : NativeCredentialSaveMode.Create,
                            CancellationToken.None);
                        if (epoch == ticket && !stopped) Notice = new(NativeCredentialNoticeKind.Saved);
                    }
                    catch (NativeCredentialException error)
                    {
                        if (epoch == ticket && !stopped) Notice = new(NativeCredentialNoticeKind.SaveUnconfirmed, error.Error);
                    }
                    finally
                    {
                        candidate.Secret.Clear();
                    }
                });
            }
            else candidate.Secret.Clear();
        }
        if (snapshot.State is NativeSessionState.Closed or NativeSessionState.Failed)
        {
            if (automaticPrompt is not null) { ++epoch; CancelAutomatic(); }
            if (pending?.Generation == snapshot.Generation)
            {
                pending.Secret.Clear();
                pending = null;
            }
            if (snapshot.EndReason == NativeEndReason.AuthenticationRejected)
            {
                ForgetSession();
                if (savedSubmission == snapshot.Generation) Notice = new(NativeCredentialNoticeKind.SavedPasswordRejected);
            }
        }
    }

    private void Start(Func<CancellationToken, Task> body)
    {
        var cancel = new CancellationTokenSource();
        workCancel = cancel;
        IsWorking = true;
        work = Run();

        async Task Run()
        {
            try
            {
                await Task.Yield();
                await body(cancel.Token);
            }
            finally
            {
                if (ReferenceEquals(workCancel, cancel))
                {
                    automaticPrompt = null;
                    IsWorking = false;
                    workCancel = null;
                }
                cancel.Dispose();
            }
        }
    }

    /// <summary>Cancel, Disconnect and security changes: revoke launch inputs and drop all pending secrets.</summary>
    public void Clear()
    {
        UiThread.Require(dispatcher);
        ++epoch;
        workCancel?.Cancel();
        automaticPrompt = null;
        pending?.Secret.Clear();
        pending = null;
        DiscardLaunch();
        ForgetSession();
        savedSubmission = null;
        Notice = null;
    }

    public void Stop()
    {
        UiThread.Require(dispatcher);
        stopped = true;
        Clear();
        endpoint = null;
        routeIdentity = "";
        if (session is not null) session.PropertyChanged -= OnSessionChanged;
        session = null;
    }

    /// <summary>Window close: stops and waits for admitted work (a save in progress finishes).</summary>
    public async Task CloseAsync()
    {
        Stop();
        await Work;
    }

    public void DismissNotice() => Notice = null;
}
