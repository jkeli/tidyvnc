// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TidyVNC.Native;
using TidyVNC.Native.Desktop;
using TidyVNC.Native.Storage;
using TidyVNC.Native.Trust;

namespace TidyVNC;

/// <summary>
/// Settings: the connection defaults (UX.md section 8; macOS
/// PreferencesSettingsView; PARITY P01-P05, P09). A navigation pane lists
/// the macOS sections in the macOS order; each field is a settings card with
/// its effective value and source. Nothing is saved until Apply, which
/// commits against the revision that was read. Existing connections keep
/// their own settings.
/// </summary>
internal sealed partial class SettingsWindow : Window
{
    private readonly NativePreferencesDraft draft;
    private readonly NavigationView navigation = new()
    {
        PaneDisplayMode = NavigationViewPaneDisplayMode.Left, IsSettingsVisible = false, IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
        IsPaneToggleButtonVisible = false, OpenPaneLength = 220,
    };
    private readonly ScrollViewer page = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
    private readonly TextBlock error = Ui.Text("", "preferences.error");
    private readonly StackPanel busy = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly Button restore, cancel, apply, reload;
    private readonly SettingsSections sections;
    private string section = "clipboard";

    public SettingsWindow(NativePreferencesDraft draft, string? initialSection = null)
    {
        this.draft = draft;
        sections = new SettingsSections(draft, () => this);
        sections.Navigate += Select;
        Title = Strings.Get("app.menu.settings");
        SystemBackdrop = new MicaBackdrop();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "tidyvnc.ico"));
        WindowSizes.Apply(AppWindow, 860, 640, 560, 420);

        foreach (var (tag, key) in SettingsSections.All)
        {
            var item = new NavigationViewItem { Content = Strings.Get(key), Tag = tag };
            AutomationProperties.SetAutomationId(item, "preferences.section." + tag);
            if (tag == "security")
            {
                var files = new NavigationViewItem { Content = Strings.Get("settings.section.certificateFiles"), Tag = "trust" };
                AutomationProperties.SetAutomationId(files, "preferences.section.trust");
                item.MenuItems.Add(files);
                item.IsExpanded = true;
            }
            navigation.MenuItems.Add(item);
        }
        navigation.SelectionChanged += (_, e) =>
        {
            if (e.SelectedItem is NavigationViewItem { Tag: string tag }) Show(tag);
        };
        AutomationProperties.SetAutomationId(navigation, "preferences.section");

        error.Foreground = Ui.Error;
        busy.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        busy.Children.Add(Ui.Caption(Strings.Get("settings.defaults.updating.defaults")));
        restore = Ui.Button(Strings.Get("settings.defaults.restore.built.in.defaults"), (_, _) => draft.RestoreBuiltInDefaults(), "preferences.restore");
        cancel = Ui.Button(Strings.Get("settings.defaults.cancel.edits"), (_, _) => draft.Cancel(), "preferences.cancel");
        apply = Ui.Button(Strings.Get("action.apply"), (_, _) => draft.Apply(), "preferences.apply", accent: true);
        reload = Ui.Button("", (_, _) => draft.Reload(), "preferences.reload");
        cancel.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = Windows.System.VirtualKey.Escape });

        var buttons = new Grid { ColumnSpacing = 8 };
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(reload, 1); reload.HorizontalAlignment = HorizontalAlignment.Left;
        Grid.SetColumn(cancel, 3); Grid.SetColumn(apply, 4);
        buttons.Children.Add(restore); buttons.Children.Add(reload); buttons.Children.Add(cancel); buttons.Children.Add(apply);
        var footer = Ui.Stack(8, error, busy, buttons);
        footer.Padding = new Thickness(24, 12, 24, 16);

        var header = Ui.Stack(4, Ui.Title(Strings.Get("settings.defaults.connection.defaults"), "preferences.title"),
            Ui.Caption(Strings.Get("settings.defaults.these.defaults.apply.to.new.connection.windows.existing.connections.keep.their.own")));
        header.Padding = new Thickness(24, 16, 24, 8);
        page.Padding = new Thickness(24, 0, 24, 8);
        var body = new Grid();
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        body.RowDefinitions.Add(new RowDefinition());
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(page, 1); Grid.SetRow(footer, 2);
        body.Children.Add(header); body.Children.Add(page); body.Children.Add(footer);
        navigation.Content = body;
        Content = navigation;
        Strings.Localize(this);

        draft.PropertyChanged += (_, _) => Refresh();
        Activated += (_, e) =>
        {
            // Returning to the window picks up another process's save unless there are edits.
            if (e.WindowActivationState != WindowActivationState.Deactivated && !draft.IsBusy && !draft.HasChanges) draft.Reload();
        };
        Closed += (_, _) => draft.Stop();
        var start = initialSection ?? "clipboard";
        navigation.SelectedItem = navigation.MenuItems.OfType<NavigationViewItem>()
            .SelectMany(i => i.MenuItems.OfType<NavigationViewItem>().Prepend(i)).First(i => (string)i.Tag == start);
        Show(start);
    }

    /// <summary>The Settings text for a store or edit problem (macOS preferencesMessage).</summary>
    private static string Message(NativeStorageError? failure, NativePreferencesProblem? problem) => problem switch
    {
        NativePreferencesProblem.InvalidPriority => Strings.Get("settings.defaults.the.tls.priority.expression.is.invalid.correct.it.or.use.the.library"),
        NativePreferencesProblem.InvalidValue => Strings.Get("settings.defaults.a.setting.is.outside.the.supported.range.saved.values.have.been.preserved"),
        _ => failure switch
        {
            null => "",
            NativeStorageError.FutureSchema or NativeStorageError.UnsupportedFields =>
                Strings.Get("settings.defaults.these.saved.defaults.require.a.newer.version.of.tidyvnc.they.have.been"),
            NativeStorageError.Corrupt or NativeStorageError.TooLarge => Strings.Get("settings.defaults.saved.defaults.could.not.be.read.they.have.been.preserved"),
            NativeStorageError.Conflict => Strings.Get("settings.defaults.saved.defaults.changed.while.you.were.editing.reload.them.before.applying.changes"),
            NativeStorageError.Denied => Strings.Get("settings.defaults.access.to.saved.defaults.was.denied.check.access.and.try.again"),
            NativeStorageError.Cancelled => Strings.Get("settings.defaults.the.defaults.operation.was.cancelled.reload.to.check.the.saved.values"),
            NativeStorageError.IOFailure => Strings.Get("settings.defaults.the.defaults.operation.could.not.be.confirmed.reload.to.check.the.saved"),
            _ => Strings.Get("settings.defaults.saved.defaults.are.unavailable.try.again"),
        },
    };

    private void Refresh()
    {
        sections.Refresh();
        error.Text = Message(draft.Error, draft.Problem);
        error.Visibility = error.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        busy.Visibility = draft.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        page.IsEnabled = draft.CanEdit;
        restore.IsEnabled = draft.CanEdit;
        cancel.IsEnabled = !draft.IsBusy && draft.HasChanges;
        apply.IsEnabled = draft.CanApply;
        reload.Content = Strings.Get(draft.HasChanges ? "action.discard.edits.reload" : "settings.defaults.reload.saved.defaults");
        reload.Visibility = draft.NeedsReload || (draft.Snapshot is null && !draft.IsBusy) ? Visibility.Visible : Visibility.Collapsed;
        reload.IsEnabled = !draft.IsBusy;
    }

    private void Show(string tag)
    {
        section = tag;
        page.Content = sections.Build(tag);
        Refresh();
    }

    private void Select(string tag)
    {
        navigation.SelectedItem = navigation.MenuItems.OfType<NavigationViewItem>()
            .SelectMany(i => i.MenuItems.OfType<NavigationViewItem>().Prepend(i)).First(i => (string)i.Tag == tag);
    }

    /// <summary>Shows a section when the window is already open.</summary>
    public void ShowSection(string tag)
    {
        if (tag != section) Select(tag);
        Activate();
    }
}
