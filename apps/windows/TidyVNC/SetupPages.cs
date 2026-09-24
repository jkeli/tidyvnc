// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Immutable;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TidyVNC.Native;
using TidyVNC.Native.Desktop;
using TidyVNC.Native.Platform;
using TidyVNC.Native.Storage;

namespace TidyVNC;

/// <summary>
/// The pages a connection window shows before its session exists (macOS
/// ConnectionRoot): loading, command-line/file/profile/defaults problems with
/// their retry actions, connection file review (F01-F03) and monitor mapping.
/// Each page's Tag identifies its request so an unchanged page keeps focus.
/// </summary>
internal static class SetupPages
{
    public static FrameworkElement Loading()
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Tag = "loading" };
        panel.Children.Add(new ProgressRing { IsActive = true, Width = 20, Height = 20 });
        panel.Children.Add(Ui.Text(Strings.Get("app.loading.connection.defaults"), "connection.loading"));
        return panel;
    }

    public static FrameworkElement Problem(NativeText text, string automationId, params (string Key, string Id, Action Run)[] actions)
    {
        var panel = new StackPanel { Spacing = 16, Tag = automationId + ":" + text.Key + string.Join('|', text.Arguments) };
        var message = Ui.Text(text, automationId);
        AutomationProperties.SetLiveSetting(message, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        panel.Children.Add(message);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var (key, id, run) in actions) buttons.Children.Add(Ui.Button(Strings.Get(key), (_, _) => run(), id, accent: buttons.Children.Count == 0));
        panel.Children.Add(buttons);
        return panel;
    }

    private static string DisplayName(string id) =>
        App.Current.Displays.Snapshot.Find(id)?.Name ?? Strings.Get("document.unavailable.display");

    /// <summary>Review connection file (macOS DocumentReviewView).</summary>
    public static FrameworkElement Review(NativeDocumentReview review, Action editMapping, Action accept, Action cancel, bool listening = false)
    {
        var setup = review.Setup;
        var panel = new StackPanel { Spacing = 16, Tag = "review:" + review.Id };
        panel.Children.Add(Ui.Title(Strings.Get("document.review.connection.file"), "document.review.title"));
        panel.Children.Add(Ui.Text(listening
                ? Strings.Format("document.listen.port", setup.Endpoint.Length == 0 ? "5500" : setup.Endpoint)
                : setup.Endpoint.Length == 0 ? Strings.Get("document.no.server.address.is.stored.in.this.file.enter.one.after.opening")
                : Strings.Format("document.server", setup.Endpoint), "document.server", selectable: true));
        panel.Children.Add(Ui.Text(Strings.Get(listening
            ? "document.file.settings.override.saved.defaults.and.command.line.settings.for.every.accepted"
            : "document.file.settings.override.saved.defaults.for.this.new.connection.opening.does.not")));
        if (setup.Notices.Count != 0)
        {
            panel.Children.Add(Ui.Heading(Strings.Get("document.these.fields.will.be.ignored")));
            var list = new StackPanel { Spacing = 6 };
            AutomationProperties.SetAutomationId(list, "document.notices");
            foreach (var notice in setup.Notices) list.Children.Add(Ui.Text(notice.Text));
            panel.Children.Add(list);
        }
        if (setup.MonitorNumbers.Count != 0)
        {
            panel.Children.Add(Ui.Heading(Strings.Get("document.displays.for.this.connection")));
            var list = new StackPanel { Spacing = 6 };
            foreach (var number in setup.MonitorNumbers)
            {
                var name = setup.MonitorMapping.TryGetValue(number, out var id) ? DisplayName(id) : Strings.Get("document.unavailable.display");
                list.Children.Add(Ui.Text(Strings.Format(setup.MonitorSource == NativeOptionSource.CommandLine
                    ? "document.monitor.commandline.assignment" : "document.monitor.file.assignment", number, name)));
            }
            panel.Children.Add(list);
            panel.Children.Add(Ui.Caption(Strings.Get(review.MonitorMapping is null
                ? "document.these.assignments.follow.the.current.display.arrangement.left.to.right.and.then"
                : "document.these.are.the.display.assignments.you.chose.for.this.connection")));
            panel.Children.Add(Ui.Button(Strings.Get("document.change.display.assignments"), (_, _) => editMapping(), "document.mapping.edit"));
        }
        var buttons = new Grid { ColumnSpacing = 8 };
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var acceptButton = Ui.Button(Strings.Get(listening
            ? setup.Notices.Count == 0 ? "listener.start.listening" : "document.ignore.listed.fields.and.listen"
            : setup.Notices.Count == 0 ? "profiles.open.connection" : "document.ignore.listed.fields.and.open"), (_, _) => accept(), "document.accept", accent: true);
        var cancelButton = Ui.Button(Strings.Get("action.cancel"), (_, _) => cancel(), "document.cancel");
        Grid.SetColumn(cancelButton, 1);
        cancelButton.HorizontalAlignment = HorizontalAlignment.Left;
        buttons.Children.Add(acceptButton);
        buttons.Children.Add(cancelButton);
        panel.Children.Add(buttons);
        panel.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; cancel(); }
        };
        panel.Loaded += (_, _) => acceptButton.Focus(FocusState.Programmatic);
        return panel;
    }

    /// <summary>Choose displays for monitor numbers (macOS DocumentMonitorMappingView and InvocationMonitorMappingView).</summary>
    /// <summary>Catalog keys and automation prefix of a mapping page other than a file's or the command line's (imports).</summary>
    public sealed record MappingTexts(string Title, string Description, string Primary, string Shared, string Prefix);

    public static FrameworkElement Mapping(NativeMonitorMappingRequest request, NativeText? issue, string endpoint,
                                           Action<IReadOnlyDictionary<int, string>> resolve, Action cancel, MappingTexts? texts = null)
    {
        var commandLine = request.Layer == NativeOptionSource.CommandLine;
        var prefix = texts?.Prefix ?? (commandLine ? "invocation" : "document");
        var panel = new StackPanel { Spacing = 16, Tag = "mapping:" + request.Id + ":" + issue?.Key };
        panel.Children.Add(Ui.Title(Strings.Get(texts?.Title ?? (commandLine ? "document.choose.displays.for.command.line.options" : "document.choose.displays.for.this.file")),
            prefix + ".mapping.title"));
        panel.Children.Add(Ui.Text(Strings.Get(texts?.Description ?? (commandLine
            ? "document.choose.which.connected.display.each.command.line.monitor.number.should.use.for"
            : "document.monitor.numbers.belong.to.the.computer.that.saved.the.file.choose.which"))));
        var assignments = new Dictionary<int, string>(request.Suggested);
        var displays = App.Current.Displays;
        var primary = Ui.Button(Strings.Get(texts?.Primary ?? (commandLine
            ? endpoint.Length == 0 ? "profiles.open.connection" : "document.connect"
            : "document.review.connection")), (_, _) => resolve(assignments), prefix + ".mapping.review", accent: true);
        void Validate() => primary.IsEnabled = request.Numbers.Count != 0 && displays.Snapshot.Error is null &&
                                               request.Numbers.All(n => assignments.TryGetValue(n, out var id) && displays.Snapshot.Find(id) is not null);
        var pickers = new StackPanel { Spacing = 12 };
        void Build()
        {
            pickers.Children.Clear();
            foreach (var number in request.Numbers)
            {
                var label = Strings.Format(commandLine ? "document.monitor.commandline.label" : "document.monitor.file.label", number);
                var box = new ComboBox { Header = label, MinWidth = 280, PlaceholderText = Strings.Get("document.choose.a.display") };
                AutomationProperties.SetAutomationId(box, $"{prefix}.mapping.monitor.{number}");
                AutomationProperties.SetName(box, label);
                var ids = displays.Snapshot.Displays.Select(d => d.Id).ToList();
                foreach (var display in displays.Snapshot.Displays) box.Items.Add(display.Name);
                if (assignments.TryGetValue(number, out var chosen) && !ids.Contains(chosen))
                {
                    ids.Add(chosen);
                    box.Items.Add(Strings.Get("document.disconnected.display"));
                }
                if (assignments.TryGetValue(number, out var current)) box.SelectedIndex = ids.IndexOf(current);
                box.SelectionChanged += (_, _) =>
                {
                    if (box.SelectedIndex >= 0) assignments[number] = ids[box.SelectedIndex];
                    Validate();
                };
                pickers.Children.Add(box);
            }
            Validate();
        }
        Build();
        panel.Children.Add(pickers);
        panel.Children.Add(Ui.Caption(Strings.Get(texts?.Shared ?? "document.several.monitor.numbers.may.use.the.same.display.that.display.will.be")));
        if (issue is not null)
        {
            var text = Ui.Text(issue);
            Ui.SetTone(text, Tone.Error);
            panel.Children.Add(text);
        }
        else if (displays.Snapshot.Error is not null || displays.Snapshot.Displays.IsEmpty)
        {
            var text = Ui.Text(Strings.Get("document.display.information.is.unavailable.connect.a.display.and.refresh.before.continuing"));
            Ui.SetTone(text, Tone.Warning);
            panel.Children.Add(text);
        }
        panel.Children.Add(Ui.Button(Strings.Get("document.refresh.displays"), (_, _) => { displays.Refresh(); Build(); }, prefix + ".mapping.refresh"));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttons.Children.Add(primary);
        buttons.Children.Add(Ui.Button(Strings.Get("action.cancel"), (_, _) => cancel(), prefix + ".mapping.cancel"));
        panel.Children.Add(buttons);
        PropertyChangedEventHandler changed = (_, _) => Build();
        panel.Loaded += (_, _) => { displays.PropertyChanged += changed; displays.Refresh(); };
        panel.Unloaded += (_, _) => displays.PropertyChanged -= changed;
        panel.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; cancel(); }
        };
        return panel;
    }
}

