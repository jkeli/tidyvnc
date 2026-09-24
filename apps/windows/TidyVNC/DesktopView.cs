// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TidyVNC.Native;
using TidyVNC.Native.Desktop;
using TidyVNC.Native.Platform;

namespace TidyVNC;

/// <summary>
/// A session's desktop (DESKTOP.md sections 1-5): a SwapChainPanel presented
/// by a <see cref="DesktopRenderer"/>, pointer input mapped through the shared
/// transform, and keyboard input from the <see cref="KeyboardRouter"/> hook
/// through the retained Windows translator.
/// </summary>
internal sealed partial class DesktopView : UserControl, IDisposable, INativeDesktopCommandHost
{
    // SwapChainPanel takes no Background; the host grid is black and hit-testable.
    private readonly SwapChainPanel panel = new();
    private readonly Grid host = new() { Background = new SolidColorBrush(Colors.Black) };
    private readonly DesktopRenderer renderer;
    private readonly NativeKeyboard keyboard = new();
    private readonly NativeShortcutRouter shortcuts = new();
    private readonly DispatcherQueueTimer altGrTimer;
    private NativeSession? session;
    private NativeGeometry? geometry;
    private (uint Width, uint Height)? frameSize;
    private uint buttons;
    private bool disposed, keyboardFocused;
    private NativeScaling scaling = NativeScaling.BuiltIn;
    private NativeCanvasViewport? canvas;
    private NativeShortcutModifiers shortcutModifiers = NativeShortcutModifiers.BuiltIn;
    private (double X, double Y) pan;

    /// <summary>The largest backing store a Direct3D 11 texture can hold on any feature level we require.</summary>
    private const uint MaximumBacking = 16384;

