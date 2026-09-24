// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Immutable;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using CommunityToolkit.Mvvm.ComponentModel;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Power;
using Windows.Win32.UI.HiDpi;
using Windows.Win32.UI.WindowsAndMessaging;

namespace TidyVNC.Native.Platform;

public enum NativeDisplayError { Unavailable, InvalidSnapshot, TooManyDisplays }

/// <summary>A pixel rectangle in virtual-screen coordinates.</summary>
public readonly record struct NativeDisplayRectangle(double X, double Y, double Width, double Height)
{
    public bool Contains(NativeDisplayRectangle other)
        => other.X >= X && other.Y >= Y && other.X + other.Width <= X + Width && other.Y + other.Height <= Y + Height;
}

/// <summary>
/// One display (SERVICES.md section 7). Id is the stable identity (16
/// lowercase hex digits of the SHA-256 of the monitor device path), never an
/// HMONITOR or enumeration index; mirrored outputs are one display.
/// Physical rectangles are device pixels; logical ones are effective pixels
/// (physical divided by Scale).
/// </summary>
public sealed record NativeDisplayInfo(string Id, string Name, NativeDisplayRectangle Bounds, NativeDisplayRectangle WorkArea, double Scale,
                                       bool IsPrimary, bool IsMirrored, nint Monitor)
{
    public NativeDisplayRectangle LogicalBounds => new(Bounds.X / Scale, Bounds.Y / Scale, Bounds.Width / Scale, Bounds.Height / Scale);
    public NativeDisplayRectangle LogicalWorkArea => new(WorkArea.X / Scale, WorkArea.Y / Scale, WorkArea.Width / Scale, WorkArea.Height / Scale);
    /// <summary>The same display as far as saved choices are concerned (the monitor handle may change).</summary>
    public bool SameGeometry(NativeDisplayInfo other)
        => Id == other.Id && Name == other.Name && Bounds == other.Bounds && WorkArea == other.WorkArea && Scale == other.Scale &&
           IsPrimary == other.IsPrimary && IsMirrored == other.IsMirrored;
}

public sealed record NativeDisplaySelection(ImmutableArray<NativeDisplayInfo> Displays, ImmutableArray<string> Missing, bool UsedFallback);

public sealed record NativeDisplaySnapshot(ulong Generation, ImmutableArray<NativeDisplayInfo> Displays, NativeDisplayError? Error)
{
    public static NativeDisplaySnapshot Initial { get; } = new(0, [], null);

    public NativeDisplayInfo? Primary => Displays.FirstOrDefault(d => d.IsPrimary);
    public NativeDisplayInfo? Find(string id) => Displays.FirstOrDefault(d => d.Id == id);

    /// <summary>
    /// Saved choices resolve as on macOS: surviving displays in the requested
    /// order, missing ones reported (the stored preference is not rewritten),
    /// and only when none survive a fallback to the current, then the primary
    /// display.
    /// </summary>
    public NativeDisplaySelection Resolve(IEnumerable<string> requested, string? current = null)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var available = ImmutableArray.CreateBuilder<NativeDisplayInfo>();
        var missing = ImmutableArray.CreateBuilder<string>();
        foreach (var id in requested)
        {
            if (!seen.Add(id)) continue;
            if (Find(id) is { } display) available.Add(display);
            else missing.Add(id);
        }
        if (available.Count > 0) return new(available.ToImmutable(), missing.ToImmutable(), false);
        var fallback = (current is not null ? Find(current) : null) ?? Primary;
        return new(fallback is null ? [] : [fallback], missing.ToImmutable(), fallback is not null);
    }
}

/// <summary>Reads the current topology (tests substitute scripted sources).</summary>
public interface INativeDisplaySource
{
    IReadOnlyList<NativeDisplayInfo> Read();
}

/// <summary>The helper DLL's QueryDisplayConfig topology (tvw_displays).</summary>
public sealed class NativeWindowsDisplaySource : INativeDisplaySource
{
    public static string FormatId(ulong id) => id.ToString("x16", CultureInfo.InvariantCulture);

