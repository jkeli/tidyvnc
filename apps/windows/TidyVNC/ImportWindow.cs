// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TidyVNC.Native;
using TidyVNC.Native.Storage;

namespace TidyVNC;

/// <summary>
/// Import connection defaults or recent connections from the FLTK viewer's
/// registry (macOS DefaultsImportView and HistoryImportView; PARITY F09-F14):
/// choose *Current TidyVNC settings* or *TigerVNC settings*, review exactly
/// what will be copied, acknowledge omissions, then import. The registry is
/// never written.
/// </summary>
internal sealed partial class ImportWindow : Window
{
    private readonly NativeDefaultsImport? defaults;
    private readonly NativeHistoryImport? history;
    private readonly ContentControl body = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly TextBlock issue = Ui.Text("", "import.issue");
    private readonly StackPanel busy = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly Grid buttons = new() { ColumnSpacing = 8 };
    private bool acknowledged;

    private ImportWindow(string titleKey)
    {
        Title = Strings.Get(titleKey);
        SystemBackdrop = new MicaBackdrop();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "tidyvnc.ico"));
        WindowSizes.Apply(AppWindow, 640, 600, 480, 400);
        issue.Foreground = Ui.Error;
        busy.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        busy.Children.Add(Ui.Caption(""));
        var title = Ui.Title(Strings.Get(titleKey), "import.title");
        var root = new Grid { Padding = new Thickness(24), RowSpacing = 12 };
        foreach (var height in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto, GridLength.Auto })
            root.RowDefinitions.Add(new RowDefinition { Height = height });
        var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        Grid.SetRow(scroll, 1); Grid.SetRow(issue, 2); Grid.SetRow(busy, 3); Grid.SetRow(buttons, 4);
        foreach (var child in new UIElement[] { title, scroll, issue, busy, buttons }) root.Children.Add(child);
        Content = root;
        Strings.Localize(this);
    }

    /// <summary>Import connection defaults (F09-F12).</summary>
    public ImportWindow(NativeDefaultsImport model) : this("import.defaults.import.connection.defaults")
    {
        defaults = model;
        model.PropertyChanged += (_, _) => Refresh();
        Closed += (_, _) => _ = model.CloseAsync();
        Refresh();
    }

    /// <summary>Import recent connections (F13-F14).</summary>
    public ImportWindow(NativeHistoryImport model) : this("history.import.import.recent.connections")
    {
        history = model;
        model.PropertyChanged += (_, _) => Refresh();
        Closed += (_, _) => _ = model.CloseAsync();
        Refresh();
    }

    private static string SourceName(NativeRegistrySource source) =>
        Strings.Get(source == NativeRegistrySource.TidyVnc ? "import.source.tidyvnc" : "import.source.tigervnc");

    private void SetButtons(params (string Key, string Id, bool Accent, bool Enabled, Action Action)[] actions)
    {
        buttons.Children.Clear();
        buttons.ColumnDefinitions.Clear();
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        for (var i = 0; i < actions.Length; i++)
        {
            buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var (key, id, accent, enabled, action) = actions[i];
            var button = Ui.Button(Strings.Get(key), (_, _) => action(), id, accent);
            button.IsEnabled = enabled;
            Grid.SetColumn(button, i + 1);
            buttons.Children.Add(button);
        }
    }

    /// <summary>The source choice (F10): only sources that have something to import are offered.</summary>
    private static StackPanel Sources(IReadOnlyList<NativeRegistryImportSource> sources, string introKey, string noneKey, Action<NativeRegistrySource> begin)
    {
        var panel = Ui.Stack(12, Ui.Caption(Strings.Get(introKey)), Ui.Caption(Strings.Get("import.registry.source")));
        if (sources.Count == 0) panel.Children.Add(Ui.Text(Strings.Get(noneKey)));
        foreach (var source in sources)
        {
            var value = source.Source;
            var button = Ui.Button(SourceName(value), (_, _) => begin(value), "import.source." + value.ToString().ToLowerInvariant());
            panel.Children.Add(button);
        }
        return panel;
    }

    private void Refresh()
    {
        if (defaults is not null) RefreshDefaults(defaults);
        else if (history is not null) RefreshHistory(history);
    }

    private void Status(bool isBusy, string key, NativeImportIssue? problem)
    {
        busy.Visibility = isBusy ? Visibility.Visible : Visibility.Collapsed;
        ((TextBlock)busy.Children[1]).Text = Strings.Get(key);
        issue.Text = problem switch
        {
            NativeImportIssue.SourceUnreadable => Strings.Get("import.registry.unreadable"),
            NativeImportIssue.Changed when history is not null => Strings.Get("history.import.native.history.takes.precedence.including.history.you.previously.cleared.existing.saved.profiles"),
            NativeImportIssue.Changed => Strings.Get("import.defaults.native.settings.changed.existing.settings.cannot.be.replaced.by.an.import"),
            NativeImportIssue.Unavailable => Strings.Get("import.defaults.native.settings.could.not.be.loaded.resolve.the.stored.settings.problem.before"),
            NativeImportIssue.AcknowledgementRequired => Strings.Get("import.defaults.review.all.omitted.or.converted.settings.before.importing"),
            NativeImportIssue.Failed => Strings.Get("import.defaults.settings.could.not.be.imported.reload.native.settings.and.review.the.source"),
            _ => "",
        };
        issue.Visibility = issue.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private static string Category(string name) => Strings.Get(name switch
    {
        "SendClipboard" or "AcceptClipboard" => "import.defaults.clipboard.sharing",
        "AutoSelect" or "FullColor" or "LowColorLevel" or "PreferredEncoding" or "CustomCompressLevel" or "CompressLevel" or "NoJPEG" or "QualityLevel"
            => "import.defaults.encoding.and.image.quality",
        "ViewOnly" or "EmulateMiddleButton" or "FullscreenSystemKeys" or "ShortcutModifiers" or "AlwaysCursor" or "CursorType"
            => "import.defaults.keyboard.pointer.and.cursor",
        "ScalingFactor" or "ScalingQuality" or "DesktopPixelUnits" => "import.defaults.desktop.scaling",
        "FullScreen" or "FullScreenMode" => "import.defaults.fullscreen.displays",
        _ => "import.defaults.connection.behavior",
    });

    private static string Notice(NativeImportNotice notice) => Strings.Format("import.registry.notice", notice.Name, Strings.Get(notice.Kind switch
    {
        NativeImportNoticeKind.Unknown => "import.defaults.unknown.setting.not.imported",
        NativeImportNoticeKind.PlatformOnly => "import.defaults.unavailable.on.macos.not.imported",
        _ => "import.defaults.not.imported",
    }));

    private void RefreshDefaults(NativeDefaultsImport model)
    {
        Status(model.IsBusy, model.Review is null ? "import.defaults.reading.defaults" : "import.defaults.saving.imported.defaults", model.Issue);
        if (model.Imported)
        {
            body.Content = Ui.Stack(8, Ui.Heading(Strings.Get("import.defaults.defaults.imported")),
                Ui.Caption(Strings.Get("import.defaults.open.a.new.connection.window.to.use.these.defaults.existing.windows.keep")),
                Ui.Caption(Strings.Get("import.registry.left.unchanged")));
            SetButtons(("import.defaults.new.connection", "import.newConnection", true, true, () => { App.Current.OpenWindow(); Close(); }),
                       ("action.done", "import.done", false, true, Close));
            return;
        }
        if (model.Review is not { } review)
        {
            body.Content = Sources(model.Sources, "import.defaults.bring.ordinary.connection.settings.into.this.native.app.saved.native.defaults.take",
                "import.registry.none", source => { acknowledged = false; model.Begin(source); });
            SetButtons(("action.cancel", "import.cancel", false, !model.IsBusy, Close));
            return;
        }
        var panel = Ui.Stack(12, Ui.Caption(Strings.Format("import.registry.reviewing", SourceName(review.Source))));
        if (review.ReplacesExisting) panel.Children.Add(Ui.Caption(Strings.Get("import.registry.replaces"), Ui.Warning));
        panel.Children.Add(Ui.Heading(Strings.Get("import.defaults.settings.to.import")));
        if (review.Imported.Count == 0 && review.Settings.FullscreenDisplays.IsEmpty)
            panel.Children.Add(Ui.Caption(Strings.Get("import.defaults.this.file.contains.no.supported.ordinary.settings.to.import")));
        foreach (var group in review.Imported.GroupBy(a => Category(a.Name)))
        {
            panel.Children.Add(Ui.Text(group.Key));
            foreach (var assignment in group) panel.Children.Add(Ui.Caption($"{assignment.Name} = {assignment.Value}"));
        }
        if (review.NeedsAcknowledgement)
        {
            panel.Children.Add(Ui.Heading(Strings.Get("import.defaults.omissions.and.conversions")));
            foreach (var notice in review.Notices) panel.Children.Add(Ui.Caption(Notice(notice)));
            foreach (var skipped in review.Skipped) panel.Children.Add(Ui.Caption(Strings.Format("import.registry.skipped", skipped)));
            foreach (var monitor in review.Monitors)
                panel.Children.Add(Ui.Caption(monitor.Display is { } display
                    ? Strings.Format("import.registry.monitor", monitor.Number.ToString(CultureInfo.CurrentCulture),
                        App.Current.Displays.Snapshot.Find(display)?.Name ?? Strings.Get("document.unavailable.display"))
                    : Strings.Format("import.registry.monitor.missing", monitor.Number.ToString(CultureInfo.CurrentCulture))));
            var check = new CheckBox { Content = Strings.Get("import.defaults.i.reviewed.the.omissions.and.conversions"), IsChecked = acknowledged };
            AutomationProperties.SetAutomationId(check, "import.acknowledge");
            check.Click += (_, _) => { acknowledged = check.IsChecked == true; Refresh(); };
            panel.Children.Add(check);
        }
        panel.Children.Add(Ui.Caption(Strings.Get("import.defaults.passwords.server.addresses.security.settings.certificate.files.trust.decisions.and.tunnel.commands")));
        body.Content = panel;
        var id = review.Id;
        SetButtons(("action.cancel", "import.cancel", false, !model.IsBusy, model.Cancel),
                   ("import.defaults.import.defaults", "import.approve", true, !model.IsBusy && (acknowledged || !review.NeedsAcknowledgement),
                    () => model.Approve(id, acknowledged)));
    }

    private void RefreshHistory(NativeHistoryImport model)
    {
        Status(model.IsBusy, model.Review is null ? "history.import.reading.history" : "history.import.saving.imported.history", model.Issue);
        if (model.Finished)
        {
            body.Content = Ui.Stack(8, Ui.Heading(Strings.Get("history.import.history.imported")), Ui.Caption(Strings.Get("import.registry.left.unchanged")));
            SetButtons(("action.done", "import.done", true, true, Close));
            return;
        }
        if (model.Review is not { } review)
        {
            body.Content = Sources(model.Sources, "history.import.copy.recent.server.addresses.into.this.app.this.is.separate.from.importing",
                "import.registry.none", source => { acknowledged = false; model.Begin(source); });
            SetButtons(("action.cancel", "import.cancel", false, !model.IsBusy, Close));
            return;
        }
        var panel = Ui.Stack(8, Ui.Caption(Strings.Format("import.registry.reviewing", SourceName(review.Source))),
            Ui.Heading(Strings.Format("history.import.address.count", review.Endpoints.Count.ToString(CultureInfo.CurrentCulture))));
        if (review.Endpoints.Count == 0) panel.Children.Add(Ui.Caption(Strings.Get("history.import.this.file.contains.no.server.addresses.to.import")));
        for (var i = 0; i < review.Endpoints.Count; i++)
            panel.Children.Add(Ui.Text(Strings.Format("history.import.address.row", (i + 1).ToString(CultureInfo.CurrentCulture), review.Endpoints[i])));
        var omitted = review.Duplicates != 0 || review.OmittedOlder != 0;
        if (omitted)
        {
            panel.Children.Add(Ui.Caption(Strings.Format("history.import.omitted.counts", review.Duplicates.ToString(CultureInfo.CurrentCulture),
                review.OmittedOlder.ToString(CultureInfo.CurrentCulture))));
            var check = new CheckBox { Content = Strings.Get("history.import.i.reviewed.the.omitted.entries"), IsChecked = acknowledged };
            AutomationProperties.SetAutomationId(check, "import.acknowledge");
            check.Click += (_, _) => { acknowledged = check.IsChecked == true; Refresh(); };
            panel.Children.Add(check);
        }
        panel.Children.Add(Ui.Caption(Strings.Get("history.import.import.preserves.the.listed.order.and.address.spelling.no.connection.will.be")));
        body.Content = panel;
        var id = review.Id;
        SetButtons(("action.cancel", "import.cancel", false, !model.IsBusy, model.Cancel),
                   ("history.import.not.now", "import.skip", false, !model.IsBusy, () => model.Complete(id, import: false)),
                   ("history.import.import.history", "import.approve", true, !model.IsBusy && (acknowledged || !omitted), () => model.Complete(id, import: true)));
    }
}
