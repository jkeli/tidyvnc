// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Immutable;
using System.ComponentModel;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TidyVNC.Native;
using TidyVNC.Native.Desktop;
using TidyVNC.Native.Platform;

namespace TidyVNC;

/// <summary>
/// One connection window's full-screen presentation (DESKTOP.md section 7;
/// macOS NativeFullscreenController). The current display uses the window's
/// own FullScreenPresenter with its chrome collapsed. All or selected
/// displays get one owned, borderless full-screen window per display, each
/// with its own swap chain showing that display's region of a shared canvas;
/// the connection window hides meanwhile. Surfaces are created and bound
/// before anything is shown, so a failure leaves the window as it was. A
/// topology change or the end of the connection closes full screen.
/// </summary>
internal sealed class FullscreenHost : IDisposable
{
    private sealed record Surface(Window Window, DesktopView View, NativeDisplayInfo Display);

    private readonly ConnectionWindow owner;
    private readonly NativeFullscreenState state;
    private readonly NativeDisplayService displays;
    private readonly List<Surface> surfaces = [];
    private ImmutableArray<NativeDisplayInfo> topology = [];
    private bool presenter, closing, disposed;
    private FullscreenConnectionBar? bar;
    private Grid? barLayer;
    private readonly PointerEventHandler barPointer;
    private readonly Guid canvasSource = Guid.NewGuid();
    private NativeRemoteResizeCoordinator Resize => owner.Controller.RemoteResize;

    public FullscreenHost(ConnectionWindow owner, NativeFullscreenState state, NativeDisplayService displays)
    {
        this.owner = owner; this.state = state; this.displays = displays;
        displays.PropertyChanged += DisplaysChanged;
        barPointer = (sender, e) => { if (sender is UIElement layer) bar?.PointerMovedOnSurface(e, layer); };
    }

    public NativeFullscreenState State => state;
    public bool IsFullscreen => state.Phase != NativeFullscreenPhase.Windowed;
    /// <summary>The desktop views showing the connection now (the window's own, or the surfaces').</summary>
    public IEnumerable<DesktopView> Views => surfaces.Count > 0 ? surfaces.Select(s => s.View) : [owner.Desktop];

    public void Toggle()
    {
        if (IsFullscreen) Exit();
        else TryEnter(automatic: false);
    }

    /// <summary>Enters with the connection's policy; a failure is reported in the window and leaves it unchanged.</summary>
    public bool TryEnter(bool automatic)
    {
        try
        {
            Enter();
            return true;
        }
        catch (Exception error) when (error is NativeError or NativeDisplayException or ArgumentException or InvalidOperationException
                                          or System.Runtime.InteropServices.COMException)
        {
            System.Diagnostics.Trace.TraceWarning($"Full screen failed: {error}");
            var message = NativePresentationIssues.From(error, NativePresentationContext.Fullscreen).Message();
            if (automatic) state.AutomaticEntryFailed(message);
            else state.Message = message;
            return false;
        }
    }