    public IReadOnlyList<NativeDisplayInfo> Read()
    {
        IReadOnlyList<NativeDisplay> displays;
        // QueryDisplayConfig fails (E_INVALIDARG) while every display is powered off.
        try { displays = NativeDisplays.Query(); }
        catch (WindowsHelperException) { throw new NativeDisplayException(NativeDisplayError.Unavailable); }
        return displays.Select((d, index) => new NativeDisplayInfo(FormatId(d.Id),
            string.IsNullOrWhiteSpace(d.Name) ? string.Create(CultureInfo.InvariantCulture, $"Display {index + 1}") : d.Name,
            new(d.Bounds.X, d.Bounds.Y, d.Bounds.Width, d.Bounds.Height),
            new(d.WorkArea.X, d.WorkArea.Y, d.WorkArea.Width, d.WorkArea.Height),
            d.DpiX == 0 ? 1.0 : d.DpiX / 96.0, d.Primary, d.Mirrored, d.Monitor)).ToList();
    }
}

public sealed class NativeDisplayException(NativeDisplayError error) : Exception($"Displays {error}")
{
    public NativeDisplayError Error { get; } = error;
}

/// <summary>
/// Topology change notifications: WM_DISPLAYCHANGE, WM_SETTINGCHANGE (work
/// area), WM_DPICHANGED and console display on/off, received by a hidden
/// top-level window on its own thread (message-only windows get no
/// broadcasts). Changed is raised on that thread.
/// </summary>
public sealed unsafe class NativeDisplayChangeListener : IDisposable
{
    private const uint DisplayChange = 0x007E, SettingChange = 0x001A, DpiChanged = 0x02E0, PowerBroadcast = 0x0218, Quit = 0x8001;
    private const uint PowerSettingChange = 0x8013; // PBT_POWERSETTINGCHANGE
    private static readonly Guid ConsoleDisplayState = new("6FE69556-704A-47A0-8F24-C28D936FDA47");
    private static readonly Dictionary<nint, NativeDisplayChangeListener> Listeners = [];

    private readonly Thread thread;
    private readonly TaskCompletionSource<nint> ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private HWND window;
    private bool disposed;

    public event Action? Changed;

    public NativeDisplayChangeListener()
    {
        thread = new Thread(Run) { IsBackground = true, Name = "TidyVNC display changes" };
        thread.Start();
        window = new HWND(ready.Task.GetAwaiter().GetResult());
    }

    /// <summary>Tests deliver a message as Windows would.</summary>
    internal void Deliver(uint message, nuint wParam = 0)
    {
        // WM_DPICHANGED carries the suggested window rectangle, which the system marshals.
        var suggested = new RECT { right = 1, bottom = 1 };
        PInvoke.SendMessage(window, message, new WPARAM(wParam), message == DpiChanged ? new LPARAM((nint)(&suggested)) : default);
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static LRESULT WindowProcedure(HWND hwnd, uint message, WPARAM wParam, LPARAM lParam)
    {
        NativeDisplayChangeListener? owner;
        lock (Listeners) Listeners.TryGetValue((nint)hwnd.Value, out owner);
        if (owner is not null)
        {
            if (message == Quit)
            {
                PInvoke.DestroyWindow(hwnd);
                PInvoke.PostQuitMessage(0);
                return new LRESULT(0);
            }
            if (message is DisplayChange or SettingChange or DpiChanged ||
                (message == PowerBroadcast && wParam.Value == PowerSettingChange))
            {
                try { owner.Changed?.Invoke(); }
                catch (Exception error) { System.Diagnostics.Trace.TraceError($"Display listener failed: {error.GetType().Name}"); }
            }
        }
        return PInvoke.DefWindowProc(hwnd, message, wParam, lParam);
    }

    private void Run()
    {
        HWND created;
        HPOWERNOTIFY notification = default;
        try
        {
            // WM_DPICHANGED reaches only per-monitor-aware windows.
            PInvoke.SetThreadDpiAwarenessContext(new DPI_AWARENESS_CONTEXT(-4)); // PER_MONITOR_AWARE_V2
            var name = "TidyVNC.Displays." + Environment.ProcessId + "." + Environment.CurrentManagedThreadId;
            fixed (char* className = name)
            {
                var windowClass = new WNDCLASSEXW { cbSize = (uint)sizeof(WNDCLASSEXW), lpfnWndProc = &WindowProcedure, lpszClassName = className };
                if (PInvoke.RegisterClassEx(&windowClass) == 0) throw new InvalidOperationException("Display window class");
            }
            // A hidden top-level window: broadcasts do not reach message-only windows.
            created = PInvoke.CreateWindowEx(WINDOW_EX_STYLE.WS_EX_TOOLWINDOW, name, null, WINDOW_STYLE.WS_POPUP, 0, 0, 0, 0, HWND.Null, null, null, null);
            if (created.IsNull) throw new InvalidOperationException("Display window");
            lock (Listeners) Listeners[(nint)created.Value] = this;
            var guid = ConsoleDisplayState;
            notification = PInvoke.RegisterPowerSettingNotification(new HANDLE(created.Value), &guid, 0); // DEVICE_NOTIFY_WINDOW_HANDLE
            ready.SetResult((nint)created.Value);
        }
        catch (Exception error)
        {
            ready.SetException(error);
            return;
        }
        MSG message;
        while (PInvoke.GetMessage(&message, HWND.Null, 0, 0) > 0)
        {
            PInvoke.TranslateMessage(&message);
            PInvoke.DispatchMessage(&message);
        }
        if (!notification.IsNull) PInvoke.UnregisterPowerSettingNotification(notification);
        lock (Listeners) Listeners.Remove((nint)created.Value);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        PInvoke.PostMessage(window, Quit, default, default);
        thread.Join(TimeSpan.FromSeconds(5));
    }
}

/// <summary>
/// The display service (SERVICES.md section 7; NativeDisplayService on
/// macOS): immutable snapshots with a generation that advances only when
/// the topology really changes (order and monitor handles alone do not). A
/// failed read publishes an empty snapshot with its error rather than stale
/// geometry. UI thread only; change notifications are marshalled to it.
/// </summary>
public sealed partial class NativeDisplayService : ObservableObject, IDisposable
{
    public const int MaximumDisplays = 64;