/// <summary>The recent connections flyout (macOS RecentConnectionsPanel; PARITY C02).</summary>
public sealed partial class RecentConnectionsPanel : UserControl
{
    private readonly StackPanel rows = new() { Spacing = 4 };
    private readonly TextBlock empty = Ui.Caption("");
    private readonly TextBlock error = Ui.Text("");
    private readonly StackPanel busy = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly Button reload, clear;
    private NativeRecentHistory? history;
    private bool canSelect = true;

    internal event Action<NativeConnectionDestination>? Selected;

    public RecentConnectionsPanel()
    {
        Ui.SetTone(error, Tone.Error);
        busy.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        busy.Children.Add(Ui.Caption(Strings.Get("history.updating.recent.connections")));
        reload = Ui.Button(Strings.Get("trust.library.ui.reload"), (_, _) => history?.Reload(), "history.reload");
        clear = Ui.Button(Strings.Get("history.clear.recent.connections"), (_, _) => history?.Clear(), "history.clear");
        var scroll = new ScrollViewer { Content = rows, MaxHeight = 260, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(reload);
        actions.Children.Add(clear);
        Content = Ui.Stack(12, Ui.Heading(Strings.Get("history.recent.connections.title")),
            Ui.Caption(Strings.Get("history.choose.an.address.then.select.connect")), empty, scroll, error, busy, actions);
        Width = 440;
        AutomationProperties.SetAutomationId(this, "history.panel");
    }

    internal NativeRecentHistory? History
    {
        get => history;
        set
        {
            if (history is not null) history.PropertyChanged -= Changed;
            history = value;
            if (history is not null) history.PropertyChanged += Changed;
            Refresh();
        }
    }

    internal bool CanSelect
    {
        get => canSelect;
        set { if (canSelect != value) { canSelect = value; Refresh(); } }
    }

    private void Changed(object? sender, PropertyChangedEventArgs e) => Refresh();

    private void Refresh()
    {
        rows.Children.Clear();
        var connections = history?.Connections ?? ImmutableArray<NativeConnectionDestination>.Empty;
        empty.Text = Strings.Get(history?.HasLoaded == true ? "history.no.recent.connections" : "history.recent.connections.have.not.loaded");
        empty.Visibility = connections.IsEmpty ? Visibility.Visible : Visibility.Collapsed;
        foreach (var destination in connections)
        {
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var text = new StackPanel { Spacing = 2 };
            text.Children.Add(new TextBlock { Text = destination.Endpoint, TextTrimming = TextTrimming.CharacterEllipsis });
            if (destination.SshGateway is { } gateway)
                text.Children.Add(Ui.Caption(Strings.Format("history.gateway", gateway.CanonicalUri)));
            var select = new Button { Content = text, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, IsEnabled = canSelect };
            var description = destination.SshGateway is { } via ? Strings.Format("history.destination.gateway", destination.Endpoint, via.CanonicalUri) : destination.Endpoint;
            ToolTipService.SetToolTip(select, description);
            AutomationProperties.SetName(select, description);
            AutomationProperties.SetHelpText(select, Strings.Get("history.places.this.address.and.its.gateway.in.the.connection.fields"));
            select.Click += (_, _) => Selected?.Invoke(destination);
            var remove = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, IsEnabled = history?.CanEdit == true };
            ToolTipService.SetToolTip(remove, Strings.Get("history.remove.from.recent.connections"));
            AutomationProperties.SetName(remove, Strings.Format("history.remove.destination", destination.Endpoint));
            remove.Click += (_, _) => history?.Remove(destination);
            Grid.SetColumn(remove, 1);
            row.Children.Add(select);
            row.Children.Add(remove);
            rows.Children.Add(row);
        }
        error.Text = history?.Error is { } failure ? Strings.Resolve(NativeTexts.History(failure)) : "";
        error.Visibility = error.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        busy.Visibility = history?.IsBusy == true ? Visibility.Visible : Visibility.Collapsed;
        reload.IsEnabled = history is { IsBusy: false };
        clear.IsEnabled = history?.CanEdit == true && !connections.IsEmpty;
    }
}

