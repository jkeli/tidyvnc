// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

/// <summary>
/// Owns one core runtime (NativeRuntime.swift). UI-thread object: sessions and
/// listeners register weakly; shutdown begins closing all of them before
/// awaiting any.
/// </summary>
public sealed class NativeRuntime
{
    /// <summary>Capabilities the Windows app relies on; runtime creation fails without them.</summary>
    public const ulong RequiredFeatures =
        Tidyvnc.TIDYVNC_FEATURE_RUNTIME | Tidyvnc.TIDYVNC_FEATURE_TCP_UNIX_CONNECT | Tidyvnc.TIDYVNC_FEATURE_EVENT_POLL |
        Tidyvnc.TIDYVNC_FEATURE_IMAGES | Tidyvnc.TIDYVNC_FEATURE_INPUT | Tidyvnc.TIDYVNC_FEATURE_PROMPTS |
        Tidyvnc.TIDYVNC_FEATURE_CALLBACKS | Tidyvnc.TIDYVNC_FEATURE_GEOMETRY | Tidyvnc.TIDYVNC_FEATURE_CLIPBOARD |
        Tidyvnc.TIDYVNC_FEATURE_ENCODING | Tidyvnc.TIDYVNC_FEATURE_ENDPOINT_VALIDATION | Tidyvnc.TIDYVNC_FEATURE_SCALING |
        Tidyvnc.TIDYVNC_FEATURE_TILE_RENDERER | Tidyvnc.TIDYVNC_FEATURE_DAMAGE_GEOMETRY | Tidyvnc.TIDYVNC_FEATURE_CURSOR_RENDERER |
        Tidyvnc.TIDYVNC_FEATURE_INPUT_POLICY | Tidyvnc.TIDYVNC_FEATURE_SHORTCUTS | Tidyvnc.TIDYVNC_FEATURE_INPUT_RELEASE |
        Tidyvnc.TIDYVNC_FEATURE_CONNECTION_INFO | Tidyvnc.TIDYVNC_FEATURE_ENDPOINT_IDENTITY | Tidyvnc.TIDYVNC_FEATURE_PROMPT_SECURITY |
        Tidyvnc.TIDYVNC_FEATURE_CERTIFICATE_POLICY | Tidyvnc.TIDYVNC_FEATURE_HOST_KEY_ENCODING |
        Tidyvnc.TIDYVNC_FEATURE_REQUIRED_TLS_FILES | Tidyvnc.TIDYVNC_FEATURE_SECURITY_SELECTION |
        Tidyvnc.TIDYVNC_FEATURE_TLS_PRIORITY_VALIDATION | Tidyvnc.TIDYVNC_FEATURE_SECURITY_RECONFIGURATION |
        Tidyvnc.TIDYVNC_FEATURE_SHARED_SESSION | Tidyvnc.TIDYVNC_FEATURE_DESKTOP_LAYOUT | Tidyvnc.TIDYVNC_FEATURE_DISPLAY_LAYOUT |
        Tidyvnc.TIDYVNC_FEATURE_CANVAS_GEOMETRY | Tidyvnc.TIDYVNC_FEATURE_INPUT_TIMING | Tidyvnc.TIDYVNC_FEATURE_MESSAGE_LIMITS |
        Tidyvnc.TIDYVNC_FEATURE_WINDOW_GEOMETRY | Tidyvnc.TIDYVNC_FEATURE_ROUTED_CONNECT;

    internal NativeHandle Handle { get; }
    public IUiDispatcher Dispatcher { get; }
    private readonly List<WeakReference<NativeSession>> sessions = [];
    private readonly List<WeakReference<NativeListener>> listeners = [];
    private Task? shutdownTask;

    public unsafe NativeRuntime(IUiDispatcher dispatcher, uint sessionCapacity = 16)
    {
        Dispatcher = dispatcher;
        var options = Abi.Init<tidyvnc_runtime_options>();
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_runtime_options_init(&options, &error), &error);
        options.session_capacity = sessionCapacity;
        options.required_features = RequiredFeatures;
        ulong raw = 0;
        Abi.Check(NativeMethods.tidyvnc_runtime_create(&options, &raw, &error), &error);
        Handle = NativeHandle.Adopt(raw);
    }

    public bool IsShuttingDown => shutdownTask is not null;

    public NativeSession CreateSession(NativeSessionConfiguration? configuration = null)
    {
        UiThread.Require(Dispatcher);
        if (shutdownTask is not null) throw new NativeError(NativeStatus.Closing, "Runtime is shutting down");
        var session = new NativeSession(this, configuration ?? new NativeSessionConfiguration());
        sessions.RemoveAll(entry => !entry.TryGetTarget(out _));
        sessions.Add(new WeakReference<NativeSession>(session));
        return session;
    }

    public NativeListener CreateListener(NativeListenOptions? options = null)
    {
        UiThread.Require(Dispatcher);
        if (shutdownTask is not null) throw new NativeError(NativeStatus.Closing, "Runtime is shutting down");
        var listener = new NativeListener(this, options ?? new NativeListenOptions());
        listeners.RemoveAll(entry => !entry.TryGetTarget(out _));
        listeners.Add(new WeakReference<NativeListener>(listener));
        return listener;
    }

    /// <summary>Begins closing every listener and session, then awaits them and the runtime drain.</summary>
    public Task ShutdownAsync()
    {
        UiThread.Require(Dispatcher);
        return shutdownTask ??= Shutdown();
    }

    private async Task Shutdown()
    {
        var closing = new List<Task>();
        foreach (var entry in listeners) if (entry.TryGetTarget(out var listener)) closing.Add(listener.BeginClose());
        foreach (var entry in sessions) if (entry.TryGetTarget(out var session)) closing.Add(session.BeginClose());
        StartShutdown();
        Exception? failure = null;
        foreach (var task in closing)
        {
            try { await task.ConfigureAwait(true); } catch (Exception e) { failure ??= e; }
        }
        try { await NativeDrainer.WaitAsync(Handle, NativeDrain.Runtime).ConfigureAwait(true); } catch (Exception e) { failure ??= e; }
        if (failure is not null) throw failure;
    }

    private unsafe void StartShutdown()
    {
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_runtime_shutdown(Handle.Raw, &error), &error);
    }

    ~NativeRuntime()
    {
        unsafe { if (!Handle.IsClosed) _ = NativeMethods.tidyvnc_runtime_shutdown(Handle.Raw, null); }
    }

    /// <summary>The loaded core's ABI description (tidyvnc_get_abi).</summary>
    public static unsafe NativeAbiInfo GetAbi()
    {
        var info = Abi.Init<tidyvnc_abi_info>();
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_get_abi(&info, &error), &error);
        var types = new uint[Math.Min(info.security_count, 32u)];
        for (var i = 0; i < types.Length; i++) types[i] = info.security_types[i];
        return new NativeAbiInfo(info.features, info.handle_capacity, info.runtime_capacity, types);
    }
}

public sealed record NativeAbiInfo(ulong Features, uint HandleCapacity, uint RuntimeCapacity, IReadOnlyList<uint> SecurityTypes)
{
    public bool Supports(ulong feature) => (Features & feature) == feature;
}
