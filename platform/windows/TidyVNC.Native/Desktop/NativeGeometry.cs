// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Text;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native.Desktop;

public enum NativeScalingFilter : uint { Nearest = 0, Bilinear = 1, Area = 2 }

/// <summary>Pan desktop (PARITY M12): a step of 80% of the view, or back to the top left.</summary>
public enum NativeDesktopPan { Left, Right, Up, Down, Origin }

/// <summary>
/// One display's region of a shared fullscreen canvas (tidyvnc_canvas_viewport):
/// the canvas size and the region, in the geometry's selected units. Fitting
/// uses the whole canvas; each surface draws and maps only its region.
/// </summary>
public sealed unsafe record NativeCanvasViewport
{
    public uint Width { get; }
    public uint Height { get; }
    public uint X { get; }
    public uint Y { get; }
    public uint RegionWidth { get; }
    public uint RegionHeight { get; }
    public bool DevicePixels { get; }

    public NativeCanvasViewport(uint width, uint height, uint x, uint y, uint regionWidth, uint regionHeight, bool devicePixels)
    {
        Width = width; Height = height; X = x; Y = y; RegionWidth = regionWidth; RegionHeight = regionHeight; DevicePixels = devicePixels;
        // Validated by the core with a trivial transform.
        var options = Abi.Init<tidyvnc_geometry_options>();
        options.remote_width = 1; options.remote_height = 1; options.viewport_width = 1; options.viewport_height = 1; options.backing_scale = 1;
        var canvas = Value;
        var result = Abi.Init<tidyvnc_geometry>();
        var error = Abi.Init<tidyvnc_error>();
        var text = "100"u8;
        fixed (byte* bytes = text)
        {
            options.scaling = AbiText.Span(bytes, text.Length);
            Abi.Check(NativeMethods.tidyvnc_desktop_canvas_geometry(&options, &canvas, 0, 0, &result, &error), &error);
        }
    }

    internal tidyvnc_canvas_viewport Value
    {
        get
        {
            var value = Abi.Init<tidyvnc_canvas_viewport>();
            value.width = Width; value.height = Height; value.x = X; value.y = Y;
            value.region_width = RegionWidth; value.region_height = RegionHeight;
            return value;
        }
    }
}

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

    public NativeCanvasViewport? Canvas { get; }

    public NativeGeometry(uint width, uint height, double viewportWidth, double viewportHeight, double backingScale,
                          string scaling = "FixedRatio", bool devicePixels = false, double panX = 0, double panY = 0,
                          NativeCanvasViewport? canvas = null)
    {
        this.scaling = Encoding.UTF8.GetBytes(scaling);
        Canvas = canvas;
        var value = Abi.Init<tidyvnc_geometry_options>();
        value.remote_width = width; value.remote_height = height; value.units = (canvas?.DevicePixels ?? devicePixels) ? 1u : 0u;
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
            input.scaling = AbiText.Span(text, scaling.Length);
            if (Canvas is { } canvas)
            {
                var region = canvas.Value;
                Abi.Check(NativeMethods.tidyvnc_desktop_canvas_geometry(&input, &region, pointX, pointY, &output, &error), &error);
            }
            else Abi.Check(NativeMethods.tidyvnc_desktop_geometry(&input, pointX, pointY, &output, &error), &error);
        }
        return output;
    }

    // Pan uses the selected sizing units, while the view and pointer use logical
    // coordinates; the limit matches the shared transform's rounded canvas.
    private double PanUnits => options.units == 1 ? BackingScale : 1;

    /// <summary>How far the desktop can pan: zero on an axis where it fits the view.</summary>
    public (double X, double Y) PanLimit => (
        Math.Min(65535, Math.Max(0, Width * PanUnits - (Canvas is { } c ? c.Width : Math.Ceiling(ViewportWidth * PanUnits)))),
        Math.Min(65535, Math.Max(0, Height * PanUnits - (Canvas is { } d ? d.Height : Math.Ceiling(ViewportHeight * PanUnits)))));

    /// <summary>The pan in effect, within the limit.</summary>
    public (double X, double Y) PanPosition => (Math.Min(options.pan_x, PanLimit.X), Math.Min(options.pan_y, PanLimit.Y));

    /// <summary>The pan after one step in a direction (macOS NativeGeometry.panned).</summary>
    public (double X, double Y) Panned(NativeDesktopPan direction)
    {
        var (x, y) = PanPosition;
        var (limitX, limitY) = PanLimit;
        return direction switch
        {
            NativeDesktopPan.Left => (Math.Max(0, x - ViewportWidth * PanUnits * 0.8), y),
            NativeDesktopPan.Right => (Math.Min(limitX, x + ViewportWidth * PanUnits * 0.8), y),
            NativeDesktopPan.Up => (x, Math.Max(0, y - ViewportHeight * PanUnits * 0.8)),
            NativeDesktopPan.Down => (x, Math.Min(limitY, y + ViewportHeight * PanUnits * 0.8)),
            _ => (0, 0),
        };
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
            input.scaling = AbiText.Span(text, scaling.Length);
            if (Canvas is { } canvas)
            {
                var viewport = canvas.Value;
                Abi.Check(NativeMethods.tidyvnc_desktop_canvas_damage(&input, &viewport, &region, &result, &error), &error);
            }
            else Abi.Check(NativeMethods.tidyvnc_desktop_damage(&input, &region, &result, &error), &error);
        }
        return (result.x, result.y, result.width, result.height);
    }
}
