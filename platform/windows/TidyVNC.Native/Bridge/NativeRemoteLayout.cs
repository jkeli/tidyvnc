// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

public readonly record struct NativeRemoteScreen(uint Id, uint X, uint Y, uint Width, uint Height, uint Flags = 0)
{
    internal tidyvnc_remote_screen ToAbi() => new() { id = Id, x = X, y = Y, width = Width, height = Height, flags = Flags };
}

/// <summary>A validated remote desktop layout request (NativeRemoteLayout).</summary>
public sealed record NativeRemoteLayout
{
    public uint Width { get; }
    public uint Height { get; }
    public IReadOnlyList<NativeRemoteScreen> Screens { get; }

    public unsafe NativeRemoteLayout(uint width, uint height, IReadOnlyList<NativeRemoteScreen> screens)
    {
        if (screens.Count > 255) throw new NativeError(NativeStatus.InvalidArgument, "Too many remote screens");
        Width = width; Height = height; Screens = screens.ToArray();
        var values = Screens.Select(s => s.ToAbi()).ToArray();
        var error = Abi.Init<tidyvnc_error>();
        fixed (tidyvnc_remote_screen* p = values)
        {
            var request = Abi.Init<tidyvnc_desktop_layout_request>();
            request.width = width; request.height = height; request.screen_count = (uint)values.Length; request.screens = p;
            Abi.Check(NativeMethods.tidyvnc_desktop_layout_validate(&request, &error), &error);
        }
    }

    public bool Equals(NativeRemoteLayout? other)
        => other is not null && Width == other.Width && Height == other.Height && Screens.SequenceEqual(other.Screens);

    public override int GetHashCode() => HashCode.Combine(Width, Height, Screens.Count);
}

public sealed record NativeRemoteDesktop(NativeRemoteLayout Layout, NativeSnapshot Snapshot)
{
    internal static NativeRemoteDesktop From(tidyvnc_desktop_layout value)
    {
        if (value.screen_count == 0 || value.screen_count > 255) throw new NativeError(NativeStatus.InternalFailure, "Invalid remote layout");
        var screens = new List<NativeRemoteScreen>();
        for (var i = 0; i < value.screen_count; i++)
        {
            var s = value.screens[i];
            screens.Add(new NativeRemoteScreen(s.id, s.x, s.y, s.width, s.height, s.flags));
        }
        return new NativeRemoteDesktop(new NativeRemoteLayout(value.snapshot.width, value.snapshot.height, screens),
                                       NativeSnapshot.From(value.snapshot));
    }
}
