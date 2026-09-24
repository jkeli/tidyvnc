// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Desktop;
using TidyVNC.Native.Platform;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Pointer, wheel, pen and touch input (plans/native-ui-winui TODO W6.6, W6.7;
/// DESKTOP.md sections 4 and 6). The gesture engine's equivalence with the
/// retained classes is tests/unit/windows/touchgestures.cxx; this checks the
/// managed binding through tidyvnc_windows.dll.
/// </summary>
[TestClass]
public sealed class PointerInputTests
{
    [TestMethod]
    public void ButtonsPenAndWheelFollowTheRetainedMapping()
    {
        Assert.AreEqual(NativePointerButtons.Left | NativePointerButtons.Right, NativePointerButtons.Mouse(true, false, true, false, false));
        Assert.AreEqual(128u | 256u, NativePointerButtons.Mouse(false, false, false, true, true), "back and forward");
        Assert.AreEqual(NativePointerButtons.Left, NativePointerButtons.Pen(contact: true, barrel: false, eraser: false));
        Assert.AreEqual(NativePointerButtons.Right, NativePointerButtons.Pen(contact: true, barrel: true, eraser: false));
        Assert.AreEqual(0u, NativePointerButtons.Pen(contact: true, barrel: false, eraser: true), "the eraser is ignored");
        Assert.AreEqual(0u, NativePointerButtons.Pen(contact: false, barrel: true, eraser: false), "hovering presses nothing");
        Assert.AreEqual(8u, NativePointerButtons.FromButtonNumber(4));

        var wheel = new NativeWheelAccumulator();
        Assert.AreEqual(0, wheel.Add(40, false), "a partial delta waits");
        Assert.AreEqual(0, wheel.Add(40, false));
        Assert.AreEqual(1, wheel.Add(40, false), "three thirds make one notch");
        Assert.AreEqual(2, wheel.Add(240, false));
        Assert.AreEqual(0, wheel.Add(-60, false), "a reversal drops the old remainder");
        Assert.AreEqual(-1, wheel.Add(-60, false));
        Assert.AreEqual(1, wheel.Add(120, true), "axes accumulate separately");
    }

    [TestMethod]
    public void TouchGesturesProduceTheRetainedEventsThroughTheHelper()
    {
        ulong now = 5000;
        using var touch = new NativeTouch(() => now);
        Assert.AreEqual(0, touch.Begin(1, 100, 80).Count);
        Assert.IsNotNull(touch.Deadline, "the long-press timer is armed");
        now += 60;
        var tap = touch.End(1);
        CollectionAssert.AreEqual(new[] { NativeTouchAction.ActionKind.Motion, NativeTouchAction.ActionKind.Button, NativeTouchAction.ActionKind.Button },
            tap.Select(a => a.Kind).ToArray());
        Assert.IsTrue(tap[1].Press && tap[1].Button == 1 && !tap[2].Press, "a tap is a left click");
        Assert.AreEqual(100, tap[0].X);
        Assert.IsNull(touch.Deadline);

        now += 2000;
        touch.Begin(2, 300, 300);
        now += (ulong)(touch.Deadline!.Value - now);
        var hold = touch.Timeout();
        Assert.IsTrue(hold.Any(a => a.Kind == NativeTouchAction.ActionKind.Button && a.Press && a.Button == 3), "a long press holds the right button");
        now += 50;
        var release = touch.End(2);
        Assert.IsTrue(release.Any(a => a.Kind == NativeTouchAction.ActionKind.Button && !a.Press && a.Button == 3));
    }
}