    public DesktopView(IntPtr window)
    {
        WindowHandle = window;
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(this, "desktop.view");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, "Remote desktop");
        host.Children.Add(panel);
        Content = host;
        renderer = new DesktopRenderer(App.Current.Dispatcher, AttachPresenter);
        renderer.Failed += error => RenderFailed?.Invoke(error);
        AttachPresenter(renderer.Presenter);
        panel.SizeChanged += (_, _) => UpdateViewport();
        panel.CompositionScaleChanged += (_, _) => UpdateViewport();
        host.PointerMoved += OnPointer;
        host.PointerPressed += OnPointer;
        host.PointerReleased += OnPointer;
        host.PointerCanceled += OnPointer;
        host.PointerWheelChanged += OnWheel;
        host.PointerEntered += (_, _) => SurfaceEntered?.Invoke(this);
        GotFocus += (_, _) => SetKeyboardFocus(true);
        LostFocus += (_, _) => SetKeyboardFocus(false);
        altGrTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        altGrTimer.IsRepeating = false;
        altGrTimer.Tick += (_, _) => Send(keyboard.Timeout().Events);
        systemKeys = new NativeWindowsKeyboardCapture(window);
        Capture = new NativeKeyboardCaptureController(systemKeys, () => keyboardFocused && !disposed && session is not null, ReleaseKeys);
    }

    private readonly NativeWindowsKeyboardCapture systemKeys;

    /// <summary>System-key capture for this desktop (SERVICES.md section 8); commands and fullscreen drive it.</summary>
    public NativeKeyboardCaptureController Capture { get; }

    public IntPtr WindowHandle { get; }
    public DesktopRenderer Renderer => renderer;
    public event Action<Exception>? RenderFailed;
    /// <summary>A viewer shortcut other than remote input (full screen, keyboard capture, context menu), raised after the key is handled.</summary>
    public event Action<DesktopView, NativeShortcutDecision.RouteKind>? Command;
    /// <summary>This view's size, scale and scaling changed (automatic remote resize follows it).</summary>
    public event Action<NativeResizeViewport>? ViewportChanged;
    /// <summary>This view gained keyboard focus (menu commands then act on it).</summary>
    public event Action<DesktopView>? FocusAcquired;
    /// <summary>A physical Ctrl or Alt release was sent to the server (Hold Ctrl/Alt press it again).</summary>
    public event Action<uint>? ModifierReleased;
    /// <summary>A viewer shortcut released the remote keys.</summary>
    public event Action? InputReleased;
    /// <summary>The pointer entered this surface (full-screen surfaces follow the pointer).</summary>
    public event Action<DesktopView>? SurfaceEntered;

    public NativeSession? Session
    {
        get => session;
        set
        {
            if (ReferenceEquals(session, value)) return;
            if (session is not null) session.FrameUpdated -= OnFrame;
            session = value;
            if (session is not null) session.FrameUpdated += OnFrame;
            OnFrame(session?.Frame);
        }
    }

    private void AttachPresenter(NativePresenter presenter)
    {
        if (disposed) return;
        var unknown = ((WinRT.IWinRTObject)panel).NativeObject.ThisPtr;
        try { presenter.Attach(unknown); }
        catch (ObjectDisposedException) { } // Replaced again before this attach ran.
    }

    private void OnFrame(NativeImage? frame)
    {
        renderer.Submit(frame);
        var size = frame is null ? ((uint, uint)?)null : (frame.Width, frame.Height);
        if (size != frameSize) { frameSize = size; UpdateGeometry(); }
    }

    /// <summary>The connection's scaling (Z01-Z12): mode, units and filter reach the renderer and pointer mapping.</summary>
    public NativeScaling Scaling
    {
        get => scaling;
        set
        {
            if (scaling == value) return;
            if (scaling.Canonical != value.Canonical || scaling.DevicePixels != value.DevicePixels) pan = (0, 0);
            scaling = value;
            UpdateViewport();
        }
    }

    /// <summary>This surface's region of a shared full-screen canvas, or null for the whole desktop.</summary>
    public NativeCanvasViewport? Canvas
    {
        get => canvas;
        set
        {
            if (canvas == value) return;
            canvas = value;
            UpdateViewport();
        }
    }

    /// <summary>The connection's viewer shortcut modifiers (K07-K09).</summary>
    public NativeShortcutModifiers ShortcutModifiers
    {
        get => shortcutModifiers;
        set
        {
            if (shortcutModifiers == value) return;
            shortcutModifiers = value;
            shortcuts.SetModifiers(value);
        }
    }

    /// <summary>
    /// Whether this view can render a scaling for its current desktop and
    /// size (macOS validateScaling): the backing store must fit a texture.
    /// </summary>
    public bool CanRender(NativeScaling value)
    {
        double width = panel.ActualWidth, height = panel.ActualHeight, scale = panel.CompositionScaleX;
        if (frameSize is not { } size || width <= 0 || height <= 0 || scale <= 0) return true;
        try
        {
            var candidate = new NativeGeometry(size.Width, size.Height, width, height, scale, value.Canonical, value.DevicePixels);
            return candidate.BackingWidth is > 0 and <= MaximumBacking && candidate.BackingHeight is > 0 and <= MaximumBacking;
        }
        catch (NativeError) { return false; }
    }

    private void UpdateViewport()
    {
        double width = panel.ActualWidth, height = panel.ActualHeight, scale = panel.CompositionScaleX;
        if (width <= 0 || height <= 0 || scale <= 0) return;
        renderer.Resize(new DesktopViewport((uint)Math.Ceiling(width * scale), (uint)Math.Ceiling(height * scale), width, height, scale,
            scaling.Canonical, scaling.Filter, scaling.DevicePixels, canvas, pan.X, pan.Y));
        UpdateGeometry();
        ViewportChanged?.Invoke(Viewport);
    }

    /// <summary>The current size for automatic resizing; a canvas region is never a source on its own.</summary>
    public NativeResizeViewport Viewport
    {
        get
        {
            double width = panel.ActualWidth, height = panel.ActualHeight, scale = panel.CompositionScaleX;
            return new NativeResizeViewport(width, height, scale, scaling.Mode == NativeScalingMode.Unscaled, scaling.DevicePixels,
                width > 0 && height > 0 && scale > 0 && canvas is null && !disposed);
        }
    }

    private void UpdateGeometry()
    {
        double width = panel.ActualWidth, height = panel.ActualHeight, scale = panel.CompositionScaleX;
        geometry = frameSize is { } size && width > 0 && height > 0 && scale > 0
            ? new NativeGeometry(size.Width, size.Height, width, height, scale, scaling.Canonical, scaling.DevicePixels, pan.X, pan.Y, canvas)
            : null;
    }

    // ---- Commands (Connection menu) ------------------------------------------------------

    /// <summary>The desktop's size in effective pixels at the current scaling (Resize window to desktop).</summary>
    public (double Width, double Height)? DesktopSize => geometry is { } value ? (value.Width, value.Height) : null;

    /// <summary>The desktop view's own size in effective pixels.</summary>
    public (double Width, double Height) ViewSize => (panel.ActualWidth, panel.ActualHeight);

    public bool CanPan(NativeDesktopPan direction) => Live && geometry is { } value && value.Panned(direction) != value.PanPosition;

    public bool Pan(NativeDesktopPan direction)
    {
        if (!CanPan(direction)) return false;
        pan = geometry!.Panned(direction);
        UpdateViewport();
        return true;
    }

    public bool FocusForCommand()
    {
        if (disposed || session is null) return false;
        if (!keyboardFocused) Focus(FocusState.Programmatic);
        return keyboardFocused;
    }

    public void ClearCommandInput()
    {
        if (disposed) return;
        altGrTimer.Stop();
        keyboard.Reset();
        shortcuts.Reset();
    }

    private bool Live => session is { IsClosing: false } s && s.Snapshot.State == NativeSessionState.Connected;

    // ---- Pointer --------------------------------------------------------------------

    private static uint ButtonMask(PointerPointProperties properties) =>
        (properties.IsLeftButtonPressed ? 1u : 0) | (properties.IsMiddleButtonPressed ? 2u : 0) | (properties.IsRightButtonPressed ? 4u : 0);

    private void OnPointer(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(panel);
        if (point.Properties.PointerUpdateKind is PointerUpdateKind.LeftButtonPressed or PointerUpdateKind.MiddleButtonPressed
            or PointerUpdateKind.RightButtonPressed)
        {
            Focus(FocusState.Pointer);
            host.CapturePointer(e.Pointer);
        }
        if (!Live || geometry is null) return;
        buttons = ButtonMask(point.Properties);
        SendPointer(point.Position.X, point.Position.Y, buttons);
        if (buttons == 0) host.ReleasePointerCapture(e.Pointer);
        e.Handled = true;
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        if (!Live || geometry is null) return;
        var point = e.GetCurrentPoint(panel);
        var delta = point.Properties.MouseWheelDelta;
        // RFB buttons 4/5 (up/down) and 6/7 (left/right), one click per notch.
        var bit = point.Properties.IsHorizontalMouseWheel ? (delta > 0 ? 64u : 32u) : (delta > 0 ? 8u : 16u);
        var clicks = Math.Max(1, Math.Abs(delta) / 120);
        for (var i = 0; i < clicks; i++)
        {
            SendPointer(point.Position.X, point.Position.Y, buttons | bit);
            SendPointer(point.Position.X, point.Position.Y, buttons);
        }
        e.Handled = true;
    }

    private void SendPointer(double x, double y, uint mask)
    {
        var (remoteX, remoteY) = geometry!.RemotePoint(x, y);
        try { session!.SendPointer(remoteX, remoteY, mask); }
        catch (NativeError) { } // Stale or closing: the attempt ended under us.
    }

    // ---- Keyboard -------------------------------------------------------------------

    /// <summary>From the UI-thread hook; true swallows the message.</summary>
    public bool HandleKeyMessage(TvwKeyMessage message)
    {
        if (!Live) return false;
        var result = keyboard.Translate(message);
        Send(result.Events);
        altGrTimer.Stop();
        if (result.TimerDelay is { } delay)
        {
            altGrTimer.Interval = delay;
            altGrTimer.Start();
        }
        return result.Consumed;
    }

    private void Send(IReadOnlyList<NativeKeyEvent> events)
    {
        if (session is null) return;
        foreach (var key in events)
        {
            // Viewer shortcuts come first (the retained Space bypass and chord rules).
            NativeShortcutDecision decision;
            try
            {
                decision = key.Press
                    ? shortcuts.Press(key.SystemKeyCode, key.KeySym, () => keyboard.KeySyms(key.SystemKeyCode))
                    : shortcuts.Release(key.SystemKeyCode);
            }
            catch (NativeError)
            {
                shortcuts.Reset();
                decision = new(NativeShortcutDecision.RouteKind.Suppress, true);
            }
            if (decision.ReleaseRemoteKeys)
            {
                try { session.ReleaseInput(); }
                catch (NativeError) { }
                InputReleased?.Invoke();
            }
            switch (decision.Route)
            {
                case NativeShortcutDecision.RouteKind.Remote:
                    try { session.SendKey((uint)key.SystemKeyCode, key.KeySym, key.KeyCode, key.Press); }
                    catch (NativeError) { return; }
                    if (!key.Press && key.KeySym is 0xffe3 or 0xffe4 or 0xffe9 or 0xffea) ModifierReleased?.Invoke(key.KeySym);
                    break;
                case NativeShortcutDecision.RouteKind.ReleaseKeyboard:
                    Capture.ReleaseForCommand();
                    break;
                case NativeShortcutDecision.RouteKind.CaptureKeyboard or NativeShortcutDecision.RouteKind.ToggleFullscreen
                    or NativeShortcutDecision.RouteKind.ContextMenu:
                    // After the hook returns: the command may change windows and focus.
                    var route = decision.Route;
                    DispatcherQueue.TryEnqueue(() => { if (!disposed) Command?.Invoke(this, route); });
                    break;
            }
        }
    }

    private void SetKeyboardFocus(bool focused)
    {
        var router = App.Current.Keyboard;
        if (focused) router.Focused = this;
        else if (ReferenceEquals(router.Focused, this)) router.Focused = null;
        if (!focused) ReleaseKeys();
        try { if (session is { IsClosing: false } s) s.SetFocused(focused); }
        catch (NativeError) { }
        keyboardFocused = focused;
        Capture?.FocusChanged(focused);
        if (focused) FocusAcquired?.Invoke(this);
    }

    /// <summary>Window deactivation and focus loss release everything held.</summary>
    public void ReleaseKeys()
    {
        if (disposed) return;
        altGrTimer.Stop();
        keyboard.Reset();
        shortcuts.Reset();
        try { if (session is { IsClosing: false } s) s.ReleaseInput(); }
        catch (NativeError) { }
    }

    public void Dispose()
    {
        if (disposed) return;
        SetKeyboardFocus(false);
        Capture.Close();
        systemKeys.Dispose();
        disposed = true;
        Session = null;
        altGrTimer.Stop();
        renderer.Dispose();
        keyboard.Dispose();
        shortcuts.Dispose();
    }
}
