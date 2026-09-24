// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TidyVNC.Native;
using TidyVNC.Native.Desktop;

namespace TidyVNC;

/// <summary>Labels shared by the per-connection Input and Scaling dialogs.</summary>
internal static class SettingsLabels
{
    /// <summary>Where a connection's current value came from (macOS input/scaling sheets).</summary>
    public static string ConnectionSource(NativeOptionSource source) => Strings.Get(source switch
    {
        NativeOptionSource.AppDefaults => "settings.encoding.app.default",
        NativeOptionSource.Profile => "settings.input.saved.profile.override",
        NativeOptionSource.Session => "settings.input.this.connection.override",
        NativeOptionSource.Document => "settings.encoding.connection.file",
        NativeOptionSource.CommandLine => "settings.input.command.line.override",
        _ => "settings.defaults.built.in.default",
    });

    /// <summary>Where a window's resize or full-screen setting came from (macOS resizeSourceLabel, fullscreenSourceLabel).</summary>
    public static string ShortSource(NativeOptionSource source) => Strings.Get(source switch
    {
        NativeOptionSource.AppDefaults => "settings.encoding.app.default",
        NativeOptionSource.Profile => "settings.encoding.profile",
        NativeOptionSource.Session => "settings.encoding.connection.override",
        NativeOptionSource.Document => "settings.encoding.connection.file",
        NativeOptionSource.CommandLine => "settings.encoding.command.line",
        _ => "settings.defaults.built.in.default",
    });

    public static string Cursor(NativeCursorFallback value) => Strings.Get(value switch
    {
        NativeCursorFallback.Hidden => "settings.input.hidden",
        NativeCursorFallback.Dot => "settings.input.dot",
        _ => "settings.input.system.pointer",
    });

    public static string Mode(NativeScalingMode mode) => Strings.Get(mode switch
    {
        NativeScalingMode.Unscaled => "settings.scaling.no.scaling.100",
        NativeScalingMode.Automatic => "settings.scaling.fit.window.stretch",
        NativeScalingMode.FixedRatio => "settings.scaling.fit.window.keep.proportions",
        NativeScalingMode.FitWidth => "settings.scaling.fit.width",
        NativeScalingMode.FitHeight => "settings.scaling.fit.height",
        NativeScalingMode.Exact => "settings.scaling.exact.dimensions",
        NativeScalingMode.Percent => "settings.scaling.percentage",
        _ => "settings.scaling.independent.percentages",
    });

    public static string Filter(NativeScalingFilter filter) => Strings.Get(filter switch
    {
        NativeScalingFilter.Nearest => "settings.scaling.nearest.neighbor",
        NativeScalingFilter.Area => "settings.scaling.area.averaging",
        _ => "settings.scaling.bilinear",
    });

    public static string FilterHelp(NativeScalingFilter filter) => Strings.Get(filter switch
    {
        NativeScalingFilter.Nearest => "settings.scaling.keeps.pixel.edges.sharp.enlarged.pixels.may.look.blocky",
        NativeScalingFilter.Area => "settings.scaling.averages.pixels.when.shrinking.the.desktop.uses.more.processing.time",
        _ => "settings.scaling.blends.nearby.pixels.for.smooth.scaling.fine.details.may.soften",
    });

    /// <summary>Modifier names for Windows (Ctrl, Shift, Alt, Windows key; UX.md section 7).</summary>
    public static string Modifiers(NativeShortcutModifiers value) => value == NativeShortcutModifiers.None
        ? Strings.Get("settings.input.shortcuts.off")
        : string.Join(" + ", new[]
            {
                (NativeShortcutModifiers.Control, "settings.input.control"), (NativeShortcutModifiers.Shift, "settings.input.shift"),
                (NativeShortcutModifiers.Option, "settings.input.option"), (NativeShortcutModifiers.Command, "settings.input.command"),
            }.Where(m => value.HasFlag(m.Item1)).Select(m => Strings.Get(m.Item2)));

    public static ComboBox Choice(string header, string automationId, params string[] items)
    {
        var box = new ComboBox { Header = header, MinWidth = 240 };
        AutomationProperties.SetAutomationId(box, automationId);
        foreach (var item in items) box.Items.Add(item);
        return box;
    }
}

