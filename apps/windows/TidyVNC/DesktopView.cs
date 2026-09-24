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
    // Cursors larger than Windows accepts are drawn here, over the desktop (DESKTOP.md section 3).
    private readonly Canvas cursorLayer = new() { IsHitTestVisible = false };
    private readonly StatisticsOverlay statistics = new();
    private readonly DesktopRenderer renderer;
    private readonly NativeKeyboard keyboard = new();
    private readonly NativeShortcutRouter shortcuts = new();
    private readonly UiTimer altGrTimer;
    // Touch gestures (DESKTOP.md section 6) and the buttons they hold; wheel remainders (section 4).
    private readonly NativeTouch touch = new();
    private readonly UiTimer touchTimer;
    private readonly NativeWheelAccumulator wheel = new();
    private uint touchButtons;
    /// <summary>A synthetic key identity for the pinch gesture's Ctrl, clear of real scan codes.</summary>
    private const uint TouchControlId = 0x210000;
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
#if DEBUG
        LiveObjects.Track(this);
#endif
        WindowHandle = window;
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(this, "desktop.view");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, Strings.Get("ssh.remote.desktop"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(this,
            Strings.Get("desktop.click.to.focus.keyboard.and.pointer.input.control.the.connected.computer"));
        host.Children.Add(panel);
        host.Children.Add(cursorLayer);
        host.Children.Add(statistics);
        Content = host;
        renderer = new DesktopRenderer(App.Current.Dispatcher, AttachPresenter);
#if DEBUG
        LiveObjects.Track(renderer);
        LiveObjects.Track(panel);
#endif
        renderer.Failed += error => RenderFailed?.Invoke(error);
        AttachPresenter(renderer.Presenter);
        panel.SizeChanged += (_, _) => UpdateViewport();
        panel.CompositionScaleChanged += (_, _) => UpdateViewport();
        host.PointerMoved += (sender, e) => { if (IsTouch(e)) OnTouch(e, TouchPhase.Update); else OnPointer(sender, e); };
        host.PointerPressed += (sender, e) => { if (IsTouch(e)) OnTouch(e, TouchPhase.Begin); else OnPointer(sender, e); };
        host.PointerReleased += (sender, e) => { if (IsTouch(e)) OnTouch(e, TouchPhase.End); else OnPointer(sender, e); };
        host.PointerCanceled += (sender, e) => { if (IsTouch(e)) OnTouch(e, TouchPhase.End); else OnPointer(sender, e); };
        host.PointerCaptureLost += (_, e) => { if (IsTouch(e)) OnTouch(e, TouchPhase.End); };
        host.PointerWheelChanged += OnWheel;
        host.PointerEntered += (_, _) => SurfaceEntered?.Invoke(this);
        host.PointerExited += (_, e) =>
        {
            if (IsTouch(e)) return;
            pointer = null;
            DrawSoftwareCursor();
        };
        GotFocus += (_, _) => SetKeyboardFocus(true);
        LostFocus += (_, _) => SetKeyboardFocus(false);
        altGrTimer = new UiTimer(() => Send(keyboard.Timeout().Events));
        touchTimer = new UiTimer(() => Apply(touch.Timeout()));
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
            if (session is not null)
            {
                session.FrameUpdated -= OnFrame;
                session.CursorUpdated -= OnCursor;
                session.PropertyChanged -= OnSessionProperty;
            }
            session = value;
            if (session is not null)
            {
                session.FrameUpdated += OnFrame;
                session.CursorUpdated += OnCursor;
                session.PropertyChanged += OnSessionProperty;
            }
            OnFrame(session?.Frame);
            UpdateCursor();
        }
    }

    // ---- Cursor (DESKTOP.md section 3, D13) -------------------------------------------

    private NativeCursorHandle? cursorHandle;
    private object? cursorKey;
    private NativeCursorTiles? softwareCursor;
    private readonly Dictionary<NativePixelRect, Image> softwareTiles = new();
    /// <summary>The mouse or pen over the view, logical units in the panel; null when it is elsewhere.</summary>
    private Windows.Foundation.Point? pointer;

    /// <summary>Where the mouse or pen is over this view, in its logical units; null when it is elsewhere.</summary>
    internal Windows.Foundation.Point? PointerPosition => pointer;
    private NativeCursorFallback cursorFallback = NativeCursorFallback.Hidden;

    /// <summary>What a blank remote cursor becomes (AlwaysCursor/CursorType): nothing, the dot or the system arrow.</summary>
    public NativeCursorFallback CursorFallback
    {
        get => cursorFallback;
        set { if (cursorFallback == value) return; cursorFallback = value; UpdateCursor(); }
    }

    private void OnCursor(NativeImage? cursor) => UpdateCursor();

    private void OnSessionProperty(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(NativeSession.IsViewOnly) or nameof(NativeSession.Snapshot)) UpdateCursor();
    }

    /// <summary>
    /// The pointer over the desktop follows the retained rules: the remote cursor scaled like the desktop
    /// (device pixels per remote pixel, the connection's filter), the dot, the system arrow or nothing.
    /// A remote cursor larger than Windows accepts is drawn over the desktop instead, with the pointer
    /// hidden there.
    /// </summary>
    private void UpdateCursor()
    {
        if (disposed) return;
        var image = Live ? session!.Cursor : null;
        var viewOnly = session?.IsViewOnly == true;
        if (!Live || geometry is not { } shape)
        {
            UseSoftwareCursor(null);
            SetCursor("system", null);
            return;
        }
        double scaleX = (double)shape.BackingWidth / shape.RemoteWidth, scaleY = (double)shape.BackingHeight / shape.RemoteHeight;
        NativeCursorRaster? remote = null;
        NativeCursorTiles? large = null;
        if (image is not null && !viewOnly && image.Width > 0 && image.Height > 0)
        {
            var (maxWidth, maxHeight) = NativeCursorHandle.Limits;
            try
            {
                if (!NativeCursorPolicy.NeedsSoftware(image.Width, image.Height, scaleX, scaleY, maxWidth, maxHeight))
                    remote = NativeCursorSampler.Sample(image, scaleX, scaleY, scaling.Filter);
                else if (softwareCursor is { } current && current.Samples(image, scaleX, scaleY, scaling.Filter))
                    large = current;
                else
                    large = new NativeCursorTiles(image, scaleX, scaleY, scaling.Filter);
            }
            catch (NativeError) { remote = null; }
        }
        var blank = large is not null ? large.Blank : remote is null or { Blank: true };
        var choice = NativeCursorPolicy.Choose(viewOnly, blank, cursorFallback);
        UseSoftwareCursor(choice == NativeCursorChoice.Remote ? large : null);
        if (large is not null && !ReferenceEquals(large, softwareCursor)) large.Dispose();
        switch (choice)
        {
            case NativeCursorChoice.Remote when softwareCursor is not null: DrawSoftwareCursor(); break;
            case NativeCursorChoice.Remote: SetCursor(("remote", image, scaleX, scaleY, scaling.Filter), remote); break;
            case NativeCursorChoice.Dot: SetCursor(("dot", shape.BackingScale), NativeCursorPolicy.Dot(shape.BackingScale)); break;
            case NativeCursorChoice.Hidden: SetCursor("hidden", NativeCursorPolicy.Hidden); break;
            default: SetCursor("system", null); break;
        }
    }

    private void SetCursor(object key, NativeCursorRaster? raster)
    {
        if (Equals(cursorKey, key)) return;
        cursorKey = key;
        var previous = cursorHandle;
        cursorHandle = null;
        if (raster is null) ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Arrow);
        else
        {
            try
            {
                var handle = new NativeCursorHandle(raster.Rgba, raster.Width, raster.Height, raster.HotspotX, raster.HotspotY);
                ProtectedCursor = InputCursors.FromHandle(handle.Handle);
                cursorHandle = handle;
            }
            catch (Exception error) when (error is System.Runtime.InteropServices.COMException or InvalidOperationException or ArgumentException)
            {
                System.Diagnostics.Trace.TraceWarning($"Remote cursor not shown ({error.GetType().Name} {error.HResult:x8}); using the arrow");
                // Debug builds stop here, so the protocol smokes (which send cursors) catch a broken conversion.
                System.Diagnostics.Debug.Fail("HCURSOR to InputCursor conversion failed: " + error.Message);
                ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Arrow);
            }
        }
        previous?.Dispose(); // The replaced InputCursor no longer uses it.
    }

    /// <summary>Switches to drawing these cursor tiles over the desktop, or back to real cursors (null).</summary>
    private void UseSoftwareCursor(NativeCursorTiles? tiles)
    {
        if (ReferenceEquals(tiles, softwareCursor)) return;
        softwareCursor?.Dispose();
        softwareCursor = tiles;
        softwareTiles.Clear();
        cursorLayer.Children.Clear();
    }

    /// <summary>
    /// The software cursor at the pointer (macOS clipping and motion reuse): only the tiles over the
    /// visible desktop are drawn, tiles already drawn are moved rather than sampled again, and the
    /// pointer is hidden while it is over the desktop and the system arrow elsewhere (the letterbox).
    /// </summary>
    private void DrawSoftwareCursor()
    {
        if (softwareCursor is not { } tiles || geometry is not { } shape) return;
        var q = shape.BackingScale;
        var clipLeft = Math.Max(0, shape.X);
        var clipTop = Math.Max(0, shape.Y);
        var clip = (X: clipLeft, Y: clipTop,
                    Width: Math.Max(0, Math.Min(shape.X + shape.Width, shape.ViewportWidth) - clipLeft),
                    Height: Math.Max(0, Math.Min(shape.Y + shape.Height, shape.ViewportHeight) - clipTop));
        var inside = pointer is { } at && at.X >= clip.X && at.Y >= clip.Y && at.X < clip.X + clip.Width && at.Y < clip.Y + clip.Height;
        if (inside) SetCursor("software", NativeCursorPolicy.Hidden);
        else SetCursor("system", null);
        var origin = pointer is { } p ? NativeCursorPolicy.SoftwareOrigin(p.X, p.Y, q, tiles.HotspotX, tiles.HotspotY) : (0.0, 0.0);
        var region = inside ? NativeCursorPolicy.VisibleRegion(tiles.Width, tiles.Height, origin, q, clip) : new NativePixelRect(0, 0, 0, 0);
        IReadOnlyList<NativeCursorTile> visible;
        try { visible = tiles.Render(region).Tiles; }
        catch (NativeError error)
        {
            System.Diagnostics.Trace.TraceWarning($"Software cursor not drawn: {error.Message}");
            visible = [];
        }
        var shown = new HashSet<NativePixelRect>();
        foreach (var tile in visible)
        {
            shown.Add(tile.Rect);
            if (!softwareTiles.TryGetValue(tile.Rect, out var element))
            {
                var bitmap = new Microsoft.UI.Xaml.Media.Imaging.WriteableBitmap((int)tile.Rect.Width, (int)tile.Rect.Height);
                using (var pixels = System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsStream(bitmap.PixelBuffer))
                    pixels.Write(tile.PremultipliedBgra());
                bitmap.Invalidate();
                element = new Image { Source = bitmap, Stretch = Stretch.Fill, Width = tile.Rect.Width / q, Height = tile.Rect.Height / q };
                // The pointer's picture, not content: hidden from Narrator and other assistive technology.
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(element, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
                softwareTiles[tile.Rect] = element;
                cursorLayer.Children.Add(element);
            }
            Microsoft.UI.Xaml.Controls.Canvas.SetLeft(element, origin.Item1 + tile.Rect.X / q);
            Microsoft.UI.Xaml.Controls.Canvas.SetTop(element, origin.Item2 + tile.Rect.Y / q);
        }
        foreach (var gone in softwareTiles.Keys.Where(rect => !shown.Contains(rect)).ToList())
        {
            cursorLayer.Children.Remove(softwareTiles[gone]);
            softwareTiles.Remove(gone);
        }
        cursorLayer.Clip = new RectangleGeometry { Rect = new Windows.Foundation.Rect(clip.X, clip.Y, clip.Width, clip.Height) };
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
        UpdateCursor();
        if (peer is not null && Microsoft.UI.Xaml.Automation.Peers.AutomationPeer.ListenerExists(Microsoft.UI.Xaml.Automation.Peers.AutomationEvents.PropertyChanged))
            peer.GeometryChanged();
    }

    private DesktopAutomationPeer? peer;

    /// <summary>The Scroll and Invoke patterns (UX.md section 10).</summary>
    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() => peer = new DesktopAutomationPeer(this);

    /// <summary>The geometry the Scroll pattern reports, while a desktop is shown.</summary>
    internal NativeGeometry? PanGeometry => Live ? geometry : null;

    /// <summary>Connection statistics over this view (Q03), or none.</summary>
    public void ShowStatistics(NativeConnectionInformation? information) => statistics.Show(information);

    // ---- Commands (Connection menu) ------------------------------------------------------

    /// <summary>The desktop's size in effective pixels at the current scaling (Resize window to desktop).</summary>
    public (double Width, double Height)? DesktopSize => geometry is { } value ? (value.Width, value.Height) : null;

    /// <summary>The desktop view's own size in effective pixels.</summary>
    public (double Width, double Height) ViewSize => (panel.ActualWidth, panel.ActualHeight);

    public bool CanPan(NativeDesktopPan direction) => Live && geometry is { } value && value.Panned(direction) != value.PanPosition;

    /// <summary>Pans to Scroll pattern percentages; -1 keeps an axis.</summary>
    public bool PanTo(double percentX, double percentY)
    {
        if (!Live || geometry is null) return false;
        pan = geometry.PannedTo(percentX, percentY);
        UpdateViewport();
        return true;
    }

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

    /// <summary>Mouse buttons including back and forward; a pen as a mouse (tip left, barrel right, eraser ignored).</summary>
    private static uint ButtonMask(PointerRoutedEventArgs e, PointerPointProperties properties) =>
        e.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Pen
            ? NativePointerButtons.Pen(properties.IsLeftButtonPressed, properties.IsBarrelButtonPressed, properties.IsEraser)
            : NativePointerButtons.Mouse(properties.IsLeftButtonPressed, properties.IsMiddleButtonPressed, properties.IsRightButtonPressed,
                                         properties.IsXButton1Pressed, properties.IsXButton2Pressed);

    private static bool IsTouch(PointerRoutedEventArgs e) => e.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Touch;

    private void OnPointer(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(panel);
        pointer = point.Position;
        if (softwareCursor is not null) DrawSoftwareCursor();
        if (point.Properties.PointerUpdateKind is PointerUpdateKind.LeftButtonPressed or PointerUpdateKind.MiddleButtonPressed
            or PointerUpdateKind.RightButtonPressed or PointerUpdateKind.XButton1Pressed or PointerUpdateKind.XButton2Pressed)
        {
            Focus(FocusState.Pointer);
            host.CapturePointer(e.Pointer);
        }
        if (!Live || geometry is null) return;
        buttons = ButtonMask(e, point.Properties);
        SendPointer(point.Position.X, point.Position.Y, buttons);
        if (buttons == 0) host.ReleasePointerCapture(e.Pointer);
        e.Handled = true;
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        if (!Live || geometry is null) return;
        var point = e.GetCurrentPoint(panel);
        var horizontal = point.Properties.IsHorizontalMouseWheel;
        // Partial deltas (high-resolution wheels, precision touchpads) carry over to whole notches.
        var notches = wheel.Add(point.Properties.MouseWheelDelta, horizontal);
        e.Handled = true;
        if (notches == 0) return;
        // RFB buttons 4/5 (up/down) and 6/7 (left/right), one click per notch.
        var bit = horizontal ? (notches > 0 ? NativePointerButtons.WheelRight : NativePointerButtons.WheelLeft)
            : (notches > 0 ? NativePointerButtons.WheelUp : NativePointerButtons.WheelDown);
        for (var i = 0; i < Math.Abs(notches); i++)
        {
            SendPointer(point.Position.X, point.Position.Y, buttons | bit);
            SendPointer(point.Position.X, point.Position.Y, buttons);
        }
        e.Handled = true;
    }

    // ---- Touch ----------------------------------------------------------------------

    private enum TouchPhase { Begin, Update, End }

    /// <summary>Touches go through the retained gesture model; they are converted to remote coordinates once, when sent.</summary>
    private void OnTouch(PointerRoutedEventArgs e, TouchPhase phase)
    {
        e.Handled = true;
        var id = (int)e.Pointer.PointerId;
        if (phase == TouchPhase.Begin)
        {
            Focus(FocusState.Pointer);
            host.CapturePointer(e.Pointer);
        }
        if (phase == TouchPhase.End) host.ReleasePointerCapture(e.Pointer);
        if (disposed) return;
        var point = e.GetCurrentPoint(panel).Position;
        Apply(phase switch
        {
            TouchPhase.Begin => touch.Begin(id, point.X, point.Y),
            TouchPhase.Update => touch.Update(id, point.X, point.Y),
            _ => touch.End(id),
        });
    }

    private void Apply(IReadOnlyList<NativeTouchAction> actions)
    {
        touchTimer.Stop();
        if (touch.Deadline is { } due)
        {
            touchTimer.Interval = TimeSpan.FromMilliseconds(Math.Max(0, (long)due - Environment.TickCount64));
            touchTimer.Start();
        }
        if (!Live || geometry is null)
        {
            touchButtons = 0;
            return;
        }
        foreach (var action in actions)
        {
            switch (action.Kind)
            {
                case NativeTouchAction.ActionKind.Motion:
                    SendPointer(action.X, action.Y, touchButtons);
                    break;
                case NativeTouchAction.ActionKind.Button:
                    var bit = NativePointerButtons.FromButtonNumber(action.Button);
                    touchButtons = action.Press ? touchButtons | bit : touchButtons & ~bit;
                    SendPointer(action.X, action.Y, touchButtons);
                    break;
                case NativeTouchAction.ActionKind.Key:
                    // The pinch gesture's Ctrl (XK_Control_L, QEMU key code 0x1d), held around its wheel clicks.
                    try { session!.SendKey(TouchControlId, action.KeySym, 0x1d, action.Press); }
                    catch (NativeError) { }
                    break;
            }
        }
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
        wheel.Reset();
        touchButtons = 0;
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
        altGrTimer.Dispose();
        touchTimer.Dispose();
        UseSoftwareCursor(null);
        cursorHandle?.Dispose();
        cursorHandle = null;
        renderer.Dispose();
        keyboard.Dispose();
        touch.Dispose();
        shortcuts.Dispose();
    }
}
