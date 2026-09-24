// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
namespace TidyVNC.Native.Desktop;

/// <summary>
/// Pointer, wheel and pen input for the desktop view (DESKTOP.md section 4,
/// PARITY V07 and W02): the retained RFB button bits for mouse buttons,
/// including back and forward (X1, X2 as in vncviewer/Viewport.cxx), and pen
/// input as a mouse (tip = left, barrel = right, eraser ignored).
/// </summary>
public static class NativePointerButtons
{
    public const uint Left = 1, Middle = 2, Right = 4, WheelUp = 8, WheelDown = 16, WheelLeft = 32, WheelRight = 64,
                      Back = 1u << 7, Forward = 1u << 8;

    public static uint Mouse(bool left, bool middle, bool right, bool x1, bool x2) =>
        (left ? Left : 0) | (middle ? Middle : 0) | (right ? Right : 0) | (x1 ? Back : 0) | (x2 ? Forward : 0);

    /// <summary>A pen in contact presses left, or right while its barrel button is held; the eraser sends nothing.</summary>
    public static uint Pen(bool contact, bool barrel, bool eraser) =>
        eraser || !contact ? 0 : barrel ? Right : Left;

    /// <summary>A touch gesture's retained button number (1-7) as its RFB bit.</summary>
    public static uint FromButtonNumber(int button) => button is >= 1 and <= 9 ? 1u << (button - 1) : 0;
}

/// <summary>
/// Wheel deltas to whole notches (120 units each). High-resolution wheels and
/// precision touchpads send partial deltas; the remainder carries over per axis
/// until a direction change or <see cref="Reset"/>.
/// </summary>
public sealed class NativeWheelAccumulator
{
    public const int Notch = 120;
    private int vertical, horizontal;

    /// <summary>Whole notches for this delta: positive is up (or right), negative down (or left).</summary>
    public int Add(int delta, bool isHorizontal)
    {
        ref var total = ref isHorizontal ? ref horizontal : ref vertical;
        if (total != 0 && Math.Sign(total) != Math.Sign(delta)) total = 0; // A reversal starts afresh.
        total += delta;
        var notches = total / Notch;
        total -= notches * Notch;
        return notches;
    }

    public void Reset() => vertical = horizontal = 0;
}
