// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Immutable;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native.Platform;

/// <summary>A window frame in physical virtual-screen pixels.</summary>
public readonly record struct NativeWindowFrame(int X, int Y, int Width, int Height)
{
    public int Right => X + Width;
    public int Bottom => Y + Height;

    public long Overlap(NativeDisplayRectangle other)
    {
        var width = Math.Min(Right, other.X + other.Width) - Math.Max(X, other.X);
        var height = Math.Min(Bottom, other.Y + other.Height) - Math.Max(Y, other.Y);
        return width <= 0 || height <= 0 ? 0 : (long)width * (long)height;
    }
}

/// <summary>A window frame's borders around its client area, in physical pixels.</summary>
public readonly record struct NativeInsets(int Left, int Top, int Right, int Bottom);

/// <summary>
/// Window placement arithmetic (DESKTOP.md section 8; macOS
/// NativeWindowStartupState.contentRect). Frames are physical pixels. A
/// -geometry size is the client area in effective pixels on the target
/// display; its position is the client's top-left in effective pixels of the
/// primary display, whose top-left is the desktop origin. Saved placements
/// return only onto displays that still exist.
/// </summary>
public static class NativeWindowPlacements
{
    /// <summary>Where a -geometry position lands in physical desktop pixels, if it has one.</summary>
    public static (int X, int Y)? Position(NativeWindowGeometry? geometry, NativeDisplaySnapshot displays)
    {
        if (geometry?.X is not int x || geometry.Y is not int y) return null;
        var scale = displays.Primary?.Scale ?? 1;
        return ((int)Math.Round(x * scale), (int)Math.Round(y * scale));
    }

    /// <summary>
    /// The display a startup placement uses: the one holding the position (a
    /// point on a boundary belongs to the display below or right), else the
    /// window's current display, else the primary.
    /// </summary>
    public static NativeDisplayInfo? Target(NativeDisplaySnapshot displays, (int X, int Y)? position, string? current)
    {
        if (position is { } point &&
            displays.Displays.FirstOrDefault(d => Contains(d.Bounds, point.X + 0.5, point.Y + 0.5)) is { } holding) return holding;
        return (current is null ? null : displays.Find(current)) ?? displays.Primary ?? displays.Displays.FirstOrDefault();
    }

    private static bool Contains(NativeDisplayRectangle r, double x, double y) => x >= r.X && x < r.X + r.Width && y >= r.Y && y < r.Y + r.Height;

    /// <summary>
    /// The frame for a startup policy. Maximize is not a size here: the caller
    /// maximizes the presenter after moving the window onto the target display,
    /// so the restored size stays the requested one.
    /// </summary>
    public static NativeWindowFrame Startup(NativeWindowStartupPolicy policy, NativeWindowFrame frame, NativeInsets borders, NativeDisplayInfo target,
                                          (int Width, int Height) minimumClient, (int X, int Y)? position)
    {
        var work = target.WorkArea;
        var availableWidth = Math.Max(1, (int)work.Width - borders.Left - borders.Right);
        var availableHeight = Math.Max(1, (int)work.Height - borders.Top - borders.Bottom);
        var width = frame.Width - borders.Left - borders.Right;
        var height = frame.Height - borders.Top - borders.Bottom;
        if (policy.Geometry is { Width: int w, Height: int h })
        {
            width = (int)Math.Round(w * target.Scale);
            height = (int)Math.Round(h * target.Scale);
        }
        width = Math.Clamp(width, minimumClient.Width, Math.Max(availableWidth, minimumClient.Width));
        height = Math.Clamp(height, minimumClient.Height, Math.Max(availableHeight, minimumClient.Height));
        var (left, top) = position ?? (frame.X + borders.Left, frame.Y + borders.Top);
        return new NativeWindowFrame(left - borders.Left, top - borders.Top, width + borders.Left + borders.Right, height + borders.Top + borders.Bottom);
    }

