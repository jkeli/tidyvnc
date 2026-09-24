// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native.Interop;
using TidyVNC.Native.Platform;

namespace TidyVNC.Native.Desktop;

/// <summary>A desktop view's presentation surface: physical size, logical size and scaling.</summary>
public sealed record DesktopViewport(
    uint PixelWidth, uint PixelHeight, double LogicalWidth, double LogicalHeight, double Scale,
    string Scaling = "FixedRatio", NativeScalingFilter Filter = NativeScalingFilter.Bilinear, bool DevicePixels = false,
    NativeCanvasViewport? Canvas = null, double PanX = 0, double PanY = 0)
{
    public bool IsEmpty => PixelWidth == 0 || PixelHeight == 0 || LogicalWidth <= 0 || LogicalHeight <= 0 || Scale <= 0;
}

public readonly record struct DesktopRenderStatistics(
    long Frames, long TilesRendered, long TilesCached, long FullRedraws, TimeSpan LastFrame, TimeSpan WorstFrame, int DeviceResets);

/// <summary>
/// Renders a session's frames into a <see cref="NativePresenter"/> on a
/// dedicated thread (DESKTOP.md section 1): the core renders 256x256 BGRA tiles
/// of the scaled desktop, only tiles meeting the frame's damage are rendered
/// and uploaded, and the letterbox is cleared on layout changes. The newest
/// frame wins; skipped frames' damage is merged so the core's tile cache stays
/// valid. After device loss a new presenter is created and handed to
/// <c>attach</c> on the UI thread.
/// </summary>
public sealed unsafe class DesktopRenderer : IDisposable
{
    private const int TileSize = 256;

    private sealed class Pending
    {
        public required NativeImage Image;
        public ulong PreviousSequence;
        public NativePixelRect Damage;
    }

    private readonly IUiDispatcher ui;
    private readonly Action<NativePresenter> attach;
    private readonly Thread thread;
    private readonly AutoResetEvent wake = new(false);
    private readonly Lock gate = new();
    private readonly byte[] tile = new byte[TileSize * TileSize * 4];
    private readonly NativeHandle renderer;

    // Guarded by gate.
    private Pending? pendingFrame;
    private bool frameChanged;
    private DesktopViewport? pendingViewport;
    private bool stopping;

    // Render thread only.
    private NativePresenter presenter;
    private DesktopViewport? viewport;
    private NativeImage? shown;
    private (uint Width, uint Height, int X, int Y)? layout;
    private long frames, tilesRendered, tilesCached, fullRedraws;
    private TimeSpan lastFrame, worstFrame;
    private int deviceResets;

    public DesktopRenderer(IUiDispatcher ui, Action<NativePresenter> attach, ulong cacheBytes = 8 * 1024 * 1024)
    {
        this.ui = ui;
        this.attach = attach;
        ulong value = 0;
        var error = Abi.Init<tidyvnc_error>();
        Abi.Check(NativeMethods.tidyvnc_renderer_create(cacheBytes, &value, &error), &error);
        renderer = NativeHandle.Adopt(value);
        presenter = new NativePresenter();
        thread = new Thread(Run) { IsBackground = true, Name = "TidyVNC desktop renderer" };
        thread.Start();
    }

    /// <summary>The presenter to attach to the view's SwapChainPanel now.</summary>
    public NativePresenter Presenter => presenter;

    /// <summary>Called on the UI thread after a render failure other than device loss.</summary>
    public event Action<Exception>? Failed;

    /// <summary>Called on the UI thread after each present (diagnostics and tests).</summary>
    public event Action<DesktopRenderStatistics>? Presented;

    public DesktopRenderStatistics Statistics
    {
        get { lock (gate) return new(frames, tilesRendered, tilesCached, fullRedraws, lastFrame, worstFrame, deviceResets); }
    }

    /// <summary>Queues a frame; the renderer takes its own lease (the caller keeps theirs).</summary>
    public void Submit(NativeImage? frame)
    {
        var lease = frame?.Clone();
        lock (gate)
        {
            if (stopping) { lease?.Dispose(); return; }
            if (lease is not null && pendingFrame is { } older && older.Image.StreamId == lease.StreamId &&
                older.Image.Generation == lease.Generation && older.Image.SizeGeneration == lease.SizeGeneration &&
                lease.PreviousSequence == older.Image.Sequence)
            {
                // Merge a skipped frame: keep its predecessor and the union of damage.
                older.Image.Dispose();
                older.Image = lease;
                older.Damage = Union(older.Damage, lease.Damage);
            }
            else
            {
                pendingFrame?.Image.Dispose();
                pendingFrame = lease is null ? null : new Pending { Image = lease, PreviousSequence = lease.PreviousSequence, Damage = lease.Damage };
            }
            frameChanged = true;
        }
        wake.Set();
    }

    public void Resize(DesktopViewport value)
    {
        lock (gate)
        {
            if (stopping) return;
            pendingViewport = value;
        }
        wake.Set();
    }

