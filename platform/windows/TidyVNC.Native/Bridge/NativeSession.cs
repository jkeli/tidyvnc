// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Text;
using CommunityToolkit.Mvvm.ComponentModel;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

/// <summary>Where a setting's effective value came from (tidyvnc TIDYVNC_SOURCE_*).</summary>
public enum NativeOptionSource : uint { Compiled = 0, AppDefaults, Profile, Session, CommandLine, Document }

/// <summary>Per-session creation settings (NativeSessionConfiguration in Swift).</summary>
public sealed class NativeSessionConfiguration
{
    /// <summary>Null uses the shared default; explicit zero disables motion delay.</summary>
    public uint? PointerEventIntervalMilliseconds { get; set; }
    public NativeOptionSource? PointerEventIntervalSource { get; set; }
    /// <summary>Incoming clipboard wire bytes; null uses the shared default.</summary>
    public uint? MaxCutText { get; set; }
    public NativeOptionSource? MaxCutTextSource { get; set; }
    public bool Ipv4 { get; set; } = true;
    public bool Ipv6 { get; set; } = true;
    public bool AlertOnFatalError { get; set; } = true;
    public bool Shared { get; set; }
    public bool ReconnectOnError { get; set; } = true;
    public NativeOptionSource SharedSource { get; set; } = NativeOptionSource.Compiled;
    public NativeOptionSource ReconnectSource { get; set; } = NativeOptionSource.Compiled;
    public bool ViewOnly { get; set; }
    public bool EmulateMiddleButton { get; set; }
    public NativeOptionSource ViewOnlySource { get; set; } = NativeOptionSource.Compiled;
    public NativeOptionSource MiddleButtonSource { get; set; } = NativeOptionSource.Compiled;
    public NativeEncodingOptions? Encoding { get; set; }
    /// <summary>Null snapshots the compiled defaults; empty explicitly denies every type.</summary>
    public IReadOnlyList<uint>? SecurityTypes { get; set; }
    public NativeOptionSource? SecuritySource { get; set; }
    public string TlsPriority { get; set; } = "";
    public NativeOptionSource? TlsPrioritySource { get; set; }
    public string CaFile { get; set; } = "";
    public string CrlFile { get; set; } = "";
    public uint PromptTimeoutMilliseconds { get; set; } = 60_000;
    public uint EventCapacity { get; set; } = 128;
    public uint CommandCapacity { get; set; } = 32;
    public ulong FramebufferBytes { get; set; } = 64UL * 1024 * 1024;
    public ulong PublicationBytes { get; set; } = 128UL * 1024 * 1024;
    public bool ClipboardSend { get; set; } = true;
    public bool ClipboardReceive { get; set; } = true;
}

/// <summary>Sharing and reconnect options of a session (NativeConnectionOptions).</summary>
public sealed record NativeConnectionOptions(bool Shared, bool ReconnectOnError, bool Editable, ulong Revision, ulong Generation,
                                             NativeOptionSource SharedSource, NativeOptionSource ReconnectSource);

/// <summary>Current security configuration of a session (NativeSessionSecurity).</summary>
public sealed record NativeSessionSecurity(ulong Revision, ulong Generation, bool Editable, string Types, string TlsPriority,
                                           string CaFile, string CrlFile);

/// <summary>
/// One viewer session (NativeSession.swift), owned by the UI thread. Core
/// readiness arrives through <see cref="NativeDelivery"/>; each delivery drains
/// events, the view, prompts and clipboard, and ignores stale generations.
/// </summary>
public sealed partial class NativeSession : ObservableObject
{
    private readonly NativeRuntime runtime;
    private readonly NativeHandle handle;
    private readonly Guid imageStream = Guid.NewGuid();
    private readonly NativeHandle? subscription;
    private readonly NativeDelivery? delivery;
    private readonly List<Func<Task>> closeParticipants = [];
    private readonly Dictionary<Guid, Pending> pending = [];
    private Task? closeTask;
    private (ulong Generation, ulong Count) bellMark;
    private NativeImage? frame, cursor;
    private Guid? desktopFocusOwner;

    private sealed class Pending(NativeOperation operation, TaskCompletionSource<NativeCompletion> completion)
    {
        public NativeOperation Operation { get; } = operation;
        public TaskCompletionSource<NativeCompletion> Completion { get; } = completion;
        public bool Cancelled { get; set; }
    }

