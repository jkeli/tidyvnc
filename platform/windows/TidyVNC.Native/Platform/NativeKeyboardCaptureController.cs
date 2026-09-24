// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
namespace TidyVNC.Native.Platform;

/// <summary>Why a capture start failed. Windows needs no permission, so only failures remain.</summary>
public enum NativeKeyboardCaptureStart { Active, Failed }

/// <summary>A system keyboard capture (NativeKeyboardCapturing on macOS).</summary>
public interface INativeKeyboardCapturing
{
    bool IsActive { get; }
    NativeKeyboardCaptureStart Start();
    void Stop();
}

/// <summary>
/// The helper DLL's WH_KEYBOARD_LL capture for one window (tvw_capture_*):
/// its own hook thread, the retained win32.c pass-through rules (lock keys
/// pass; keys already down when capture started pass their release).
/// Ctrl+Alt+Del, Win+L and keys for elevated windows cannot be captured.
/// </summary>
public sealed class NativeWindowsKeyboardCapture(nint window) : INativeKeyboardCapturing, IDisposable
{
    private NativeKeyboardCapture? capture;

    public bool IsActive => capture is not null;

    public NativeKeyboardCaptureStart Start()
    {
        if (capture is not null) return NativeKeyboardCaptureStart.Active;
        try { capture = new NativeKeyboardCapture(window); }
        catch (WindowsHelperException) { return NativeKeyboardCaptureStart.Failed; }
        return NativeKeyboardCaptureStart.Active;
    }

    public void Stop()
    {
        capture?.Dispose();
        capture = null;
    }

    public void Dispose() => Stop();
}

/// <summary>Why capture ended; the window shows a notice for the failures.</summary>
public enum NativeKeyboardCaptureRelease
{
    /// <summary>The desktop lost focus, the window was deactivated or a dialog opened.</summary>
    FocusLost,
    /// <summary>The user released capture (menu, shortcut) or left fullscreen.</summary>
    Command,
    Sleep,
    Lock,
    /// <summary>The system-keys policy was turned off.</summary>
    PolicyChanged,
    Disconnected,
    Closed,
    /// <summary>The capture stopped on its own; Capture keyboard retries.</summary>
    Ended,
}

public enum NativeKeyboardCaptureFailure { Unavailable, Failed }

public sealed class NativeKeyboardCaptureException(NativeKeyboardCaptureFailure failure) : Exception($"Keyboard capture {failure}")
{
    public NativeKeyboardCaptureFailure Failure { get; } = failure;
}

/// <summary>
/// When a desktop captures system keys (SERVICES.md section 8, DESKTOP.md
/// section 5; the macOS NativeDesktopView capture rules). Capture is held
/// only while the desktop is eligible (focused, window active, no dialog):
/// automatically once per fullscreen entry when Capture system keys in full
/// screen is on, or after the explicit Capture keyboard command. Losing
/// eligibility, sleep, lock, a policy change, disconnect or close releases it
/// and the remote's pressed keys; an explicit release or a failed or ended
/// capture suppresses automatic recapture until the next fullscreen entry
/// or focus change. UI thread only.
/// </summary>
public sealed class NativeKeyboardCaptureController(INativeKeyboardCapturing capture, Func<bool> eligible, Action releaseInput)
{
    private bool wasActive, suppressed, automaticAttempted, fullscreen, fullscreenSystemKeys, closed;

    /// <summary>Raised with the new state and, when capture ended unexpectedly or failed, why.</summary>
    public event Action<bool, NativeKeyboardCaptureRelease?, NativeKeyboardCaptureFailure?>? Changed;

    public bool IsCapturing => wasActive && capture.IsActive;

    public void SetFullscreen(bool enabled)
    {
        if (fullscreen == enabled) return;
        fullscreen = enabled;
        automaticAttempted = false;
        if (!enabled)
        {
            Release(NativeKeyboardCaptureRelease.Command, suppress: false);
            suppressed = false;
        }
        Update();
    }

    public void SetFullscreenSystemKeys(bool enabled)
    {
        if (fullscreenSystemKeys == enabled) return;
        fullscreenSystemKeys = enabled;
        automaticAttempted = false;
        if (!enabled && wasActive) Release(NativeKeyboardCaptureRelease.PolicyChanged, suppress: false);
        Update();
    }

    /// <summary>Focus and activation changes: a new focus interval may capture automatically again.</summary>
    public void FocusChanged(bool focused)
    {
        if (!focused) { suppressed = false; automaticAttempted = false; }
        Update();
    }

    /// <summary>Re-evaluates eligibility and automatic capture (call after any relevant change).</summary>
    public void Update()
    {
        if (closed) return;
        if (!eligible())
        {
            Release(NativeKeyboardCaptureRelease.FocusLost, suppress: false);
            return;
        }
        if (wasActive && !capture.IsActive)
        {
            capture.Stop();
            wasActive = false;
            suppressed = true;
            releaseInput();
            Changed?.Invoke(false, NativeKeyboardCaptureRelease.Ended, null);
        }
        if (fullscreenSystemKeys && fullscreen && !suppressed && !automaticAttempted && !capture.IsActive)
        {
            automaticAttempted = true;
            try { Capture(); }
            catch (NativeKeyboardCaptureException) { /* The notice already reports it; no focus-stealing alert. */ }
        }
    }

    /// <summary>The Capture keyboard command.</summary>
    public void Capture()
    {
        if (closed || !eligible()) throw new NativeKeyboardCaptureException(NativeKeyboardCaptureFailure.Unavailable);
        if (capture.Start() != NativeKeyboardCaptureStart.Active)
        {
            wasActive = false;
            suppressed = true;
            Changed?.Invoke(false, null, NativeKeyboardCaptureFailure.Failed);
            throw new NativeKeyboardCaptureException(NativeKeyboardCaptureFailure.Failed);
        }
        wasActive = true;
        suppressed = false;
        Changed?.Invoke(true, null, null);
    }

    /// <summary>The Release keyboard command: no automatic recapture until the next fullscreen entry or focus change.</summary>
    public void ReleaseForCommand() => Release(NativeKeyboardCaptureRelease.Command, suppress: true);

    /// <summary>Sleep, lock, disconnect: release now; eligibility decides afterwards.</summary>
    public void Release(NativeKeyboardCaptureRelease reason) => Release(reason, suppress: reason is NativeKeyboardCaptureRelease.Command);

    public void Close()
    {
        Release(NativeKeyboardCaptureRelease.Closed, suppress: true);
        closed = true;
    }

    private void Release(NativeKeyboardCaptureRelease reason, bool suppress)
    {
        var active = wasActive || capture.IsActive;
        capture.Stop();
        if (suppress) suppressed = true;
        if (!active) return;
        wasActive = false;
        // Keys pressed while captured must not stay down on the remote side.
        releaseInput();
        Changed?.Invoke(false, reason, null);
    }
}