    private static NativePixelRect Union(NativePixelRect a, NativePixelRect b)
    {
        if (a.Width == 0 || a.Height == 0) return b;
        if (b.Width == 0 || b.Height == 0) return a;
        uint left = Math.Min(a.X, b.X), top = Math.Min(a.Y, b.Y);
        uint right = Math.Max(a.X + a.Width, b.X + b.Width), bottom = Math.Max(a.Y + a.Height, b.Y + b.Height);
        return new NativePixelRect(left, top, right - left, bottom - top);
    }

    private void Run()
    {
        while (true)
        {
            wake.WaitOne();
            Pending? frame = null;
            bool haveFrame;
            DesktopViewport? resize;
            lock (gate)
            {
                if (stopping) break;
                haveFrame = frameChanged;
                frame = pendingFrame; pendingFrame = null; frameChanged = false;
                resize = pendingViewport; pendingViewport = null;
            }
            try
            {
                Render(haveFrame, frame, resize);
            }
            catch (WindowsHelperException error) when (error.IsDeviceLost)
            {
                RecoverDevice(haveFrame ? frame : null);
                frame = null;
            }
            catch (Exception error)
            {
                // The render thread never dies; the view reports and may recreate the renderer.
                ui.TryEnqueue(() => Failed?.Invoke(error));
            }
            finally
            {
                // A frame that was not adopted by Render is released here.
                if (frame is not null && !ReferenceEquals(frame.Image, shown)) frame.Image.Dispose();
            }
        }
        shown?.Dispose();
        shown = null;
    }

    private void RecoverDevice(Pending? unrendered)
    {
        presenter.Dispose();
        lock (gate) deviceResets++;
        try
        {
            presenter = new NativePresenter();
        }
        catch (WindowsHelperException error)
        {
            unrendered?.Image.Dispose();
            ui.TryEnqueue(() => Failed?.Invoke(error));
            return;
        }
        var replacement = presenter;
        var current = viewport;
        viewport = null; layout = null;
        ui.TryEnqueue(() => attach(replacement));
        // Redraw in full on the new device: the frame that failed, else the one shown.
        var redraw = unrendered ?? (shown is null ? null : new Pending { Image = shown.Clone() });
        if (redraw is not null) redraw.PreviousSequence = 0;
        lock (gate)
        {
            if (current is not null) pendingViewport ??= current;
            if (!frameChanged && redraw is not null) { pendingFrame = redraw; frameChanged = true; redraw = null; }
        }
        redraw?.Image.Dispose();
        wake.Set();
    }

