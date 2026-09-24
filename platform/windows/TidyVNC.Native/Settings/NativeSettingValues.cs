// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Immutable;
using TidyVNC.Native.Desktop;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

// Frontend-owned session policies (macOS NativeInputSettings, NativeScaling,
// NativeFullscreenPolicy, NativeRemoteResizePolicy, NativeWindowStartupPolicy,
// NativeNetworkPolicy). Parsing always goes through the shared core parsers;
// these types only hold validated values.

public enum NativeCursorFallback { Hidden, Dot, System }

public enum NativeInputOption { ViewOnly, EmulateMiddle, ShortcutModifiers, FullscreenSystemKeys, CursorFallback }

public sealed record NativeInputSettings(
    bool ViewOnly = false, bool EmulateMiddle = false,
    NativeShortcutModifiers ShortcutModifiers = NativeShortcutModifiers.BuiltIn,
    bool FullscreenSystemKeys = true, NativeCursorFallback CursorFallback = NativeCursorFallback.Hidden)
{
    public static NativeInputSettings BuiltIn { get; } = new();

    /// <summary>The canonical ShortcutModifiers value ("Ctrl,Alt"; empty disables shortcuts).</summary>
    public static string Canonical(NativeShortcutModifiers modifiers)
    {
        var names = new List<string>(4);
        if (modifiers.HasFlag(NativeShortcutModifiers.Control)) names.Add("Ctrl");
        if (modifiers.HasFlag(NativeShortcutModifiers.Shift)) names.Add("Shift");
        if (modifiers.HasFlag(NativeShortcutModifiers.Option)) names.Add("Alt");
        if (modifiers.HasFlag(NativeShortcutModifiers.Command)) names.Add("Super");
        return string.Join(',', names);
    }

    /// <summary>Parses a canonical ShortcutModifiers value (the core has already validated it).</summary>
    public static NativeShortcutModifiers ParseModifiers(string canonical) =>
        canonical.Split(',', StringSplitOptions.RemoveEmptyEntries).Aggregate(NativeShortcutModifiers.None, (mask, name) => mask | name switch
        {
            "Ctrl" => NativeShortcutModifiers.Control,
            "Shift" => NativeShortcutModifiers.Shift,
            "Alt" => NativeShortcutModifiers.Option,
            "Super" => NativeShortcutModifiers.Command,
            _ => throw new ArgumentException("Unknown shortcut modifier", nameof(canonical)),
        });
}

public enum NativeScalingMode : uint { Unscaled = 0, Automatic, FixedRatio, FitWidth, FitHeight, Exact, Percent, Independent }

public enum NativeScalingOption { Scaling, DevicePixels, Filter }

public static class NativeScalingModes
{
    public static bool Fits(this NativeScalingMode mode) =>
        mode is NativeScalingMode.Automatic or NativeScalingMode.FixedRatio or NativeScalingMode.FitWidth or NativeScalingMode.FitHeight;

    public static bool Custom(this NativeScalingMode mode) =>
        mode is NativeScalingMode.Exact or NativeScalingMode.Percent or NativeScalingMode.Independent;

    /// <summary>The text a mode starts with when chosen in a dialog (macOS initialText).</summary>
    public static string InitialText(this NativeScalingMode mode) => mode switch
    {
        NativeScalingMode.Unscaled => "100",
        NativeScalingMode.Automatic => "Auto",
        NativeScalingMode.FixedRatio => "FixedRatio",
        NativeScalingMode.FitWidth => "FitWidth",
        NativeScalingMode.FitHeight => "FitHeight",
        NativeScalingMode.Exact => "1920x1080",
        NativeScalingMode.Percent => "137.5",
        _ => "125%x80%",
    };

    /// <summary>The canonical ScalingQuality value.</summary>
    public static string Canonical(this NativeScalingFilter filter) => filter switch
    {
        NativeScalingFilter.Nearest => "Nearest",
        NativeScalingFilter.Area => "Area",
        _ => "Bilinear",
    };