/// <summary>The per-connection Input dialog (macOS InputSettingsSheet; PARITY I01-I13, K01-K06).</summary>
internal static class InputDialog
{
    public static ContentDialog Create(NativeInputDraft draft)
    {
        var updating = false;
        CheckBox Check(string key, string id, Action<bool> set)
        {
            var box = new CheckBox { Content = Strings.Get(key) };
            AutomationProperties.SetAutomationId(box, id);
            box.Click += (_, _) => { if (!updating) set(box.IsChecked == true); };
            return box;
        }
        var viewOnly = Check("settings.input.view.only", "input.viewOnly", v => draft.ViewOnly = v);
        var viewOnlySource = Ui.Caption("");
        var middle = Check("settings.input.emulate.middle.mouse.button", "input.emulateMiddle", v => draft.EmulateMiddle = v);
        var middleSource = Ui.Caption("");
        var systemKeys = Check("settings.input.capture.system.keys.in.full.screen", "input.fullscreenSystemKeys", v => draft.FullscreenSystemKeys = v);
        var systemKeysSource = Ui.Caption("");
        var modifiers = new Dictionary<NativeShortcutModifiers, CheckBox>();
        var modifierGrid = new Grid { ColumnSpacing = 12, RowSpacing = 4 };
        modifierGrid.ColumnDefinitions.Add(new ColumnDefinition());
        modifierGrid.ColumnDefinitions.Add(new ColumnDefinition());
        modifierGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        modifierGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var index = 0;
        foreach (var (bit, key) in new[] { (NativeShortcutModifiers.Control, "settings.input.control"), (NativeShortcutModifiers.Shift, "settings.input.shift"),
                                           (NativeShortcutModifiers.Option, "settings.input.option"), (NativeShortcutModifiers.Command, "settings.input.command") })
        {
            var flag = bit;
            var box = Check(key, "input.modifier." + (uint)bit, selected => draft.ShortcutModifiers = selected ? draft.ShortcutModifiers | flag : draft.ShortcutModifiers & ~flag);
            Grid.SetRow(box, index / 2); Grid.SetColumn(box, index % 2);
            modifierGrid.Children.Add(box);
            modifiers[bit] = box;
            index++;
        }
        AutomationProperties.SetAutomationId(modifierGrid, "input.shortcutModifiers");
        var modifierSource = Ui.Caption("");
        var shortcutHelp = Ui.Caption("");
        var cursor = SettingsLabels.Choice(Strings.Get("settings.input.cursor.fallback"), "input.cursorFallback",
            SettingsLabels.Cursor(NativeCursorFallback.Hidden), SettingsLabels.Cursor(NativeCursorFallback.Dot), SettingsLabels.Cursor(NativeCursorFallback.System));
        cursor.SelectionChanged += (_, _) => { if (!updating && cursor.SelectedIndex >= 0) draft.CursorFallback = (NativeCursorFallback)cursor.SelectedIndex; };
        var cursorSource = Ui.Caption("");
        var error = Ui.Text("", "input.error");
        error.Foreground = Ui.Error;
        var panel = Ui.Stack(8,
            Ui.Caption(Strings.Get("settings.input.these.settings.apply.to.this.connection")),
            viewOnly, viewOnlySource,
            Ui.Caption(Strings.Get("settings.input.watch.the.remote.desktop.without.sending.keyboard.pointer.or.clipboard.input.enabling")),
            middle, middleSource,
            Ui.Caption(Strings.Get("settings.input.press.the.left.and.right.mouse.buttons.together.for.a.middle.click")),
            systemKeys, systemKeysSource,
            Ui.Caption(Strings.Get("settings.input.requires.macos.accessibility.permission.keyboard.capture.stops.when.this.desktop.loses.focus")),
            Ui.Heading(Strings.Get("settings.input.viewer.shortcut.modifiers")), modifierGrid, modifierSource, shortcutHelp,
            cursor, cursorSource,
            Ui.Caption(Strings.Get("settings.input.used.when.the.server.supplies.no.visible.cursor.view.only.mode.always")),
            error);
        var dialog = Ui.Dialog(Strings.Get("settings.input.input.settings"), panel, 480);
        dialog.PrimaryButtonText = Strings.Get("action.apply");
        dialog.CloseButtonText = Strings.Get("action.cancel");
        AutomationProperties.SetAutomationId(dialog, "input.dialog");

        void Refresh()
        {
            updating = true;
            viewOnly.IsChecked = draft.ViewOnly; middle.IsChecked = draft.EmulateMiddle; systemKeys.IsChecked = draft.FullscreenSystemKeys;
            foreach (var (bit, box) in modifiers) box.IsChecked = draft.ShortcutModifiers.HasFlag(bit);
            cursor.SelectedIndex = (int)draft.CursorFallback;
            updating = false;
            viewOnlySource.Text = SettingsLabels.ConnectionSource(draft.Source(NativeInputOption.ViewOnly));
            middleSource.Text = SettingsLabels.ConnectionSource(draft.Source(NativeInputOption.EmulateMiddle));
            systemKeysSource.Text = SettingsLabels.ConnectionSource(draft.Source(NativeInputOption.FullscreenSystemKeys));
            modifierSource.Text = SettingsLabels.ConnectionSource(draft.Source(NativeInputOption.ShortcutModifiers));
            cursorSource.Text = SettingsLabels.ConnectionSource(draft.Source(NativeInputOption.CursorFallback));
            shortcutHelp.Text = draft.ShortcutModifiers == NativeShortcutModifiers.None
                ? Strings.Get("settings.input.viewer.shortcuts.are.off.use.the.connection.menu.to.release.keyboard.capture")
                : Strings.Format("settings.input.shortcut.instructions", SettingsLabels.Modifiers(draft.ShortcutModifiers));
            error.Text = draft.Issue switch
            {
                NativeInputIssue.Changed => Strings.Get("settings.input.input.settings.changed.while.this.editor.was.open.close.and.reopen.it"),
                NativeInputIssue.Closed => Strings.Get("settings.input.this.connection.s.input.settings.are.no.longer.available"),
                NativeInputIssue.Failed => Strings.Get("settings.input.input.settings.could.not.be.applied.close.and.reopen.the.editor.to"),
                _ => "",
            };
            error.Visibility = draft.Issue is null ? Visibility.Collapsed : Visibility.Visible;
            dialog.IsPrimaryButtonEnabled = draft.CanApply;
            dialog.DefaultButton = draft.CanApply ? ContentDialogButton.Primary : ContentDialogButton.Close;
        }
        draft.PropertyChanged += (_, _) => Refresh();
        Refresh();
        dialog.PrimaryButtonClick += (_, args) => { if (!draft.Apply()) args.Cancel = true; };
        dialog.Closed += (_, _) => draft.Cancel();
        return dialog;
    }
}

