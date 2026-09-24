// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using TidyVNC.Native.Desktop;

namespace TidyVNC;

/// <summary>
/// The desktop view for UI Automation (UX.md section 10, PARITY V02 and W18):
/// an Image named Remote desktop with the macOS help text. Panning is the
/// Scroll pattern (percentages, view size, scroll by page); Invoke focuses the
/// view. Narrator cannot read the remote computer's interface (RFB sends pixels).
/// </summary>
internal sealed partial class DesktopAutomationPeer(DesktopView owner) : FrameworkElementAutomationPeer(owner), IScrollProvider, IInvokeProvider
{
    private (double X, double Y) scroll = (-1, -1), view = (100, 100);

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Image;
    protected override string GetClassNameCore() => nameof(DesktopView);
    protected override bool IsKeyboardFocusableCore() => true;
    protected override object GetPatternCore(PatternInterface patternInterface) =>
        patternInterface is PatternInterface.Scroll or PatternInterface.Invoke ? this : base.GetPatternCore(patternInterface);

    private NativeGeometry? Geometry => owner.PanGeometry;

    public bool HorizontallyScrollable => Geometry?.ScrollPercent.X >= 0;
    public bool VerticallyScrollable => Geometry?.ScrollPercent.Y >= 0;
    public double HorizontalScrollPercent => Geometry?.ScrollPercent.X ?? -1;
    public double VerticalScrollPercent => Geometry?.ScrollPercent.Y ?? -1;
    public double HorizontalViewSize => Geometry?.ViewPercent.X ?? 100;
    public double VerticalViewSize => Geometry?.ViewPercent.Y ?? 100;

    /// <summary>Small and large increments both pan by the view's step (80% of the view, as the menu commands do).</summary>
    public void Scroll(ScrollAmount horizontalAmount, ScrollAmount verticalAmount)
    {
        if (Geometry is null) throw new InvalidOperationException("The remote desktop is not shown");
        Step(horizontalAmount, NativeDesktopPan.Left, NativeDesktopPan.Right, HorizontallyScrollable);
        Step(verticalAmount, NativeDesktopPan.Up, NativeDesktopPan.Down, VerticallyScrollable);
    }

    private void Step(ScrollAmount amount, NativeDesktopPan back, NativeDesktopPan forward, bool scrollable)
    {
        if (amount == ScrollAmount.NoAmount) return;
        if (!scrollable) throw new InvalidOperationException("The remote desktop fits on this axis");
        owner.Pan(amount is ScrollAmount.LargeDecrement or ScrollAmount.SmallDecrement ? back : forward);
    }

    public void SetScrollPercent(double horizontalPercent, double verticalPercent)
    {
        if (Geometry is null) throw new InvalidOperationException("The remote desktop is not shown");
        static bool Invalid(double value) => double.IsNaN(value) || (value != -1 && (value < 0 || value > 100));
        if (Invalid(horizontalPercent) || Invalid(verticalPercent)) throw new ArgumentOutOfRangeException(nameof(horizontalPercent));
        if ((horizontalPercent >= 0 && !HorizontallyScrollable) || (verticalPercent >= 0 && !VerticallyScrollable))
            throw new InvalidOperationException("The remote desktop fits on this axis");
        owner.PanTo(horizontalPercent, verticalPercent);
    }

    public void Invoke() => owner.FocusForCommand();

    /// <summary>Tells assistive technology about a new pan, zoom or view size.</summary>
    public void GeometryChanged()
    {
        var nextScroll = (HorizontalScrollPercent, VerticalScrollPercent);
        var nextView = (HorizontalViewSize, VerticalViewSize);
        if (nextScroll.HorizontalScrollPercent != scroll.X)
            RaisePropertyChangedEvent(ScrollPatternIdentifiers.HorizontalScrollPercentProperty, scroll.X, nextScroll.HorizontalScrollPercent);
        if (nextScroll.VerticalScrollPercent != scroll.Y)
            RaisePropertyChangedEvent(ScrollPatternIdentifiers.VerticalScrollPercentProperty, scroll.Y, nextScroll.VerticalScrollPercent);
        if (nextView.HorizontalViewSize != view.X)
            RaisePropertyChangedEvent(ScrollPatternIdentifiers.HorizontalViewSizeProperty, view.X, nextView.HorizontalViewSize);
        if (nextView.VerticalViewSize != view.Y)
            RaisePropertyChangedEvent(ScrollPatternIdentifiers.VerticalViewSizeProperty, view.Y, nextView.VerticalViewSize);
        if ((scroll.X >= 0) != (nextScroll.HorizontalScrollPercent >= 0))
            RaisePropertyChangedEvent(ScrollPatternIdentifiers.HorizontallyScrollableProperty, scroll.X >= 0, nextScroll.HorizontalScrollPercent >= 0);
        if ((scroll.Y >= 0) != (nextScroll.VerticalScrollPercent >= 0))
            RaisePropertyChangedEvent(ScrollPatternIdentifiers.VerticallyScrollableProperty, scroll.Y >= 0, nextScroll.VerticalScrollPercent >= 0);
        scroll = (nextScroll.HorizontalScrollPercent, nextScroll.VerticalScrollPercent);
        view = (nextView.HorizontalViewSize, nextView.VerticalViewSize);
    }
}