    private void Render(bool haveFrame, Pending? frame, DesktopViewport? resize)
    {
        var started = Stopwatch.GetTimestamp();
        var full = false;
        if (resize is not null && resize != viewport)
        {
            if (!resize.IsEmpty)
            {
                if (viewport is null || viewport.PixelWidth != resize.PixelWidth || viewport.PixelHeight != resize.PixelHeight ||
                    viewport.Scale != resize.Scale)
                    presenter.Resize(resize.PixelWidth, resize.PixelHeight, (float)resize.Scale, (float)resize.Scale);
                full = true;
            }
            viewport = resize;
        }
        if (viewport is null || viewport.IsEmpty) { Adopt(haveFrame, frame); return; }

        var image = haveFrame ? frame?.Image : shown;
        if (image is null)
        {
            Adopt(haveFrame, frame);
            layout = null;
            presenter.Clear(new TvwRect(0, 0, (int)viewport.PixelWidth, (int)viewport.PixelHeight));
            presenter.Present([]);
            Count(started, full: true, rendered: 0, cached: 0);
            return;
        }

        var geometry = new NativeGeometry(image.Width, image.Height, viewport.LogicalWidth, viewport.LogicalHeight, viewport.Scale, viewport.Scaling,
                                          viewport.DevicePixels, viewport.PanX, viewport.PanY, viewport.Canvas);
        var offsetX = (int)Math.Round(geometry.X * viewport.Scale);
        var offsetY = (int)Math.Round(geometry.Y * viewport.Scale);
        var placement = (geometry.BackingWidth, geometry.BackingHeight, offsetX, offsetY);
        var previous = shown;
        full |= layout != placement || previous is null || previous.StreamId != image.StreamId ||
                previous.Generation != image.Generation || previous.SizeGeneration != image.SizeGeneration;

        ulong previousSequence = 0;
        var damage = new NativePixelRect(0, 0, image.Width, image.Height);
        if (!full && haveFrame && frame is not null)
        {
            if (frame.Image.Sequence == previous!.Sequence) { Adopt(haveFrame, frame); return; }
            if (frame.PreviousSequence == previous.Sequence) { previousSequence = frame.PreviousSequence; damage = frame.Damage; }
            else full = true;
        }
        else if (!full && !haveFrame)
        {
            return; // Only an unchanged viewport; nothing to redraw.
        }

        // Tiles of the scaled desktop that are visible in the surface.
        var surface = new TvwRect(0, 0, (int)viewport.PixelWidth, (int)viewport.PixelHeight);
        var desktop = new TvwRect(offsetX, offsetY, (int)geometry.BackingWidth, (int)geometry.BackingHeight);
        var visible = desktop.Intersect(surface);
        TvwRect dirtyBacking;
        if (full)
        {
            ClearLetterbox(surface, visible);
            dirtyBacking = new TvwRect(0, 0, desktop.Width, desktop.Height);
        }
        else
        {
            var mapped = new NativeGeometry(image.Width, image.Height, geometry.BackingWidth, geometry.BackingHeight, 1,
                $"{geometry.BackingWidth}x{geometry.BackingHeight}", devicePixels: true).Damage(damage, viewport.Filter);
            var left = (int)Math.Floor(mapped.X);
            var top = (int)Math.Floor(mapped.Y);
            dirtyBacking = new TvwRect(left, top, (int)Math.Ceiling(mapped.X + mapped.Width) - left,
                (int)Math.Ceiling(mapped.Y + mapped.Height) - top);
        }

        var options = Abi.Init<tidyvnc_tile_options>();
        options.width = geometry.BackingWidth; options.height = geometry.BackingHeight; options.quality = (uint)viewport.Filter;
        options.previous_sequence = previousSequence;
        options.damage_x = damage.X; options.damage_y = damage.Y; options.damage_width = damage.Width; options.damage_height = damage.Height;

        var dirty = new List<TvwRect>();
        int rendered = 0, cached = 0;
        if (!visible.IsEmpty)
        {
            var region = new TvwRect(visible.X - offsetX, visible.Y - offsetY, visible.Width, visible.Height);
            var firstX = region.X / TileSize * TileSize;
            var firstY = region.Y / TileSize * TileSize;
            for (var y = firstY; y < region.Bottom; y += TileSize)
            {
                for (var x = firstX; x < region.Right; x += TileSize)
                {
                    var rect = new TvwRect(x, y, Math.Min(TileSize, desktop.Width - x), Math.Min(TileSize, desktop.Height - y));
                    if (rect.Intersect(dirtyBacking).IsEmpty) continue;
                    options.x = (uint)x; options.y = (uint)y;
                    options.tile_width = (uint)rect.Width; options.tile_height = (uint)rect.Height;
                    var result = Abi.Init<tidyvnc_tile_result>();
                    var error = Abi.Init<tidyvnc_error>();
                    fixed (byte* output = tile)
                    {
                        var span = new tidyvnc_mutable_bytes { data = output, length = (ulong)tile.Length };
                        Abi.Check(NativeMethods.tidyvnc_renderer_render(renderer.Raw, image.Handle.Raw, &options, span, &result, &error), &error);
                    }
                    if (result.cache_hit != 0) cached++; else rendered++;
                    var target = new TvwRect(rect.X + offsetX, rect.Y + offsetY, rect.Width, rect.Height);
                    presenter.Upload(tile, (uint)rect.Width * 4, target);
                    dirty.Add(target.Intersect(surface));
                }
            }
        }
        if (full) presenter.Present([]);
        else if (dirty.Count > 0) presenter.Present([.. dirty]);
        layout = placement;
        Adopt(haveFrame, frame);
        Count(started, full, rendered, cached);
    }

    private void ClearLetterbox(TvwRect surface, TvwRect visible)
    {
        if (visible.IsEmpty) { presenter.Clear(surface); return; }
        if (visible.Y > 0) presenter.Clear(new TvwRect(0, 0, surface.Width, visible.Y));
        if (visible.Bottom < surface.Height) presenter.Clear(new TvwRect(0, visible.Bottom, surface.Width, surface.Height - visible.Bottom));
        if (visible.X > 0) presenter.Clear(new TvwRect(0, visible.Y, visible.X, visible.Height));
        if (visible.Right < surface.Width) presenter.Clear(new TvwRect(visible.Right, visible.Y, surface.Width - visible.Right, visible.Height));
    }

    private void Adopt(bool haveFrame, Pending? frame)
    {
        if (!haveFrame) return;
        if (ReferenceEquals(shown, frame?.Image)) return;
        shown?.Dispose();
        shown = frame?.Image;
    }

    private void Count(long started, bool full, int rendered, int cached)
    {
        var elapsed = Stopwatch.GetElapsedTime(started);
        DesktopRenderStatistics statistics;
        lock (gate)
        {
            frames++; tilesRendered += rendered; tilesCached += cached;
            if (full) fullRedraws++;
            lastFrame = elapsed;
            if (elapsed > worstFrame) worstFrame = elapsed;
            statistics = new(frames, tilesRendered, tilesCached, fullRedraws, lastFrame, worstFrame, deviceResets);
        }
        if (Presented is { } handler) ui.TryEnqueue(() => handler(statistics));
    }

    /// <summary>Stops the render thread and releases the presenter, frames and tile cache.</summary>
    public void Dispose()
    {
        lock (gate)
        {
            if (stopping) return;
            stopping = true;
            pendingFrame?.Image.Dispose();
            pendingFrame = null;
        }
        wake.Set();
        thread.Join();
        presenter.Dispose();
        renderer.Dispose();
        wake.Dispose();
    }
}