    private void Enter()
    {
        if (disposed || IsFullscreen || !state.Connected || owner.Session is not { } session)
            throw new NativeError(NativeStatus.NotConnected, "Full screen needs a connection");
        displays.Refresh();
        var snapshot = displays.Snapshot;
        if (snapshot.Error is not null || snapshot.Displays.IsEmpty) throw new NativeDisplayException(snapshot.Error ?? NativeDisplayError.Unavailable);
        var current = owner.CurrentDisplayId;
        var policy = state.Policy;
        var selection = policy.Mode switch
        {
            NativeFullscreenMode.Current => snapshot.Resolve([], current),
            NativeFullscreenMode.All => new NativeDisplaySelection(snapshot.Displays, [], false),
            _ => snapshot.Resolve(policy.SelectedDisplays, current),
        };
        if (selection.Displays.IsEmpty) throw new NativeDisplayException(NativeDisplayError.Unavailable);
        state.Message = selection.Missing.IsEmpty ? null
            : new NativeText("desktop.fullscreen.some.selected.displays.are.unavailable.full.screen.uses.the.available.displays");
        topology = snapshot.Displays;

        if (policy.Mode == NativeFullscreenMode.Current || (selection.Displays.Length == 1 && selection.Displays[0].Id == current))
        {
            state.SetPhase(NativeFullscreenPhase.Entering);
            owner.Desktop.ReleaseKeys();
            presenter = true;
            owner.SetFullscreenChrome(true);
            owner.AppWindow.SetPresenter(AppWindowPresenterKind.FullScreen);
            owner.Desktop.Capture.SetFullscreen(true);
            AddBar(owner.DesktopLayer);
            state.SetPhase(NativeFullscreenPhase.Active);
            return;
        }

        var scaling = owner.Controller.Scaling.Value;
        var layout = new NativeDisplayLayout(selection.Displays, !scaling.Mode.Fits() && scaling.DevicePixels);
        // The main surface is the current display when chosen, else the primary, else the first.
        var main = selection.Displays.FirstOrDefault(d => d.Id == current) ?? selection.Displays.FirstOrDefault(d => d.IsPrimary) ?? selection.Displays[0];
        state.SetPhase(NativeFullscreenPhase.Entering);
        owner.Desktop.ReleaseKeys();
        Resize.BeginCanvas(canvasSource);
        try
        {
            foreach (var display in selection.Displays.OrderBy(d => d.Id == main.Id ? 0 : 1))
                surfaces.Add(CreateSurface(session, display, layout.Viewport(display.Id), scaling));
        }
        catch
        {
            Finish(restore: true, disconnected: false, message: null);
            throw;
        }
        owner.AppWindow.Hide();
        foreach (var surface in surfaces.AsEnumerable().Reverse()) surface.Window.Activate();
        surfaces[0].View.Focus(FocusState.Programmatic);
        state.SetPhase(NativeFullscreenPhase.Active);
        Resize.UpdateCanvas(canvasSource, layout, scaling.Mode == NativeScalingMode.Unscaled, available: true);
    }