    public static NativeScalingFilter ParseFilter(string canonical) => canonical switch
    {
        "Nearest" => NativeScalingFilter.Nearest,
        "Area" => NativeScalingFilter.Area,
        "Bilinear" => NativeScalingFilter.Bilinear,
        _ => throw new ArgumentException("Unknown scaling quality", nameof(canonical)),
    };
}

/// <summary>A scaling selection parsed by the shared core parser (tidyvnc_scaling_parse).</summary>
public sealed record NativeScaling(NativeScalingMode Mode, string Canonical, uint X, uint Y, bool DevicePixels, NativeScalingFilter Filter)
{
    public static NativeScaling BuiltIn { get; } = new(NativeScalingMode.FixedRatio, "FixedRatio", 10000, 10000, false, NativeScalingFilter.Bilinear);

    public static unsafe NativeScaling Parse(string text, bool devicePixels = false, NativeScalingFilter filter = NativeScalingFilter.Bilinear)
    {
        var bytes = AbiText.Utf8(text);
        if (bytes.Length > 64) throw new NativeError(NativeStatus.InvalidArgument, "Scaling text is too long");
        var value = Abi.Init<tidyvnc_scaling>();
        var error = Abi.Init<tidyvnc_error>();
        fixed (byte* data = bytes)
            Abi.Check(NativeMethods.tidyvnc_scaling_parse(AbiText.Span(data, bytes.Length), &value, &error), &error);
        if (!Enum.IsDefined((NativeScalingMode)value.mode)) throw new NativeError(NativeStatus.InternalFailure, "Unknown scaling mode");
        return new NativeScaling((NativeScalingMode)value.mode, AbiText.Fixed(value.canonical, 64), value.x, value.y, devicePixels, filter);
    }

    public static bool TryParse(string text, bool devicePixels, NativeScalingFilter filter, out NativeScaling? scaling)
    {
        try { scaling = Parse(text, devicePixels, filter); return true; }
        catch (NativeError) { scaling = null; return false; }
    }
}

public enum NativeFullscreenMode { Current, All, Selected }

public enum NativeFullscreenOption { StartsFullscreen, Mode, SelectedDisplays }

/// <summary>Where full screen opens; Selected needs at least one stable display ID.</summary>
public sealed record NativeFullscreenPolicy
{
    public bool StartsFullscreen { get; }
    public NativeFullscreenMode Mode { get; }
    public ImmutableArray<string> SelectedDisplays { get; }

    public static NativeFullscreenPolicy BuiltIn { get; } = new(false, NativeFullscreenMode.Current, []);

    public NativeFullscreenPolicy(bool startsFullscreen, NativeFullscreenMode mode, IEnumerable<string> selectedDisplays)
    {
        var ids = selectedDisplays.ToImmutableArray();
        ValidateIds(ids);
        if (mode == NativeFullscreenMode.Selected && ids.IsEmpty) throw new ArgumentException("Selected mode needs displays", nameof(selectedDisplays));
        StartsFullscreen = startsFullscreen; Mode = mode;
        SelectedDisplays = [.. ids.Order(StringComparer.Ordinal)];
    }

    public static void ValidateIds(IReadOnlyCollection<string> ids)
    {
        if (ids.Count > 64 || ids.Distinct(StringComparer.Ordinal).Count() != ids.Count ||
            ids.Any(id => id.Length is 0 or > 256 || id.Any(c => c < 32 || c == 127)))
            throw new ArgumentException("Invalid display selection", nameof(ids));
    }

    public static string Canonical(NativeFullscreenMode mode) => mode.ToString();

    public bool Equals(NativeFullscreenPolicy? other) => other is not null && StartsFullscreen == other.StartsFullscreen &&
                                                         Mode == other.Mode && SelectedDisplays.SequenceEqual(other.SelectedDisplays);
    public override int GetHashCode() => HashCode.Combine(StartsFullscreen, Mode, SelectedDisplays.Length);
}

