// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
namespace TidyVNC.Native.Platform;

/// <summary>
/// The Direct3D 11 presenter for one desktop view (DESKTOP.md section 1, D11).
/// Attach on the UI thread; resize, clear, upload and present on the view's
/// render thread. After a device-lost result, dispose it and create another.
/// </summary>
public sealed unsafe class NativePresenter : IDisposable
{
    private IntPtr handle;
    private readonly Lock gate = new();

    public NativePresenter()
    {
        IntPtr value;
        WindowsResult.Check(WindowsMethods.tvw_presenter_create(&value), "Creating the Direct3D presenter");
        handle = value;
    }

    public uint Width { get; private set; }
    public uint Height { get; private set; }

    private IntPtr Handle => handle != IntPtr.Zero ? handle : throw new ObjectDisposedException(nameof(NativePresenter));

    /// <summary>Binds the swap chain to a SwapChainPanel (its IUnknown). UI thread.</summary>
    public void Attach(IntPtr panel)
    {
        lock (gate) WindowsResult.Check(WindowsMethods.tvw_presenter_attach(Handle, panel), "Attaching the swap chain");
    }

    public void Resize(uint width, uint height, float scaleX, float scaleY)
    {
        lock (gate)
        {
            WindowsResult.Check(WindowsMethods.tvw_presenter_resize(Handle, width, height, scaleX, scaleY), "Resizing the swap chain");
            Width = width; Height = height;
        }
    }

    public void Clear(TvwRect area)
    {
        lock (gate) WindowsResult.Check(WindowsMethods.tvw_presenter_clear(Handle, &area), "Clearing the desktop surface");
    }

    public void Upload(ReadOnlySpan<byte> bgra, uint stride, TvwRect area)
    {
        if (area.IsEmpty) return;
        if ((ulong)bgra.Length < (ulong)stride * (uint)(area.Height - 1) + (uint)area.Width * 4u)
            throw new ArgumentException("Pixel span is smaller than the area", nameof(bgra));
        lock (gate)
            fixed (byte* pixels = bgra)
                WindowsResult.Check(WindowsMethods.tvw_presenter_upload(Handle, pixels, stride, &area), "Uploading desktop pixels");
    }

    /// <summary>Presents; an empty span presents the whole surface.</summary>
    public void Present(ReadOnlySpan<TvwRect> dirty)
    {
        lock (gate)
            fixed (TvwRect* rects = dirty)
                WindowsResult.Check(WindowsMethods.tvw_presenter_present(Handle, rects, (uint)dirty.Length), "Presenting the desktop");
    }

    /// <summary>Reads back tightly packed BGRA (tests and diagnostics).</summary>
    public byte[] Read(TvwRect area)
    {
        var pixels = new byte[area.Width * area.Height * 4];
        lock (gate)
            fixed (byte* data = pixels)
                WindowsResult.Check(WindowsMethods.tvw_presenter_read(Handle, &area, data, (uint)area.Width * 4), "Reading the desktop surface");
        return pixels;
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (handle == IntPtr.Zero) return;
            WindowsMethods.tvw_presenter_destroy(handle);
            handle = IntPtr.Zero;
        }
    }
}