    private readonly IUiDispatcher dispatcher;
    private readonly INativeDisplaySource source;
    private readonly NativeDisplayChangeListener? listener;
    private readonly Lock queueGate = new();
    private bool stopped, refreshQueued;

    [ObservableProperty] public partial NativeDisplaySnapshot Snapshot { get; private set; } = NativeDisplaySnapshot.Initial;

    /// <summary>With a listener, topology changes refresh automatically.</summary>
    public NativeDisplayService(IUiDispatcher dispatcher, INativeDisplaySource? source = null, NativeDisplayChangeListener? listener = null)
    {
        this.dispatcher = dispatcher;
        this.source = source ?? new NativeWindowsDisplaySource();
        this.listener = listener;
        if (listener is not null) listener.Changed += QueueRefresh;
        Refresh();
    }

    private void QueueRefresh()
    {
        lock (queueGate)
        {
            if (refreshQueued) return;
            refreshQueued = true;
        }
        dispatcher.TryEnqueue(() =>
        {
            lock (queueGate) refreshQueued = false;
            Refresh();
        });
    }

    public void Refresh()
    {
        UiThread.Require(dispatcher);
        if (stopped) return;
        ImmutableArray<NativeDisplayInfo> displays;
        NativeDisplayError? problem;
        try
        {
            displays = Validate(source.Read());
            problem = null;
        }
        catch (NativeDisplayException error) { displays = []; problem = error.Error; }
        catch (Exception error) when (error is WindowsHelperException or InvalidOperationException) { displays = []; problem = NativeDisplayError.Unavailable; }
        var current = Snapshot;
        if (current.Generation != 0 && current.Error == problem && current.Displays.Length == displays.Length &&
            current.Displays.Zip(displays).All(pair => pair.First.SameGeometry(pair.Second)))
        {
            // Same topology: keep the generation; monitor handles may still be refreshed.
            if (!current.Displays.SequenceEqual(displays)) Snapshot = current with { Displays = displays };
            return;
        }
        Snapshot = new NativeDisplaySnapshot(current.Generation + 1, displays, problem);
    }

    private static ImmutableArray<NativeDisplayInfo> Validate(IReadOnlyList<NativeDisplayInfo> displays)
    {
        if (displays.Count > MaximumDisplays) throw new NativeDisplayException(NativeDisplayError.TooManyDisplays);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var d in displays)
        {
            if (d.Id.Length is 0 or > 256 || !ids.Add(d.Id) || d.Bounds.Width <= 0 || d.Bounds.Height <= 0 ||
                !double.IsFinite(d.Scale) || d.Scale <= 0 || !d.Bounds.Contains(d.WorkArea) || d.Name.Length == 0)
                throw new NativeDisplayException(NativeDisplayError.InvalidSnapshot);
        }
        if (displays.Count > 0 && displays.Count(d => d.IsPrimary) != 1) throw new NativeDisplayException(NativeDisplayError.InvalidSnapshot);
        // Order changes alone never create a new topology generation.
        return [.. displays.OrderBy(d => d.Id, StringComparer.Ordinal)];
    }

    public void Dispose()
    {
        stopped = true;
        if (listener is not null) listener.Changed -= QueueRefresh;
    }
}