    public uint PointerEventIntervalMilliseconds { get; }
    public NativeOptionSource PointerEventIntervalSource { get; }
    public uint MaxCutText { get; }
    public NativeOptionSource MaxCutTextSource { get; }
    public bool Ipv4 { get; }
    public bool Ipv6 { get; }
    public bool AlertOnFatalError { get; }
    public bool InitialShared { get; }
    public bool InitialReconnectOnError { get; }
    public IReadOnlyList<uint> InitialSecurityTypes { get; }
    public string InitialTlsPriority { get; }
    public NativeOptionSource InitialTlsPrioritySource { get; }
    public NativeOptionSource InitialSecuritySource { get; }
    public string InitialCaFile { get; }
    public string InitialCrlFile { get; }
    public NativeOptionSource ViewOnlySource { get; private set; }
    public NativeOptionSource MiddleButtonSource { get; private set; }
    private NativeOptionSource sharedSource, reconnectSource;
    public bool ReconnectOnErrorEnabled { get; private set; }

    [ObservableProperty] public partial NativeSnapshot Snapshot { get; private set; }
    [ObservableProperty] public partial NativePrompt? Prompt { get; private set; }
    [ObservableProperty] public partial NativeError? DeliveryError { get; private set; }
    [ObservableProperty] public partial bool IsClosing { get; private set; }
    [ObservableProperty] public partial bool IsFocused { get; private set; }
    [ObservableProperty] public partial bool IsViewOnly { get; private set; }
    [ObservableProperty] public partial bool EmulatesMiddleButton { get; private set; }
    [ObservableProperty] public partial bool HasFrame { get; private set; }
    [ObservableProperty] public partial NativeClipboardUpdate? Clipboard { get; private set; }
    [ObservableProperty] public partial bool ClipboardSendEnabled { get; private set; }
    [ObservableProperty] public partial bool ClipboardReceiveEnabled { get; private set; }

    /// <summary>The current attempt's generation; commands for older attempts are stale.</summary>
    public ulong Generation { get; private set; } = 1;

    /// <summary>Called on the UI thread when the current attempt's bell count advances (once per delivery turn).</summary>
    public Action? BellHandler { get; set; }

    /// <summary>Frame and cursor updates. Handlers borrow; call Clone() to keep a lease.</summary>
    public event Action<NativeImage?>? FrameUpdated;
    public event Action<NativeImage?>? CursorUpdated;
    /// <summary>A new attempt started (connect, routed connect or accepted reverse connection).</summary>
    public event Action<ulong>? AttemptStarted;

    public NativeImage? Frame
    {
        get => frame;
        private set
        {
            if (ReferenceEquals(frame, value)) return;
            var previous = frame;
            frame = value;
            FrameUpdated?.Invoke(value);
            previous?.Dispose();
            HasFrame = value is not null;
        }
    }

    public NativeImage? Cursor
    {
        get => cursor;
        private set
        {
            if (ReferenceEquals(cursor, value)) return;
            var previous = cursor;
            cursor = value;
            CursorUpdated?.Invoke(value);
            previous?.Dispose();
        }
    }

    public NativeConnectionInformation? Information =>
        !IsClosing && Snapshot.Generation == Generation && Snapshot.State == NativeSessionState.Connected ? Snapshot.Information : null;

    internal NativeHandle Handle => handle;
    public IUiDispatcher Dispatcher => runtime.Dispatcher;