/// <summary>
/// The Connection menu (macOS DesktopActions): the same items in the menu
/// bar, the toolbar's More button and, later, the fullscreen bar and the
/// desktop context menu (UX.md section 6). Commands that later items add
/// (full screen, panning, held keys, settings dialogs) join here.
/// </summary>
internal static class ConnectionMenu
{
    /// <summary>
    /// Everything the menu shows, so a menu that stays in the menu bar is
    /// rebuilt only when it would change (rebuilding closes open menus).
    /// </summary>
    public static string State(ConnectionWindow window)
    {
        var controller = window.Controller;
        var connected = controller.Session?.Snapshot.State == NativeSessionState.Connected;
        bool[] flags =
        [
            !controller.Closing && !controller.Busy && connected, window.IsFullscreen, window.CanToggleFullscreen, window.CanMinimize,
            window.CanFitWindow, window.CanResizeRemote, connected, window.CanPan(NativeDesktopPan.Left), window.CanPan(NativeDesktopPan.Right),
            window.CanPan(NativeDesktopPan.Up), window.CanPan(NativeDesktopPan.Down), window.CanPan(NativeDesktopPan.Origin),
            window.Commands.ControlSelected, window.Commands.AltSelected, window.Commands.CanSendKeys, window.KeyboardCaptured,
            window.CanCaptureKeyboard, !controller.Closing && connected, window.CanOpenFullscreenSettings, window.CanOpenConnectedEditor,
            window.CanOpenAnyEditor, window.CanOpenDisconnectedEditor, controller.ShowsStatistics, controller.CanToggleStatistics,
            window.CanOpenInformation,
        ];
        return string.Concat(flags.Select(f => f ? '1' : '0'));
    }