    /// <summary>A saved frame moved and shrunk into its display's work area, or null when that display is gone.</summary>
    public static NativeWindowFrame? Restore(NativeWindowPlacement saved, NativeDisplaySnapshot displays, (int Width, int Height) minimum)
    {
        if (saved.Display is not { } id || displays.Error is not null || displays.Find(id) is not { } display) return null;
        var work = display.WorkArea;
        int left = (int)work.X, top = (int)work.Y, right = (int)(work.X + work.Width), bottom = (int)(work.Y + work.Height);
        var width = Math.Clamp(saved.Width, Math.Min(minimum.Width, right - left), Math.Max(1, right - left));
        var height = Math.Clamp(saved.Height, Math.Min(minimum.Height, bottom - top), Math.Max(1, bottom - top));
        return new NativeWindowFrame(Math.Clamp(saved.X, left, right - width), Math.Clamp(saved.Y, top, bottom - height), width, height);
    }

    /// <summary>A placement to save: the restored frame and the display holding most of it.</summary>
    public static NativeWindowPlacement Capture(NativeWindowFrame frame, bool maximized, NativeDisplaySnapshot displays)
    {
        var display = displays.Displays.Select(d => (d.Id, Area: frame.Overlap(d.Bounds))).Where(d => d.Area > 0)
            .OrderByDescending(d => d.Area).Select(d => d.Id).FirstOrDefault();
        return new NativeWindowPlacement(frame.X, frame.Y, Math.Clamp(frame.Width, 1, 65535), Math.Clamp(frame.Height, 1, 65535), maximized, display);
    }
}

/// <summary>
/// Remembered window state (window-state.json): placements and whether the
/// connection windows show their status bar. Read once at startup; saves are
/// serialized and merge with other processes' changes. A record that cannot
/// be read (corrupt or a newer schema) is left alone and nothing is saved over
/// it. UI thread only.
/// </summary>
public sealed class NativeWindowPlacementMemory
{
    private readonly NativeWindowStateStore store;
    private NativeWindowState state;
    private readonly bool writable;
    private Task saving = Task.CompletedTask;

    private NativeWindowPlacementMemory(NativeWindowStateStore store, NativeWindowState state, bool writable)
    {
        this.store = store; this.state = state; this.writable = writable;
    }

    public static async Task<NativeWindowPlacementMemory> LoadAsync(NativeWindowStateStore store)
    {
        try { return new(store, (await store.ReadAsync().ConfigureAwait(false)).Value, true); }
        catch (NativeStorageException) { return new(store, NativeWindowState.Empty, false); }
    }

    public NativeWindowPlacement? Get(string key) => state.Windows.GetValueOrDefault(key);

    public void Remember(string key, NativeWindowPlacement placement)
    {
        if (state.Windows.GetValueOrDefault(key) == placement) return;
        Change(value => value with { Windows = value.Windows.SetItem(key, placement) });
    }

    /// <summary>Whether connection windows show their status bar (View &gt; Status bar).</summary>
    public bool StatusBarVisible
    {
        get => !state.StatusBarHidden;
        set
        {
            if (value == StatusBarVisible) return;
            Change(current => current with { StatusBarHidden = !value });
        }
    }

    /// <summary>Applies the change here, then to the stored record as it is now (another process may have changed it).</summary>
    private void Change(Func<NativeWindowState, NativeWindowState> change)
    {
        state = change(state);
        if (!writable) return;
        var previous = saving;
        saving = Save(previous, change);
    }

    private async Task Save(Task previous, Func<NativeWindowState, NativeWindowState> change)
    {
        await previous.ConfigureAwait(false);
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                var current = await store.ReadAsync().ConfigureAwait(false);
                await store.CommitAsync(change(current.Value), current.Revision).ConfigureAwait(false);
                return;
            }
            catch (NativeStorageException error) when (error.Error == NativeStorageError.Conflict) { }
            catch (NativeStorageException error)
            {
                System.Diagnostics.Trace.TraceWarning($"Window state not saved: {error.Error}");
                return;
            }
        }
    }

    /// <summary>Waits for pending saves (exit ordering).</summary>
    public Task FlushAsync() => saving;
}