    internal unsafe NativeSession(NativeRuntime runtime, NativeSessionConfiguration configuration)
    {
        this.runtime = runtime;
        var error = Abi.Init<tidyvnc_error>();
        var timing = Abi.Init<tidyvnc_input_timing>();
        Abi.Check(NativeMethods.tidyvnc_input_timing_init(&timing, &error), &error);
        if (configuration.PointerEventIntervalMilliseconds is { } interval) timing.pointer_interval_ms = interval;
        PointerEventIntervalMilliseconds = timing.pointer_interval_ms;
        PointerEventIntervalSource = configuration.PointerEventIntervalSource ??
            (configuration.PointerEventIntervalMilliseconds is null ? NativeOptionSource.Compiled : NativeOptionSource.Session);
        var limits = Abi.Init<tidyvnc_message_limits>();
        Abi.Check(NativeMethods.tidyvnc_message_limits_init(&limits, &error), &error);
        if (configuration.MaxCutText is { } limit) limits.max_cut_text = limit;
        MaxCutText = limits.max_cut_text;
        MaxCutTextSource = configuration.MaxCutTextSource ??
            (configuration.MaxCutText is null ? NativeOptionSource.Compiled : NativeOptionSource.Session);
        Ipv4 = configuration.Ipv4; Ipv6 = configuration.Ipv6;
        AlertOnFatalError = configuration.AlertOnFatalError;
        InitialShared = configuration.Shared; InitialReconnectOnError = configuration.ReconnectOnError;
        ReconnectOnErrorEnabled = configuration.ReconnectOnError;
        sharedSource = configuration.SharedSource; reconnectSource = configuration.ReconnectSource;
        ViewOnlySource = configuration.ViewOnlySource; MiddleButtonSource = configuration.MiddleButtonSource;
        InitialCaFile = configuration.CaFile; InitialCrlFile = configuration.CrlFile;

        var options = Abi.Init<tidyvnc_session_options>();
        Abi.Check(NativeMethods.tidyvnc_session_options_init(&options, &error), &error);
        if (configuration.SecurityTypes is { } types)
        {
            if (types.Count > 32) throw new NativeError(NativeStatus.InvalidArgument, "Too many security types");
            options.security_count = (uint)types.Count;
            for (var i = 0; i < 32; i++) options.security_types[i] = i < types.Count ? types[i] : 0;
        }
        var initialTypes = new uint[options.security_count];
        for (var i = 0; i < initialTypes.Length; i++) initialTypes[i] = options.security_types[i];
        InitialSecurityTypes = initialTypes;
        InitialTlsPriority = configuration.TlsPriority;
        InitialTlsPrioritySource = configuration.TlsPrioritySource ??
            (configuration.TlsPriority.Length == 0 ? NativeOptionSource.Compiled : NativeOptionSource.Session);
        InitialSecuritySource = configuration.SecuritySource ??
            (configuration.SecurityTypes is null ? NativeOptionSource.Compiled : NativeOptionSource.Session);
        options.prompt_timeout_ms = configuration.PromptTimeoutMilliseconds;
        options.event_capacity = configuration.EventCapacity;
        options.command_capacity = configuration.CommandCapacity;
        options.framebuffer_bytes = configuration.FramebufferBytes;
        options.publication_bytes = configuration.PublicationBytes;

        var priority = NativeText.Utf8(configuration.TlsPriority);
        var ca = NativeText.Utf8(configuration.CaFile);
        var crl = NativeText.Utf8(configuration.CrlFile);
        ulong raw = 0;
        fixed (byte* p = priority) fixed (byte* c = ca) fixed (byte* r = crl)
        {
            options.tls_priority = NativeText.Span(p, priority.Length);
            options.ca_file = NativeText.Span(c, ca.Length);
            options.crl_file = NativeText.Span(r, crl.Length);
            Abi.Check(NativeMethods.tidyvnc_session_create_with_message_limits(runtime.Handle.Raw, &options,
                configuration.Encoding?.Handle.Raw ?? 0, &timing, &limits, &raw, &error), &error);
        }
        handle = NativeHandle.Adopt(raw);
        var current = Abi.Init<tidyvnc_snapshot>();
        Abi.Check(NativeMethods.tidyvnc_session_snapshot(handle.Raw, &current, &error), &error);
        Snapshot = NativeSnapshot.From(current);
        Abi.Check(NativeMethods.tidyvnc_session_clipboard_policy(handle.Raw, current.generation,
            configuration.ClipboardSend ? 1u : 0u, configuration.ClipboardReceive ? 1u : 0u, &error), &error);
        if (configuration.Shared)
        {
            var sharing = Abi.Init<tidyvnc_sharing>();
            ulong revision = 0;
            Abi.Check(NativeMethods.tidyvnc_session_sharing(handle.Raw, &sharing, &error), &error);
            Abi.Check(NativeMethods.tidyvnc_session_set_shared(handle.Raw, sharing.generation, sharing.revision, 1, &revision, &error), &error);
        }
        ClipboardSendEnabled = configuration.ClipboardSend;
        ClipboardReceiveEnabled = configuration.ClipboardReceive;
        Abi.Check(NativeMethods.tidyvnc_session_input_policy(handle.Raw, configuration.ViewOnly ? 1u : 0u,
            configuration.EmulateMiddleButton ? 1u : 0u, &error), &error);
        IsViewOnly = configuration.ViewOnly; EmulatesMiddleButton = configuration.EmulateMiddleButton;

        var weak = new WeakReference<NativeSession>(this);
        delivery = new NativeDelivery(runtime.Dispatcher, (id, generation) =>
        {
            if (weak.TryGetTarget(out var session)) session.Receive(id, generation);
        });
        var callbacks = delivery.Callbacks();
        ulong subscribed = 0;
        var status = NativeMethods.tidyvnc_session_subscribe(handle.Raw, &callbacks, &subscribed, &error);
        if (status != Tidyvnc.TIDYVNC_OK)
        {
            delivery.AbandonUnretained();
            handle.Dispose();
            throw new NativeError(error);
        }
        subscription = NativeHandle.Adopt(subscribed);
    }

    /// <summary>A component that must stop (and be awaited) when the session closes, e.g. render workers.</summary>
    public void RegisterCloseParticipant(Func<Task> close) => closeParticipants.Add(close);

    // ---- Commands -------------------------------------------------------------------------

    private unsafe delegate uint Submit(tidyvnc_operation* operation, tidyvnc_error* error);