    public static void Fill(IList<MenuFlyoutItemBase> items, ConnectionWindow window)
    {
        var controller = window.Controller;
        var connected = controller.Session?.Snapshot.State == NativeSessionState.Connected;
        items.Clear();
        items.Add(Item("app.disconnect", "desktop.disconnect", !controller.Closing && !controller.Busy && connected, controller.Disconnect));
        items.Add(new MenuFlyoutSeparator());
        var fullscreen = Item(window.IsFullscreen ? "desktop.exit.full.screen" : "desktop.enter.full.screen", "desktop.fullscreen",
            window.CanToggleFullscreen, window.ToggleFullscreen);
        fullscreen.KeyboardAcceleratorTextOverride = "F11";
        items.Add(fullscreen);
        items.Add(Item("desktop.minimize", "desktop.minimize", window.CanMinimize, window.MinimizeWindow));
        items.Add(Item("desktop.resize.window.to.desktop", "desktop.fitWindow", window.CanFitWindow, window.FitWindow));
        items.Add(Item("desktop.resize.remote.desktop", "desktop.resizeRemote", window.CanResizeRemote, window.OpenRemoteResize));
        var pan = new MenuFlyoutSubItem { Text = Strings.Get("desktop.pan.desktop"), IsEnabled = connected };
        AutomationProperties.SetAutomationId(pan, "desktop.pan");
        foreach (var (direction, key, id) in new[]
                 {
                     (NativeDesktopPan.Left, "desktop.pan.left", "desktop.pan.left"), (NativeDesktopPan.Right, "desktop.pan.right", "desktop.pan.right"),
                     (NativeDesktopPan.Up, "desktop.pan.up", "desktop.pan.up"), (NativeDesktopPan.Down, "desktop.pan.down", "desktop.pan.down"),
                     (NativeDesktopPan.Origin, "desktop.return.to.top.left", "desktop.pan.origin"),
                 })
        {
            if (direction == NativeDesktopPan.Origin) pan.Items.Add(new MenuFlyoutSeparator());
            var target = direction;
            pan.Items.Add(Item(key, id, window.CanPan(target), () => window.PanDesktop(target)));
        }
        items.Add(pan);
        items.Add(new MenuFlyoutSeparator());
        items.Add(Toggle("desktop.hold.control", "desktop.holdControl", window.Commands.ControlSelected, window.Commands.CanSendKeys, window.HoldControl));
        items.Add(Toggle("desktop.hold.alt", "desktop.holdAlt", window.Commands.AltSelected, window.Commands.CanSendKeys, window.HoldAlt));
        items.Add(window.KeyboardCaptured
            ? Item("desktop.release.keyboard", "desktop.releaseKeyboard", true, window.ReleaseKeyboard)
            : Item("desktop.capture.keyboard", "desktop.captureKeyboard", window.CanCaptureKeyboard, window.CaptureKeyboard));
        items.Add(Item("desktop.send.ctrl.alt.delete", "desktop.controlAltDelete", window.Commands.CanSendKeys, window.SendControlAltDelete));
        items.Add(new MenuFlyoutSeparator());
        items.Add(Item("desktop.refresh.desktop", "desktop.refresh", !controller.Closing && connected, controller.Refresh));
        var settings = new MenuFlyoutSubItem { Text = Strings.Get("desktop.connection.settings") };
        AutomationProperties.SetAutomationId(settings, "desktop.connectionSettings");
        settings.Items.Add(Item("desktop.fullscreen.displays", "desktop.fullscreenDisplays", window.CanOpenFullscreenSettings, window.OpenFullscreenSettings));
        settings.Items.Add(Item("desktop.input", "desktop.input", window.CanOpenConnectedEditor, window.OpenInput));
        settings.Items.Add(Item("desktop.remote.resize.settings", "desktop.remoteResizeSettings", window.CanOpenAnyEditor, window.OpenResizePolicy));
        settings.Items.Add(Item("desktop.scaling", "desktop.scaling", window.CanOpenConnectedEditor, window.OpenScaling));
        settings.Items.Add(Item("desktop.connection", "desktop.connectionOptions", window.CanOpenDisconnectedEditor, window.OpenConnectionOptions));
        settings.Items.Add(Item("desktop.security", "desktop.security", window.CanOpenDisconnectedEditor, window.OpenSecurity));
        settings.Items.Add(Item("desktop.encoding", "desktop.encoding", window.CanOpenConnectedEditor, window.OpenEncoding));
        items.Add(settings);
        items.Add(Item("desktop.connection.information", "desktop.information", window.CanOpenInformation, window.OpenInformation));
        items.Add(Toggle("desktop.show.connection.statistics", "desktop.statistics", controller.ShowsStatistics, controller.CanToggleStatistics,
            controller.ToggleStatistics));
    }

    private static ToggleMenuFlyoutItem Toggle(string key, string id, bool on, bool enabled, Action action)
    {
        var item = new ToggleMenuFlyoutItem { Text = Strings.Get(key), IsChecked = on, IsEnabled = enabled };
        AutomationProperties.SetAutomationId(item, id);
        item.Click += (_, _) => action();
        return item;
    }

    private static MenuFlyoutItem Item(string key, string id, bool enabled, Action action)
    {
        var item = new MenuFlyoutItem { Text = Strings.Get(key), IsEnabled = enabled };
        AutomationProperties.SetAutomationId(item, id);
        item.Click += (_, _) => action();
        return item;
    }
}