public enum NativeResizeOption { Enabled, InitialSize }

/// <summary>Remote resize: automatic resizing and an optional initial size in remote pixels.</summary>
public sealed record NativeRemoteResizePolicy
{
    public bool Enabled { get; }
    /// <summary>Canonical "WxH", or empty.</summary>
    public string InitialSize { get; }
    public uint? InitialWidth { get; }
    public uint? InitialHeight { get; }

    public static NativeRemoteResizePolicy BuiltIn { get; } = new(true, "");

    /// <summary>Strict WxH (settings, profiles and dialogs); throws NativeError for invalid sizes.</summary>
    public NativeRemoteResizePolicy(bool enabled = true, string initialSize = "")
    {
        Enabled = enabled;
        if (NativeDesktopSize.Parse(initialSize, legacy: false) is { } size)
        {
            InitialWidth = size.Width; InitialHeight = size.Height; InitialSize = $"{size.Width}x{size.Height}";
        }
        else InitialSize = "";
    }

    public static bool IsValid(bool enabled, string initialSize)
    {
        try { _ = new NativeRemoteResizePolicy(enabled, initialSize); return true; }
        catch (NativeError) { return false; }
    }
}

/// <summary>The shared DesktopSize grammars (tidyvnc_desktop_size_parse).</summary>
public static class NativeDesktopSize
{
    /// <summary>Null for empty text; legacy is the retained command-line "%dx%d" leniency.</summary>
    public static unsafe (uint Width, uint Height)? Parse(string text, bool legacy)
    {
        var bytes = AbiText.Utf8(text);
        var value = Abi.Init<tidyvnc_desktop_size>();
        var error = Abi.Init<tidyvnc_error>();
        fixed (byte* data = bytes)
            Abi.Check(NativeMethods.tidyvnc_desktop_size_parse(AbiText.Span(data, bytes.Length),
                legacy ? Tidyvnc.TIDYVNC_DESKTOP_SIZE_LEGACY : Tidyvnc.TIDYVNC_DESKTOP_SIZE_STRICT, &value, &error), &error);
        return value.width == 0 ? null : (value.width, value.height);
    }
}

public enum NativeWindowStartupOption { Geometry, Maximize }

/// <summary>The retained -geometry value (tidyvnc_window_geometry_parse); absent parts are null.</summary>
public sealed record NativeWindowGeometry(int? Width, int? Height, int? X, int? Y)
{
    public static unsafe NativeWindowGeometry Parse(string text)
    {
        var bytes = AbiText.Utf8(text);
        var value = Abi.Init<tidyvnc_window_geometry>();
        var error = Abi.Init<tidyvnc_error>();
        fixed (byte* data = bytes)
            Abi.Check(NativeMethods.tidyvnc_window_geometry_parse(AbiText.Span(data, bytes.Length), &value, &error), &error);
        var sized = (value.flags & Tidyvnc.TIDYVNC_WINDOW_GEOMETRY_SIZE) != 0;
        var positioned = (value.flags & Tidyvnc.TIDYVNC_WINDOW_GEOMETRY_POSITION) != 0;
        return new NativeWindowGeometry(sized ? value.width : null, sized ? value.height : null,
                                        positioned ? value.x : null, positioned ? value.y : null);
    }
}

/// <summary>Initial window placement: applied once to a connection's ordinary window, never replayed.</summary>
public sealed record NativeWindowStartupPolicy(NativeWindowGeometry? Geometry = null, bool Maximize = false)
{
    public static NativeWindowStartupPolicy BuiltIn { get; } = new();
    public bool HasPlacement => Maximize || Geometry?.Width is not null || Geometry?.X is not null;
}

public enum NativeNetworkOption { Ipv4, Ipv6 }