    private unsafe Task<NativeCompletion> SubmitAsync(Submit send, bool advancesGeneration = false,
                                                      CancellationToken cancellation = default)
    {
        UiThread.Require(Dispatcher);
        cancellation.ThrowIfCancellationRequested();
        if (IsClosing) throw new NativeError(NativeStatus.Closing, "Session is closing");
        var operation = Abi.Init<tidyvnc_operation>();
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(send(&operation, &error), &error);
        if (advancesGeneration) BeginAttempt(operation.generation);
        var token = Guid.NewGuid();
        var completion = new TaskCompletionSource<NativeCompletion>(TaskCreationOptions.RunContinuationsAsynchronously);
        var request = new Pending(new NativeOperation(operation.operation, operation.generation), completion);
        pending[token] = request;
        if (cancellation.CanBeCanceled)
        {
            var registration = cancellation.Register(() => Dispatcher.TryEnqueue(() => Cancel(token)));
            completion.Task.ContinueWith(_ => registration.Dispose(), TaskScheduler.Default);
        }
        return completion.Task;
    }

    private void BeginAttempt(ulong generation)
    {
        Generation = generation;
        Frame = null; Cursor = null; Prompt = null; DeliveryError = null; Clipboard = null;
        desktopFocusOwner = null; IsFocused = false;
        AttemptStarted?.Invoke(generation);
    }

    private unsafe void Cancel(Guid token)
    {
        if (!pending.TryGetValue(token, out var request)) return;
        request.Cancelled = true;
        // Best effort after admission: the one completion is still consumed.
        _ = NativeMethods.tidyvnc_session_cancel_operation(handle.Raw, request.Operation.Generation, request.Operation.Id, null);
    }

    public unsafe Task<NativeCompletion> ConnectAsync(string endpoint, CancellationToken cancellation = default)
    {
        var bytes = NativeText.Utf8(endpoint);
        return SubmitAsync((operation, error) =>
        {
            var options = Abi.Init<tidyvnc_connect_options>();
            var status = NativeMethods.tidyvnc_connect_options_init(&options, error);
            if (status != Tidyvnc.TIDYVNC_OK) return status;
            options.ipv4 = Ipv4 ? 1u : 0u; options.ipv6 = Ipv6 ? 1u : 0u;
            fixed (byte* p = bytes)
            {
                options.endpoint = NativeText.Span(p, bytes.Length);
                return NativeMethods.tidyvnc_session_connect(handle.Raw, &options, operation, error);
            }
        }, advancesGeneration: true, cancellation);
    }

    /// <summary>
    /// Connects through a host-owned forwarder (SSH tunnel). The caller owns the
    /// tunnel until this session's transport has drained; trust and credentials
    /// are scoped to endpoint + route, never the forwarding address.
    /// </summary>
    public unsafe Task<NativeCompletion> ConnectAsync(string endpoint, string localEndpoint, string routeIdentity,
                                                      CancellationToken cancellation = default)
    {
        var target = NativeEndpointIdentity.Create(endpoint, routeIdentity);
        var local = NativeText.Utf8(localEndpoint);
        var task = SubmitAsync((operation, error) =>
        {
            var options = Abi.Init<tidyvnc_connect_options>();
            var status = NativeMethods.tidyvnc_connect_options_init(&options, error);
            if (status != Tidyvnc.TIDYVNC_OK) return status;
            options.ipv4 = Ipv4 ? 1u : 0u; options.ipv6 = Ipv6 ? 1u : 0u;
            fixed (byte* p = local)
            {
                options.endpoint = NativeText.Span(p, local.Length);
                return NativeMethods.tidyvnc_session_connect_routed(handle.Raw, target.Raw, &options, operation, error);
            }
        }, advancesGeneration: true, cancellation);
        task.ContinueWith(_ => target.Dispose(), TaskScheduler.Default);
        return task;
    }

    internal unsafe Task<NativeCompletion> AcceptIncomingAsync(NativeHandle listener, ulong incoming)
        => SubmitAsync((operation, error) => NativeMethods.tidyvnc_listener_accept(listener.Raw, incoming, handle.Raw, operation, error),
                       advancesGeneration: true);

    public unsafe Task<NativeCompletion> DisconnectAsync()
        => SubmitAsync((operation, error) => NativeMethods.tidyvnc_session_disconnect(handle.Raw, Generation, operation, error));

    public unsafe Task<NativeCompletion> RefreshAsync()
        => SubmitAsync((operation, error) => NativeMethods.tidyvnc_session_refresh(handle.Raw, Generation, operation, error));