/// <summary>The per-connection Scaling dialog (macOS ScalingSettingsSheet; PARITY Z05-Z12).</summary>
internal static class ScalingDialog
{
    public static ContentDialog Create(NativeScalingDraft draft)
    {
        var updating = false;
        var modes = Enum.GetValues<NativeScalingMode>();
        var mode = SettingsLabels.Choice(Strings.Get("settings.scaling.mode"), "scaling.mode", [.. modes.Select(SettingsLabels.Mode)]);
        mode.SelectionChanged += (_, _) => { if (!updating && mode.SelectedIndex >= 0) draft.Mode = modes[mode.SelectedIndex]; };
        var modeSource = Ui.Caption("");
        var value = new TextBox { IsSpellCheckEnabled = false };
        AutomationProperties.SetAutomationId(value, "scaling.value");
        value.TextChanged += (_, _) => { if (!updating) draft.Text = value.Text; };
        var valueHelp = Ui.Caption("");
        var units = SettingsLabels.Choice(Strings.Get("settings.scaling.size.units"), "scaling.units",
            Strings.Get("settings.scaling.logical.points"), Strings.Get("settings.scaling.device.pixels"));
        units.SelectionChanged += (_, _) => { if (!updating && units.SelectedIndex >= 0) draft.DevicePixels = units.SelectedIndex == 1; };
        var unitsSource = Ui.Caption("");
        var unitsHelp = Ui.Caption("");
        var filters = Enum.GetValues<NativeScalingFilter>();
        var filter = SettingsLabels.Choice(Strings.Get("settings.scaling.scaling.quality"), "scaling.filter", [.. filters.Select(SettingsLabels.Filter)]);
        filter.SelectionChanged += (_, _) => { if (!updating && filter.SelectedIndex >= 0) draft.Filter = filters[filter.SelectedIndex]; };
        var filterSource = Ui.Caption("");
        var filterHelp = Ui.Caption("");
        var error = Ui.Text("", "scaling.error");
        error.Foreground = Ui.Error;
        var panel = Ui.Stack(8,
            Ui.Caption(Strings.Get("settings.scaling.change.how.this.connection.s.desktop.fits.in.the.window.the.remote")),
            mode, modeSource, value, valueHelp, units, unitsSource, unitsHelp, filter, filterSource, filterHelp, error);
        var dialog = Ui.Dialog(Strings.Get("settings.scaling.scaling.settings"), panel, 480);
        dialog.PrimaryButtonText = Strings.Get("action.apply");
        dialog.CloseButtonText = Strings.Get("action.cancel");
        AutomationProperties.SetAutomationId(dialog, "scaling.dialog");

        void Refresh()
        {
            updating = true;
            mode.SelectedIndex = Array.IndexOf(modes, draft.Mode);
            if (value.Text != draft.Text) value.Text = draft.Text;
            units.SelectedIndex = draft.DevicePixels ? 1 : 0;
            filter.SelectedIndex = Array.IndexOf(filters, draft.Filter);
            updating = false;
            var custom = draft.Mode.Custom();
            value.Visibility = valueHelp.Visibility = custom ? Visibility.Visible : Visibility.Collapsed;
            value.Header = Strings.Get(draft.Mode == NativeScalingMode.Exact ? "settings.scaling.dimensions" : "settings.scaling.percentage");
            AutomationProperties.SetName(value, (string)value.Header);
            valueHelp.Text = Strings.Get(draft.Mode switch
            {
                NativeScalingMode.Exact => "settings.scaling.width.x.height.each.from.1.to.65535.for.example.1920x1080",
                NativeScalingMode.Independent => "settings.scaling.width.x.height.each.from.0.01.to.10000.with.up.to",
                _ => "settings.scaling.from.0.01.to.10000.with.up.to.two.decimal.places.for",
            });
            units.IsEnabled = !draft.Mode.Fits();
            unitsHelp.Text = Strings.Get(draft.Mode.Fits() ? "settings.scaling.fit.modes.always.use.the.available.window.space"
                : "settings.scaling.on.a.retina.display.one.logical.point.spans.multiple.device.pixels");
            modeSource.Text = SettingsLabels.ConnectionSource(draft.Source(NativeScalingOption.Scaling));
            unitsSource.Text = SettingsLabels.ConnectionSource(draft.Source(NativeScalingOption.DevicePixels));
            filterSource.Text = SettingsLabels.ConnectionSource(draft.Source(NativeScalingOption.Filter));
            filterHelp.Text = SettingsLabels.FilterHelp(draft.Filter);
            error.Text = draft.Issue switch
            {
                NativeScalingIssue.Dimensions => Strings.Get("settings.scaling.this.size.exceeds.the.display.limits.choose.a.smaller.size.or.a"),
                NativeScalingIssue.Changed => Strings.Get("settings.scaling.scaling.changed.while.this.editor.was.open.close.and.reopen.it.to"),
                NativeScalingIssue.Closed => Strings.Get("settings.scaling.this.connection.s.scaling.settings.are.no.longer.available"),
                _ => draft.Issue is not null || draft.Candidate is null ? Strings.Get("settings.scaling.enter.a.valid.value.for.the.selected.scaling.mode") : "",
            };
            error.Visibility = error.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            dialog.IsPrimaryButtonEnabled = draft.CanApply;
            dialog.DefaultButton = draft.CanApply ? ContentDialogButton.Primary : ContentDialogButton.Close;
        }
        draft.PropertyChanged += (_, _) => Refresh();
        Refresh();
        dialog.PrimaryButtonClick += (_, args) => { if (!draft.Apply()) args.Cancel = true; };
        dialog.Closed += (_, _) => draft.Cancel();
        return dialog;
    }
}
