// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;

namespace TidyVNC;

/// <summary>
/// The full-screen connection bar (UX.md section 7): a small bar at the top
/// centre of the primary surface, shown when the pointer rests at the top
/// edge for half a second and hidden again when the pointer leaves it unless
/// pinned or one of its menus is open. It carries the server name, the
/// Connection menu, statistics, Minimize, Exit full screen and the pin. The
/// Windows counterpart of the macOS menu bar at the top edge in full screen.
/// </summary>
internal sealed partial class FullscreenConnectionBar : UserControl
{
    private readonly ConnectionWindow window;
    private readonly TextBlock title = new() { VerticalAlignment = VerticalAlignment.Center, MaxWidth = 320, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly ToggleButton statistics, pin;
    private readonly MenuFlyout menu = new();
    private readonly DispatcherQueueTimer reveal;
    private bool menuOpen, over;

    public FullscreenConnectionBar(ConnectionWindow window)
    {
        this.window = window;
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Top;
        Visibility = Visibility.Collapsed;
        AutomationProperties.SetAutomationId(this, "fullscreen.bar");

        var connection = new DropDownButton { Content = Strings.Get("app.menu.connection"), Flyout = menu };
        AutomationProperties.SetAutomationId(connection, "fullscreen.bar.menu");
        menu.Opening += (_, _) => { menuOpen = true; ConnectionMenu.Fill(menu.Items, window); };
        menu.Closed += (_, _) => { menuOpen = false; HideUnlessNeeded(); };
        statistics = Toggle("", "desktop.show.connection.statistics", "fullscreen.bar.statistics");
        statistics.Click += (_, _) => window.Controller.ToggleStatistics();
        var minimize = Icon("", "desktop.minimize", "fullscreen.bar.minimize");
        minimize.Click += (_, _) => window.MinimizeWindow();
        var exit = Icon("", "desktop.exit.full.screen", "fullscreen.bar.exit");
        exit.Click += (_, _) => window.ToggleFullscreen();
        pin = Toggle("", "desktop.bar.pin", "fullscreen.bar.pin");
        pin.Click += (_, _) => HideUnlessNeeded();

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        foreach (var child in new UIElement[] { title, connection, statistics, minimize, exit, pin }) row.Children.Add(child);
        title.Margin = new Thickness(8, 0, 8, 0);
        Content = Ui.Surface(new Border
        {
            Child = row, Padding = new Thickness(8, 4, 8, 4), CornerRadius = new CornerRadius(0, 0, 8, 8), BorderThickness = new Thickness(1, 0, 1, 1),
        }, "TidyBarSurface");
        PointerEntered += (_, _) => over = true;
        PointerExited += (_, _) => { over = false; HideUnlessNeeded(); };

        reveal = DispatcherQueue.GetForCurrentThread().CreateTimer();
        reveal.Interval = TimeSpan.FromMilliseconds(500);
        reveal.IsRepeating = false;
        reveal.Tick += (_, _) => Show();
    }

    private static Button Icon(string glyph, string key, string id)
    {
        var button = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 14 } };
        Describe(button, key, id);
        return button;
    }

    private static ToggleButton Toggle(string glyph, string key, string id)
    {
        var button = new ToggleButton { Content = new FontIcon { Glyph = glyph, FontSize = 14 } };
        Describe(button, key, id);
        return button;
    }

    private static void Describe(FrameworkElement element, string key, string id)
    {
        AutomationProperties.SetName(element, Strings.Get(key));
        AutomationProperties.SetAutomationId(element, id);
        ToolTipService.SetToolTip(element, Strings.Get(key));
    }

    /// <summary>The surface reports the pointer; resting at the top edge reveals the bar.</summary>
    public void PointerMovedOnSurface(PointerRoutedEventArgs e, UIElement surface)
    {
        var y = e.GetCurrentPoint(surface).Position.Y;
        if (y <= 2) { if (!reveal.IsRunning && Visibility != Visibility.Visible) reveal.Start(); }
        else reveal.Stop();
    }

    public void Show()
    {
        Refresh();
        Visibility = Visibility.Visible;
    }

    private void HideUnlessNeeded()
    {
        if (pin.IsChecked == true || menuOpen || over) return;
        Visibility = Visibility.Collapsed;
    }

    public void Refresh()
    {
        title.Text = window.Title;
        statistics.IsChecked = window.Controller.ShowsStatistics;
        statistics.IsEnabled = window.Controller.CanToggleStatistics;
    }

    public void Stop()
    {
        reveal.Stop();
        menu.Hide();
        Visibility = Visibility.Collapsed;
    }
}
