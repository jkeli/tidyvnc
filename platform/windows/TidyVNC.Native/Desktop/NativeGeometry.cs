// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Text;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native.Desktop;

public enum NativeScalingFilter : uint { Nearest = 0, Bilinear = 1, Area = 2 }

/// <summary>
/// The shared desktop transform (tidyvnc_desktop_geometry), the counterpart of
/// Swift NativeGeometry. Viewport and placement are logical (DIP) units; the
/// backing size is the scaled desktop in device pixels.
/// </summary>
public sealed unsafe class NativeGeometry
{
    private readonly tidyvnc_geometry_options options;
    private readonly byte[] scaling;

    public uint RemoteWidth => options.remote_width;
    public uint RemoteHeight => options.remote_height;
    public uint BackingWidth { get; }
    public uint BackingHeight { get; }
    /// <summary>The desktop's placement in the view, logical units.</summary>
    public double X { get; }
    public double Y { get; }
    public double Width { get; }
    public double Height { get; }
    public double BackingScale => options.backing_scale;
    public double ViewportWidth => options.viewport_width;
    public double ViewportHeight => options.viewport_height;
    public bool IsIdentity => BackingWidth == RemoteWidth && BackingHeight == RemoteHeight;

    public NativeGeometry(uint width, uint height, double viewportWidth, double viewportHeight, double backingScale,
                          string scaling = "FixedRatio", bool devicePixels = false, double panX = 0, double panY = 0)
    {
        this.scaling = Encoding.UTF8.GetBytes(scaling);
        var value = Abi.Init<tidyvnc_geometry_options>();
        value.remote_width = width; value.remote_height = height; value.units = devicePixels ? 1u : 0u;
        value.viewport_width = viewportWidth; value.viewport_height = viewportHeight;
        value.backing_scale = backingScale; value.pan_x = panX; value.pan_y = panY;
        options = value;
        var result = Compute(0, 0);
        BackingWidth = result.backing_width; BackingHeight = result.backing_height;
        X = result.x; Y = result.y; Width = result.width; Height = result.height;
    }

    private tidyvnc_geometry Compute(double pointX, double pointY)
    {
        var input = options;
        var output = Abi.Init<tidyvnc_geometry>();
        var error = Abi.Init<tidyvnc_error>();
        fixed (byte* text = scaling)
        {
            input.scaling = NativeText.Span(text, scaling.Length);
            Abi.Check(NativeMethods.tidyvnc_desktop_geometry(&input, pointX, pointY, &output, &error), &error);
        }
        return output;
    }

    /// <summary>The remote pixel under a logical point (clamped to the desktop).</summary>
    public (int X, int Y) RemotePoint(double x, double y)
    {
        var result = Compute(x, y);
        return (result.remote_x, result.remote_y);
    }

    /// <summary>Remote damage mapped into this transform's output units (with the filter halo).</summary>
    public (double X, double Y, double Width, double Height) Damage(NativePixelRect damage, NativeScalingFilter filter)
    {
        var input = options;
        var region = Abi.Init<tidyvnc_damage>();
        region.x = damage.X; region.y = damage.Y; region.width = damage.Width; region.height = damage.Height;
        region.quality = (uint)filter;
        var result = Abi.Init<tidyvnc_rectangle>();
        var error = Abi.Init<tidyvnc_error>();
        fixed (byte* text = scaling)
        {
            input.scaling = NativeText.Span(text, scaling.Length);
            Abi.Check(NativeMethods.tidyvnc_desktop_damage(&input, &region, &result, &error), &error);
        }
        return (result.x, result.y, result.width, result.height);
    }
}