    public unsafe NativeRemoteDesktop DesktopLayout()
    {
        var value = Abi.Init<tidyvnc_desktop_layout>();
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_session_desktop_layout(handle.Raw, Generation, &value, &error), &error);
        return NativeRemoteDesktop.From(value);
    }

    public unsafe Task<NativeCompletion> RequestDesktopLayoutAsync(NativeRemoteLayout layout, ulong expectedGeneration)
        => SubmitAsync((operation, error) =>
        {
            var screens = layout.Screens.Select(s => s.ToAbi()).ToArray();
            fixed (tidyvnc_remote_screen* p = screens)
            {
                var request = Abi.Init<tidyvnc_desktop_layout_request>();
                request.width = layout.Width; request.height = layout.Height;
                request.screen_count = (uint)screens.Length; request.screens = p;
                return NativeMethods.tidyvnc_session_request_desktop_layout(handle.Raw, expectedGeneration, &request, operation, error);
            }
        });

    public unsafe NativeEncodingOptions EncodingOptions()
    {
        var error = Abi.Init<tidyvnc_error>();
        ulong raw = 0;
        Abi.Check(NativeMethods.tidyvnc_session_encoding(handle.Raw, &raw, &error), &error);
        return new NativeEncodingOptions(NativeHandle.Adopt(raw));
    }

    public unsafe Task<NativeCompletion> ApplyEncodingAsync(NativeEncodingOptions options, ulong? expectedGeneration = null)
        => SubmitAsync((operation, error) =>
            NativeMethods.tidyvnc_session_apply_encoding(handle.Raw, expectedGeneration ?? Generation, options.Handle.Raw, operation, error));

    public unsafe Task<NativeCompletion> OfferClipboardAsync(string text, NativeClipboardText? origin = null, ulong changeId = 0,
                                                            ulong? expectedGeneration = null)
    {
        var bytes = NativeText.Utf8(text);
        return SubmitAsync((operation, error) =>
        {
            fixed (byte* p = bytes)
                return NativeMethods.tidyvnc_session_clipboard_offer(handle.Raw, expectedGeneration ?? Generation,
                    NativeText.Span(p, bytes.Length), origin?.Handle.Raw ?? 0, changeId, operation, error);
        });
    }

    public unsafe Task<NativeCompletion> ClearClipboardAsync(ulong? expectedGeneration = null)
        => SubmitAsync((operation, error) =>
            NativeMethods.tidyvnc_session_clipboard_clear(handle.Raw, expectedGeneration ?? Generation, operation, error));

    public unsafe void SetClipboardPolicy(bool send, bool receive)
    {
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_session_clipboard_policy(handle.Raw, Generation, send ? 1u : 0u, receive ? 1u : 0u, &error), &error);
        ClipboardSendEnabled = send; ClipboardReceiveEnabled = receive;
    }

    public unsafe void ValidateClipboard(NativeClipboardRoute route, bool sending)
    {
        var value = route.ToAbi();
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_session_clipboard_check(handle.Raw, &value, sending ? 1u : 0u, &error), &error);
    }

    public unsafe NativeConnectionOptions ConnectionOptions()
    {
        var value = Abi.Init<tidyvnc_sharing>();
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_session_sharing(handle.Raw, &value, &error), &error);
        return new NativeConnectionOptions(value.shared != 0, ReconnectOnErrorEnabled, value.editable != 0, value.revision,
                                           value.generation, sharedSource, reconnectSource);
    }

    public unsafe void SetConnectionOptions(bool shared, bool reconnectOnError, NativeConnectionOptions expected)
    {
        if (IsClosing) throw new NativeError(NativeStatus.Closing, "Session closing");
        var error = Abi.Init<tidyvnc_error>();
        ulong revision = 0;
        Abi.Check(NativeMethods.tidyvnc_session_set_shared(handle.Raw, expected.Generation, expected.Revision, shared ? 1u : 0u,
            &revision, &error), &error);
        if (shared != expected.Shared) sharedSource = NativeOptionSource.Session;
        if (reconnectOnError != expected.ReconnectOnError) reconnectSource = NativeOptionSource.Session;
        ReconnectOnErrorEnabled = reconnectOnError;
        OnPropertyChanged(nameof(ReconnectOnErrorEnabled));
    }

    public unsafe NativeSessionSecurity SecurityConfiguration()
    {
        var value = Abi.Init<tidyvnc_security_configuration>();
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_session_security(handle.Raw, &value, &error), &error);
        return new NativeSessionSecurity(value.revision, value.generation, value.editable != 0,
            NativeText.Fixed(value.types, 1025),
            Encoding.UTF8.GetString(value.tls_priority, (int)Math.Min(value.tls_priority_length, 4096)),
            Encoding.UTF8.GetString(value.ca_file, (int)Math.Min(value.ca_file_length, 4096)),
            Encoding.UTF8.GetString(value.crl_file, (int)Math.Min(value.crl_file_length, 4096)));
    }

    /// <summary>Callers preflight syntax off the UI thread; the core refuses active attempts.</summary>
    public unsafe void SetSecurity(string types, string tlsPriority, string caFile, string crlFile, NativeSessionSecurity expected)
    {
        if (IsClosing) throw new NativeError(NativeStatus.Closing, "Session closing");
        var t = NativeText.Utf8(types); var p = NativeText.Utf8(tlsPriority);
        var c = NativeText.Utf8(caFile); var r = NativeText.Utf8(crlFile);
        var error = Abi.Init<tidyvnc_error>();
        ulong revision = 0;
        fixed (byte* tp = t) fixed (byte* pp = p) fixed (byte* cp = c) fixed (byte* rp = r)
        {
            var update = Abi.Init<tidyvnc_security_update>();
            update.types = NativeText.Span(tp, t.Length); update.tls_priority = NativeText.Span(pp, p.Length);
            update.ca_file = NativeText.Span(cp, c.Length); update.crl_file = NativeText.Span(rp, r.Length);
            Abi.Check(NativeMethods.tidyvnc_session_set_security(handle.Raw, expected.Generation, expected.Revision, &update,
                &revision, &error), &error);
        }
    }

    // ---- Input ----------------------------------------------------------------------------

    public unsafe void SetFocused(bool focused)
    {
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_session_focus(handle.Raw, Generation, focused ? 1u : 0u, &error), &error);
        if (!focused) desktopFocusOwner = null;
        IsFocused = focused;
    }

    /// <summary>
    /// Scoped desktop focus: a losing or destroyed surface releases only its own
    /// interval; moving focus between surfaces drains held input first.
    /// </summary>
    public void SetDesktopFocused(bool focused, Guid owner, bool releaseUnowned = false)
    {
        if (!focused)
        {
            if (desktopFocusOwner == owner || (releaseUnowned && desktopFocusOwner is null && IsFocused)) SetFocused(false);
            return;
        }
        if (IsClosing) throw new NativeError(NativeStatus.Closing, "Session is closing");
        if (desktopFocusOwner != owner)
        {
            if (IsFocused) SetFocused(false);
            desktopFocusOwner = owner;
        }
        try { SetFocused(true); }
        catch { if (desktopFocusOwner == owner) desktopFocusOwner = null; throw; }
    }

    public unsafe void SetViewOnly(bool enabled)
    {
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_session_view_only(handle.Raw, enabled ? 1u : 0u, &error), &error);
        if (IsViewOnly != enabled) { ViewOnlySource = NativeOptionSource.Session; IsViewOnly = enabled; }
    }

    public unsafe void SetInputPolicy(bool viewOnly, bool emulateMiddle)
    {
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_session_input_policy(handle.Raw, viewOnly ? 1u : 0u, emulateMiddle ? 1u : 0u, &error), &error);
        if (IsViewOnly != viewOnly) { ViewOnlySource = NativeOptionSource.Session; IsViewOnly = viewOnly; }
        if (EmulatesMiddleButton != emulateMiddle) { MiddleButtonSource = NativeOptionSource.Session; EmulatesMiddleButton = emulateMiddle; }
    }

    public unsafe void SendKey(uint id, uint keysym, uint keycode, bool down)
    {
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_session_key(handle.Raw, Generation, id, keysym, keycode, down ? 1u : 0u, &error), &error);
    }

    public unsafe void ReleaseInput()
    {
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_session_release_input(handle.Raw, Generation, &error), &error);
    }

    public unsafe void SendPointer(int x, int y, uint buttons)
    {
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_session_pointer(handle.Raw, Generation, x, y, buttons, &error), &error);
    }

    // ---- Prompts --------------------------------------------------------------------------

    /// <summary>
    /// Replies with caller-owned mutable UTF-8 buffers, wiped on return. WinUI's
    /// PasswordBox yields an immutable string, so a managed copy exists until
    /// garbage collection (SERVICES.md section 3); this call never keeps one.
    /// </summary>
    public unsafe void ReplyCredentials(NativePrompt request, byte[] username, byte[] password)
    {
        try
        {
            var error = Abi.Init<tidyvnc_error>();
            fixed (byte* u = username) fixed (byte* p = password)
            {
                var user = new tidyvnc_mutable_bytes { data = u, length = (ulong)username.Length };
                var secret = new tidyvnc_mutable_bytes { data = p, length = (ulong)password.Length };
                Abi.Check(NativeMethods.tidyvnc_session_reply_credentials(handle.Raw, request.Id, request.Generation, user, secret, &error), &error);
            }
            if (Prompt?.Id == request.Id) Prompt = null;
        }
        finally { NativeText.Wipe(username); NativeText.Wipe(password); }
    }

    /// <summary>Captured legacy bytes (VNC_PASSWORD etc.) need not be UTF-8.</summary>
    public unsafe void ReplyCredentialBytes(NativePrompt request, byte[] username, byte[] password)
    {
        try
        {
            var error = Abi.Init<tidyvnc_error>();
            fixed (byte* u = username) fixed (byte* p = password)
            {
                var user = new tidyvnc_mutable_bytes { data = u, length = (ulong)username.Length };
                var secret = new tidyvnc_mutable_bytes { data = p, length = (ulong)password.Length };
                Abi.Check(NativeMethods.tidyvnc_session_reply_credential_bytes(handle.Raw, request.Id, request.Generation, user, secret, &error), &error);
            }
            if (Prompt?.Id == request.Id) Prompt = null;
        }
        finally { NativeText.Wipe(username); NativeText.Wipe(password); }
    }

    /// <summary>The core decodes one legacy PasswordFile block; no plaintext is introduced here.</summary>
    public unsafe void ReplyPasswordFile(NativePrompt request, byte[] block)
    {
        try
        {
            var error = Abi.Init<tidyvnc_error>();
            fixed (byte* b = block)
            {
                var bytes = new tidyvnc_mutable_bytes { data = b, length = (ulong)block.Length };
                Abi.Check(NativeMethods.tidyvnc_session_reply_password_file(handle.Raw, request.Id, request.Generation, bytes, &error), &error);
            }
            if (Prompt?.Id == request.Id) Prompt = null;
        }
        finally { NativeText.Wipe(block); }
    }

    public unsafe void ReplyTrust(NativePrompt request, bool allowed)
    {
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_session_reply_trust(handle.Raw, request.Id, request.Generation, allowed ? 1u : 0u, &error), &error);
        if (Prompt?.Id == request.Id) Prompt = null;
    }

    // ---- Delivery -------------------------------------------------------------------------

    private void Complete(in tidyvnc_event value)
    {
        Guid? token = null;
        foreach (var (key, request) in pending)
        {
            if (request.Operation.Id == value.operation && request.Operation.Generation == value.snapshot.generation) { token = key; break; }
        }
        if (token is null || !pending.Remove(token.Value, out var found)) return;
        if (found.Cancelled) { found.Completion.TrySetCanceled(); return; }
        var current = NativeSnapshot.From(value.snapshot);
        if (value.result == Tidyvnc.TIDYVNC_OPERATION_SUCCEEDED)
            found.Completion.TrySetResult(new NativeCompletion(found.Operation, current));
        else
            found.Completion.TrySetException(new NativeCommandFailure(found.Operation,
                Enum.IsDefined((NativeCommandFailure.ResultKind)value.result) ? (NativeCommandFailure.ResultKind)value.result : NativeCommandFailure.ResultKind.Failed,
                Enum.IsDefined((NativeCommandFailure.FailureReason)value.failure) ? (NativeCommandFailure.FailureReason)value.failure : NativeCommandFailure.FailureReason.None,
                value.native_result, current));
    }

    private void ObserveBell(NativeSnapshot value)
    {
        // Bell counts are per attempt; a new generation starts from zero.
        var previous = value.Generation == bellMark.Generation ? bellMark.Count : 0;
        bellMark = (value.Generation, value.Bells);
        if (value.Bells > previous) BellHandler?.Invoke();
    }

    private unsafe void Receive(ulong id, ulong deliveredGeneration)
    {
        if (IsClosing || subscription is null || subscription.Raw != id || deliveredGeneration != Generation) return;
        try
        {
            var error = Abi.Init<tidyvnc_error>();
            var value = Abi.Init<tidyvnc_event>();
            var consumed = 0;
            while (consumed < 128 &&
                   Abi.Check(NativeMethods.tidyvnc_session_take_event(handle.Raw, &value, &error), &error, NativeStatus.Ok, NativeStatus.NoChange) == NativeStatus.Ok)
            {
                consumed++;
                if (value.kind == Tidyvnc.TIDYVNC_EVENT_COMPLETION) Complete(value);
            }
            // A fast producer must not monopolize the UI thread: continue next turn.
            if (consumed == 128) delivery?.Signal(id, Generation);

            var current = Abi.Init<tidyvnc_snapshot>();
            Abi.Check(NativeMethods.tidyvnc_session_snapshot(handle.Raw, &current, &error), &error);
            if (current.generation == Generation)
            {
                var info = Abi.Init<tidyvnc_connection_info>();
                var status = Abi.Check(NativeMethods.tidyvnc_session_information(handle.Raw, Generation, &info, &error), &error,
                                       NativeStatus.Ok, NativeStatus.NotConnected, NativeStatus.Stale);
                var next = status == NativeStatus.Ok ? NativeConnectionInformation.From(info) : null;
                var snapshot = NativeSnapshot.From(status == NativeStatus.Ok ? info.snapshot : current, information: next);
                if (snapshot != Snapshot) Snapshot = snapshot;
                ObserveBell(snapshot);
                if (Snapshot.State != NativeSessionState.Authenticating && Prompt is not null) Prompt = null;
            }

            var view = Abi.Init<tidyvnc_view_update>();
            if (Abi.Check(NativeMethods.tidyvnc_session_take_view(handle.Raw, &view, &error), &error, NativeStatus.Ok, NativeStatus.NoChange) == NativeStatus.Ok)
            {
                // Own both handles before any fallible conversion; stale data is released here.
                var frameOwner = view.frame == 0 ? null : NativeHandle.Adopt(view.frame);
                var cursorOwner = view.cursor == 0 ? null : NativeHandle.Adopt(view.cursor);
                if (view.generation == Generation)
                {
                    if (view.frame_changed != 0)
                    {
                        var previous = Frame?.Sequence ?? 0;
                        Frame = frameOwner is null ? null : new NativeImage(frameOwner, previous,
                            new NativePixelRect(view.damage_x, view.damage_y, view.damage_width, view.damage_height), imageStream);
                        frameOwner = null;
                    }
                    if (view.cursor_changed != 0)
                    {
                        Cursor = cursorOwner is null ? null : new NativeImage(cursorOwner);
                        cursorOwner = null;
                    }
                }
                frameOwner?.Dispose(); cursorOwner?.Dispose();
            }

            ulong rawPrompt = 0;
            if (Abi.Check(NativeMethods.tidyvnc_session_take_prompt(handle.Raw, &rawPrompt, &error), &error, NativeStatus.Ok, NativeStatus.NoChange) == NativeStatus.Ok)
            {
                var prompt = NativePrompt.Adopt(rawPrompt);
                if (prompt.Generation == Generation) Prompt = prompt;
            }

            var update = Abi.Init<tidyvnc_clipboard_update>();
            if (Abi.Check(NativeMethods.tidyvnc_session_take_clipboard(handle.Raw, &update, &error), &error, NativeStatus.Ok, NativeStatus.NoChange) == NativeStatus.Ok)
            {
                var clipboard = NativeClipboardUpdate.From(update);
                if (clipboard.Kind == NativeClipboardUpdate.UpdateKind.Invalidated || clipboard.Route.Generation == Generation) Clipboard = clipboard;
                else clipboard.Text?.Dispose();
            }

            if (Snapshot.State is NativeSessionState.Closed or NativeSessionState.Failed)
            {
                Frame = null; Cursor = null; Prompt = null; Clipboard = null;
                desktopFocusOwner = null; IsFocused = false;
            }
        }
        catch (NativeError problem)
        {
            DeliveryError = problem;
            // A consumer failure must not strand an operation whose event was consumed.
            _ = BeginClose();
        }
    }

    // ---- Close ----------------------------------------------------------------------------

    /// <summary>Starts closing (idempotent). Invalidates routing before any await or native call.</summary>
    public Task BeginClose()
    {
        if (closeTask is not null) return closeTask;
        IsClosing = true;
        delivery?.Invalidate();
        Prompt = null; Frame = null; Cursor = null; Clipboard = null; desktopFocusOwner = null; IsFocused = false;
        var operations = pending.Values.ToList();
        pending.Clear();
        foreach (var request in operations) request.Completion.TrySetException(new NativeError(NativeStatus.Closing, "Session closed"));
        unsafe
        {
            _ = NativeMethods.tidyvnc_session_close(handle.Raw, null);
            if (subscription is not null) _ = NativeMethods.tidyvnc_subscription_unsubscribe(subscription.Raw, null);
            var closing = Abi.Init<tidyvnc_snapshot>();
            if (NativeMethods.tidyvnc_session_snapshot(handle.Raw, &closing, null) == Tidyvnc.TIDYVNC_OK)
                Snapshot = NativeSnapshot.From(closing, NativeSessionState.Disconnecting);
        }
        var participants = closeParticipants.ToList();
        closeTask = Close(participants);
        return closeTask;
    }

    private async Task Close(List<Func<Task>> participants)
    {
        Exception? failure = null;
        try { await NativeDrainer.WaitAsync(handle, NativeDrain.Session).ConfigureAwait(true); } catch (Exception e) { failure = e; }
        if (subscription is not null)
        {
            try { await NativeDrainer.WaitAsync(subscription, NativeDrain.Subscription).ConfigureAwait(true); }
            catch (Exception e) { failure ??= e; }
        }
        if (delivery is not null) await delivery.DrainAsync().ConfigureAwait(true);
        foreach (var participant in participants)
        {
            try { await participant().ConfigureAwait(true); } catch (Exception e) { failure ??= e; }
        }
        PublishFinalSnapshot();
        if (failure is not null) throw failure;
    }

    private unsafe void PublishFinalSnapshot()
    {
        var final = Abi.Init<tidyvnc_snapshot>();
        if (NativeMethods.tidyvnc_session_snapshot(handle.Raw, &final, null) == Tidyvnc.TIDYVNC_OK) Snapshot = NativeSnapshot.From(final);
    }

    public Task CloseAsync()
    {
        UiThread.Require(Dispatcher);
        return BeginClose();
    }

    ~NativeSession()
    {
        delivery?.Invalidate();
        unsafe
        {
            if (subscription is { IsClosed: false }) _ = NativeMethods.tidyvnc_subscription_unsubscribe(subscription.Raw, null);
            if (!handle.IsClosed) _ = NativeMethods.tidyvnc_session_close(handle.Raw, null);
        }
    }
}