    private Surface CreateSurface(NativeSession session, NativeDisplayInfo display, NativeCanvasViewport canvas, NativeScaling scaling)
    {
        var window = new Window { Title = owner.Title };
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(window);
        NativeWindows.SetOwner(handle, owner.Handle);
        var view = new DesktopView(handle);
        var surface = new Surface(window, view, display);
        try
        {
            view.Session = session;
            view.Scaling = scaling;
            view.Canvas = canvas;
            view.ShortcutModifiers = owner.Controller.Input.Value.ShortcutModifiers;
            view.Capture.SetFullscreenSystemKeys(owner.Controller.Input.Value.FullscreenSystemKeys);
            view.Capture.SetFullscreen(true);
            view.Command += owner.DesktopCommand;
            owner.HookView(view);
            view.SurfaceEntered += SurfaceEntered;
            view.RenderFailed += _ => owner.DispatcherQueue.TryEnqueue(() => Exit());
            if (window.Content is null) window.Content = view;
            window.AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "tidyvnc.ico"));
            if (surfaces.Count == 0)
            {
                // The first surface is the primary one: it carries the connection bar.
                var layer = new Grid();
                window.Content = null;
                layer.Children.Add(view);
                window.Content = layer;
                AddBar(layer);
            }
            var bounds = display.Bounds;
            window.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32((int)bounds.X, (int)bounds.Y, (int)bounds.Width, (int)bounds.Height));
            window.AppWindow.SetPresenter(AppWindowPresenterKind.FullScreen);
            window.AppWindow.Closing += (_, args) =>
            {
                if (closing) return;
                args.Cancel = true; // Closing one surface leaves full screen, not the connection.
                Exit();
            };
            window.Activated += (_, e) => { if (e.WindowActivationState == WindowActivationState.Deactivated) view.ReleaseKeys(); };
            return surface;
        }
        catch
        {
            Dispose(surface);
            throw;
        }
    }

    /// <summary>The pointer moving onto another display's surface makes it the keyboard target.</summary>
    private void SurfaceEntered(DesktopView view)
    {
        if (state.Phase != NativeFullscreenPhase.Active || surfaces.FirstOrDefault(s => s.View == view) is not { } surface) return;
        if (view.FocusState != FocusState.Unfocused) return;
        surface.Window.Activate();
        view.Focus(FocusState.Pointer);
    }

    /// <summary>
    /// Scaling reaches every view; a change of units rebuilds the surfaces'
    /// canvas regions, since device units change the shared canvas.
    /// </summary>
    public void ScalingChanged(NativeScaling scaling)
    {
        if (surfaces.Count == 0) { owner.Desktop.Scaling = scaling; return; }
        try
        {
            var layout = new NativeDisplayLayout([.. surfaces.Select(s => s.Display)], !scaling.Mode.Fits() && scaling.DevicePixels);
            foreach (var surface in surfaces)
            {
                surface.View.Canvas = layout.Viewport(surface.Display.Id);
                surface.View.Scaling = scaling;
            }
            Resize.UpdateCanvas(canvasSource, layout, scaling.Mode == NativeScalingMode.Unscaled, available: true);
            owner.Desktop.Scaling = scaling;
        }
        catch (NativeError)
        {
            owner.Desktop.Scaling = scaling;
            Finish(restore: true, disconnected: false, message: new NativeText("desktop.fullscreen.full.screen.could.not.be.opened.try.again"));
        }
    }

    private void AddBar(Grid layer)
    {
        bar = new FullscreenConnectionBar(owner);
        barLayer = layer;
        layer.Children.Add(bar);
        layer.AddHandler(UIElement.PointerMovedEvent, barPointer, handledEventsToo: true);
    }

    private void RemoveBar()
    {
        if (bar is null || barLayer is null) return;
        bar.Stop();
        barLayer.RemoveHandler(UIElement.PointerMovedEvent, barPointer);
        barLayer.Children.Remove(bar);
        bar = null; barLayer = null;
    }

    /// <summary>The bar's title and statistics follow the window.</summary>
    public void Refresh() => bar?.Refresh();

    /// <summary>Minimizes every surface of the connection; restoring shows them in full screen again.</summary>
    public void Minimize()
    {
        if (surfaces.Count == 0) NativeWindows.Minimize(owner.Handle);
        else foreach (var surface in surfaces) NativeWindows.Minimize(WinRT.Interop.WindowNative.GetWindowHandle(surface.Window));
    }

    public void Exit()
    {
        if (!IsFullscreen) return;
        state.SetPhase(NativeFullscreenPhase.Exiting);
        Finish(restore: true, disconnected: false, message: null);
    }

    /// <summary>The connection ended or changed: full screen closes and keeps its intent for a reconnect.</summary>
    public void ConnectionEnded()
    {
        if (IsFullscreen) Finish(restore: true, disconnected: true, message: null);
    }

    private void DisplaysChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (!IsFullscreen || e.PropertyName != nameof(NativeDisplayService.Snapshot)) return;
        var snapshot = displays.Snapshot;
        // Arrangement, scale or membership changes close full screen; a work-area change alone does not.
        var same = snapshot.Error is null && snapshot.Displays.Length == topology.Length &&
                   snapshot.Displays.Zip(topology).All(p => p.First.Id == p.Second.Id && p.First.Bounds == p.Second.Bounds &&
                                                            p.First.Scale == p.Second.Scale && p.First.IsPrimary == p.Second.IsPrimary);
        if (!same) Finish(restore: true, disconnected: false, message: new NativeText("desktop.fullscreen.displays.changed.full.screen.was.closed.choose.displays.again"));
    }

    private void Finish(bool restore, bool disconnected, NativeText? message)
    {
        closing = true;
        try
        {
            RemoveBar();
            var owned = surfaces.ToList();
            surfaces.Clear();
            foreach (var surface in owned) Dispose(surface);
            Resize.EndCanvas(canvasSource);
            if (presenter)
            {
                presenter = false;
                if (restore)
                {
                    owner.AppWindow.SetPresenter(AppWindowPresenterKind.Overlapped);
                    owner.SetFullscreenChrome(false);
                }
            }
            else if (restore && owned.Count > 0)
            {
                owner.AppWindow.Show();
                owner.Activate();
            }
            owner.Desktop.Capture.SetFullscreen(false);
            if (restore && !disconnected) owner.Desktop.Focus(FocusState.Programmatic);
        }
        finally
        {
            closing = false;
        }
        state.Ended(disconnected);
        if (message is not null) state.Message = message;
    }

    private void Dispose(Surface surface)
    {
        closing = true;
        surface.View.Command -= owner.DesktopCommand;
        surface.View.SurfaceEntered -= SurfaceEntered;
        surface.View.Dispose();
        surface.Window.Content = null;
        surface.Window.Close();
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        displays.PropertyChanged -= DisplaysChanged;
        if (IsFullscreen || surfaces.Count > 0) Finish(restore: false, disconnected: false, message: null);
        state.Stop();
    }
}
