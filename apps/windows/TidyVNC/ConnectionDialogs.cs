// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Input;
using TidyVNC.Native;
using TidyVNC.Native.Platform;

namespace TidyVNC;

/// <summary>The per-window Connection options dialog (macOS SessionConnectionSheet; PARITY D09-D10).</summary>
internal static class ConnectionOptionsDialog
{
    private static string Source(NativeOptionSource value) => Strings.Get(value switch
    {
        NativeOptionSource.AppDefaults => "settings.connection.app.default",
        NativeOptionSource.Profile => "settings.connection.profile",
        NativeOptionSource.Session => "settings.connection.connection.override",
        NativeOptionSource.Document => "settings.connection.connection.file",
        NativeOptionSource.CommandLine => "settings.connection.command.line",
        _ => "settings.connection.built.in.default",
    });

    /// <summary>An inherit/on/off choice (macOS ConnectionSettingsFields.field).</summary>
    private static (ComboBox Box, TextBlock Effective) TriState(string key, string id, Action<bool?> set, Func<bool> updating)
    {
        var box = SettingsLabels.Choice(Strings.Get(key), "connection.options." + id,
            Strings.Get("settings.connection.initial.setting"), Strings.Get("settings.input.on"), Strings.Get("settings.input.off"));
        box.SelectionChanged += (_, _) =>
        {
            if (!updating() && box.SelectedIndex >= 0) set(box.SelectedIndex switch { 1 => true, 2 => false, _ => null });
        };
        return (box, Ui.Caption(""));
    }

    private static int Index(bool? value) => value switch { true => 1, false => 2, _ => 0 };

    public static ContentDialog Create(NativeConnectionDraft draft)
    {
        var updating = false;
        var (shared, sharedEffective) = TriState("settings.connection.share.server.with.other.viewers", "shared", v => draft.Shared = v, () => updating);
        var (retry, retryEffective) = TriState("settings.connection.offer.retry.after.connection.errors", "retry", v => draft.ReconnectOnError = v, () => updating);
        var sources = Ui.Caption("");
        var error = Ui.Text("", "connection.options.error");
        error.Foreground = Ui.Error;
        var applied = Ui.Caption(Strings.Get("settings.connection.applied.to.this.connection.window"));
        var panel = Ui.Stack(8,
            Ui.Caption(Strings.Get("settings.connection.apply.while.disconnected.then.connect.again.these.options.stay.in.this.window")),
            shared, sharedEffective,
            Ui.Caption(Strings.Get("settings.connection.requests.shared.access.when.connecting.with.sharing.off.the.server.may.disconnect")),
            retry, retryEffective,
            Ui.Caption(Strings.Get("settings.connection.shows.a.retry.action.for.recoverable.connection.errors.tidyvnc.reconnects.only.when")),
            sources, error, applied);
        var dialog = Ui.Dialog(Strings.Get("settings.connection.connection.options"), panel, 560);
        dialog.PrimaryButtonText = Strings.Get("action.apply");
        AutomationProperties.SetAutomationId(dialog, "connection.options.dialog");

        string Effective(bool value) => Strings.Format("settings.inheritance.effective.value", Strings.Get(value ? "settings.input.on" : "settings.input.off"));
        void Refresh()
        {
            updating = true;
            shared.SelectedIndex = Index(draft.Shared);
            retry.SelectedIndex = Index(draft.ReconnectOnError);
            updating = false;
            shared.IsEnabled = retry.IsEnabled = !draft.NeedsReload;
            sharedEffective.Text = Effective(draft.InitialShared);
            sharedEffective.Visibility = draft.Shared is null ? Visibility.Visible : Visibility.Collapsed;
            retryEffective.Text = Effective(draft.InitialReconnectOnError);
            retryEffective.Visibility = draft.ReconnectOnError is null ? Visibility.Visible : Visibility.Collapsed;
            sources.Text = draft.Baseline is { } baseline
                ? Strings.Format("settings.connection.sources", Source(baseline.SharedSource), Source(baseline.ReconnectSource)) : "";
            sources.Visibility = draft.Baseline is null ? Visibility.Collapsed : Visibility.Visible;
            error.Text = draft.Error switch
            {
                NativeConnectionDraftError.Unavailable => Strings.Get("settings.connection.disconnect.and.wait.for.the.connection.to.close.then.reload"),
                NativeConnectionDraftError.Changed => Strings.Get("settings.connection.the.connection.or.options.changed.reload.before.applying"),
                NativeConnectionDraftError.ConnectionChanged => Strings.Get("settings.connection.the.connection.changed.reload.before.applying"),
                _ => "",
            };
            error.Visibility = draft.Error is null ? Visibility.Collapsed : Visibility.Visible;
            applied.Visibility = draft.DidApply ? Visibility.Visible : Visibility.Collapsed;
            dialog.SecondaryButtonText = draft.NeedsReload ? Strings.Get("action.discard.edits.reload") : "";
            dialog.IsSecondaryButtonEnabled = draft.CanReload;
            dialog.CloseButtonText = Strings.Get(draft.HasChanges ? "action.cancel" : "action.done");
            dialog.IsPrimaryButtonEnabled = draft.CanApply;
            dialog.DefaultButton = draft.CanApply ? ContentDialogButton.Primary : ContentDialogButton.Close;
        }
        draft.PropertyChanged += (_, _) => Refresh();
        Refresh();
        // Applying keeps the dialog open to confirm the result (macOS keeps the sheet).
        dialog.PrimaryButtonClick += (_, args) => { args.Cancel = true; draft.Apply(); };
        dialog.SecondaryButtonClick += (_, args) => { args.Cancel = true; draft.Reload(); };
        dialog.Closed += (_, _) => draft.Stop();
        return dialog;
    }
}

/// <summary>The per-window Remote resize settings dialog (macOS RemoteResizePolicySheet; PARITY D05-D08).</summary>
internal static class RemoteResizePolicyDialog
{
    public static ContentDialog Create(NativeRemoteResizePolicyDraft draft)
    {
        var updating = false;
        var enabled = new CheckBox { Content = Strings.Get("settings.resize.resize.the.remote.desktop.with.this.window") };
        AutomationProperties.SetAutomationId(enabled, "remoteResizePolicy.enabled");
        enabled.Click += (_, _) => { if (!updating) draft.Enabled = enabled.IsChecked == true; };
        var enabledSource = Ui.Caption("");
        var size = new TextBox
        {
            Header = Strings.Get("settings.resize.initial.size.for.the.next.connection"),
            PlaceholderText = Strings.Get("settings.resize.leave.blank.to.use.the.server.s.size"),
            IsSpellCheckEnabled = false,
        };
        AutomationProperties.SetName(size, Strings.Get("settings.resize.initial.desktop.size"));
        AutomationProperties.SetAutomationId(size, "remoteResizePolicy.initialSize");
        size.TextChanged += (_, _) => { if (!updating) draft.InitialSize = size.Text; };
        var sizeSource = Ui.Caption("");
        var error = Ui.Text("", "remoteResizePolicy.error");
        error.Foreground = Ui.Warning;
        var restore = Ui.Button(Strings.Get("settings.fullscreen.restore.initial.settings"), (_, _) => draft.RestoreInitial(), "remoteResizePolicy.restore");
        var panel = Ui.Stack(8,
            Ui.Caption(Strings.Get("settings.resize.these.settings.apply.to.this.connection.window.saved.defaults.and.profiles.stay")),
            enabled, enabledSource,
            Ui.Caption(Strings.Get("settings.resize.automatic.resizing.follows.the.window.or.the.complete.fullscreen.display.arrangement.in")),
            size, sizeSource,
            Ui.Caption(Strings.Get("settings.resize.optional.width.height.in.remote.pixels.such.as.1920x1080.leave.blank.to")),
            Ui.Caption(Strings.Get("settings.resize.a.resize.may.affect.other.viewers.windowed.and.initial.size.requests.use")),
            error, restore);
        var dialog = Ui.Dialog(Strings.Get("settings.resize.remote.resize.settings"), panel, 560);
        dialog.PrimaryButtonText = Strings.Get("action.apply");
        dialog.CloseButtonText = Strings.Get("action.cancel");
        AutomationProperties.SetAutomationId(dialog, "remoteResizePolicy.dialog");

        void Refresh()
        {
            updating = true;
            enabled.IsChecked = draft.Enabled;
            if (size.Text != draft.InitialSize) size.Text = draft.InitialSize;
            updating = false;
            enabledSource.Text = SettingsLabels.ResizeSource(draft.Source(NativeResizeOption.Enabled));
            sizeSource.Text = SettingsLabels.ResizeSource(draft.Source(NativeResizeOption.InitialSize));
            error.Text = draft.Changed ? Strings.Get("settings.resize.the.connection.s.resize.settings.changed.close.and.reopen.this.sheet")
                : !draft.IsValid ? Strings.Get("settings.resize.use.widthxheight.with.each.dimension.from.1.to.65535.or.leave.the") : "";
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

/// <summary>
/// Resize the remote desktop (macOS RemoteResizeSheet and
/// RemoteDisplayChooser; PARITY D01-D04): a custom size or one remote
/// screen per chosen local display. The server's reply is shown in place.
/// </summary>
internal static class RemoteResizeDialog
{
    private static readonly NativeRemoteResizeSource[] SourceValues = Enum.GetValues<NativeRemoteResizeSource>();

    private static string Title(NativeRemoteResizeSource source) => Strings.Get(source switch
    {
        NativeRemoteResizeSource.AllDisplays => "settings.resize.all.local.displays",
        NativeRemoteResizeSource.SelectedDisplays => "settings.resize.selected.local.displays",
        _ => "settings.resize.custom.size",
    });

    /// <summary>"1. Name — W × H effective pixels, S%" (the Windows form of settings.display.description).</summary>
    internal static string Describe(int index, NativeDisplayInfo display) => Strings.Format("settings.display.description",
        (index + 1).ToString(CultureInfo.CurrentCulture), display.Name,
        Math.Round(display.LogicalBounds.Width).ToString("N0", CultureInfo.CurrentCulture),
        Math.Round(display.LogicalBounds.Height).ToString("N0", CultureInfo.CurrentCulture),
        Math.Round(display.Scale * 100).ToString("N0", CultureInfo.CurrentCulture));

    private static string Number(uint value) => value.ToString("N0", CultureInfo.CurrentCulture);

    private static string Message(NativeRemoteResizeDraft draft) => draft.Message switch
    {
        NativeRemoteResizeMessage.Unavailable => Strings.Get("settings.resize.the.current.remote.desktop.size.is.unavailable"),
        NativeRemoteResizeMessage.LayoutChanged => Strings.Get("settings.resize.the.server.s.desktop.layout.changed.reload.before.resizing"),
        NativeRemoteResizeMessage.RequestUnavailable => Strings.Get("settings.resize.the.requested.desktop.size.is.unavailable"),
        NativeRemoteResizeMessage.Applied when draft.Baseline is { } current =>
            Strings.Format("settings.resize.server.size", Number(current.Layout.Width), Number(current.Layout.Height)),
        NativeRemoteResizeMessage.Rejected => Strings.Format("settings.resize.server.rejection", draft.RejectionResult.ToString(CultureInfo.CurrentCulture)),
        NativeRemoteResizeMessage.TimedOut => Strings.Get("settings.resize.the.server.has.not.replied.wait.for.its.reply.or.reconnect.before"),
        NativeRemoteResizeMessage.TooLarge => Strings.Get("settings.resize.this.size.exceeds.the.connection.s.framebuffer.limit.choose.a.smaller.size"),
        NativeRemoteResizeMessage.Incomplete => Strings.Get("settings.resize.the.resize.did.not.complete.reload.the.current.desktop.size.before.trying"),
        _ => "",
    };

    public static ContentDialog Create(NativeRemoteResizeDraft draft)
    {
        var updating = false;
        var source = SettingsLabels.Choice(Strings.Get("settings.resize.resolution.from"), "remoteResize.source", [.. SourceValues.Select(Title)]);
        source.SelectionChanged += (_, _) => { if (!updating && source.SelectedIndex >= 0) draft.Source = SourceValues[source.SelectedIndex]; };

        TextBox Field(string key, string id, Action<string> set)
        {
            var box = new TextBox { Header = Strings.Get(key), IsSpellCheckEnabled = false, InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.Number) } } };
            AutomationProperties.SetAutomationId(box, id);
            box.TextChanged += (_, _) => { if (!updating) set(box.Text); };
            return box;
        }
        var width = Field("settings.resize.width.in.pixels", "remoteResize.width", v => draft.Width = v);
        var height = Field("settings.resize.height.in.pixels", "remoteResize.height", v => draft.Height = v);
        var replaces = Ui.Caption("", Ui.Warning);
        var custom = Ui.Stack(8, width, height,
            Ui.Caption(Strings.Get("settings.resize.enter.whole.numbers.from.1.to.65535.the.server.and.this.connection")), replaces);

        var map = new Canvas { Height = 110 };
        AutomationProperties.SetAccessibilityView(map, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        map.SizeChanged += (_, _) => DrawMap();
        var list = new StackPanel { Spacing = 6 };
        AutomationProperties.SetAutomationId(list, "remoteResize.displays");
        var devicePixels = new CheckBox { Content = Strings.Get("settings.resize.use.device.pixels") };
        AutomationProperties.SetAutomationId(devicePixels, "remoteResize.devicePixels");
        devicePixels.Click += (_, _) => { if (!updating) draft.DevicePixels = devicePixels.IsChecked == true; };
        var requested = Ui.Text("", "remoteResize.requested");
        var normalized = Ui.Caption(Strings.Get("settings.resize.the.remote.arrangement.is.adjusted.to.keep.displays.with.different.pixel.densities"));
        var problem = Ui.Text("", "remoteResize.displayProblem");
        problem.Foreground = Ui.Warning;
        var chooser = Ui.Stack(10, map, list, devicePixels,
            Ui.Caption(Strings.Get("settings.resize.creates.one.remote.screen.per.selected.local.display.this.changes.the.server")),
            requested, normalized, problem);

        var busy = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        busy.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        busy.Children.Add(Ui.Text(Strings.Get("settings.resize.waiting.for.the.server")));
        var result = Ui.Text("", "remoteResize.result");
        var undo = Ui.Caption(Strings.Get("settings.resize.closing.this.sheet.cannot.undo.a.request.already.sent.to.the.server"));
        var panel = Ui.Stack(12,
            Ui.Caption(Strings.Get("settings.resize.request.a.new.resolution.from.the.server.this.may.affect.other.viewers")),
            source, custom, chooser, busy, result, undo);
        var dialog = Ui.Dialog(Strings.Get("settings.resize.resize.remote.desktop"), panel, 520);
        dialog.PrimaryButtonText = Strings.Get("settings.resize.resize");
        dialog.SecondaryButtonText = Strings.Get("trust.library.ui.reload");
        AutomationProperties.SetAutomationId(dialog, "remoteResize.dialog");

        void Toggle(string id, bool selected)
        {
            var next = new HashSet<string>(draft.SelectedDisplays, StringComparer.Ordinal);
            if (selected) next.Add(id); else next.Remove(id);
            draft.SelectedDisplays = next;
        }

        void DrawMap()
        {
            map.Children.Clear();
            var displays = draft.DisplaySnapshot?.Displays ?? [];
            if (displays.IsEmpty || map.ActualWidth <= 12) return;
            double left = displays.Min(d => d.Bounds.X), top = displays.Min(d => d.Bounds.Y);
            double right = displays.Max(d => d.Bounds.X + d.Bounds.Width), bottom = displays.Max(d => d.Bounds.Y + d.Bounds.Height);
            var scale = Math.Min((map.ActualWidth - 12) / Math.Max(1, right - left), (map.ActualHeight - 12) / Math.Max(1, bottom - top));
            double offsetX = (map.ActualWidth - (right - left) * scale) / 2, offsetY = (map.ActualHeight - (bottom - top) * scale) / 2;
            var accent = Ui.Brush("AccentFillColorDefaultBrush");
            for (var i = 0; i < displays.Length; i++)
            {
                var display = displays[i];
                var chosen = draft.Source == NativeRemoteResizeSource.AllDisplays || draft.SelectedDisplays.Contains(display.Id);
                var tile = new Grid
                {
                    Width = Math.Max(1, display.Bounds.Width * scale - 3), Height = Math.Max(1, display.Bounds.Height * scale - 3),
                    CornerRadius = new CornerRadius(5), BorderThickness = new Thickness(2),
                    BorderBrush = chosen ? accent : Ui.Secondary,
                    Background = new SolidColorBrush(((SolidColorBrush)(chosen ? accent : Ui.Secondary)).Color) { Opacity = 0.18 },
                };
                tile.Children.Add(new TextBlock
                {
                    Text = (i + 1).ToString(CultureInfo.CurrentCulture), FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                });
                var id = display.Id;
                tile.Tapped += (_, _) =>
                {
                    if (draft.Source == NativeRemoteResizeSource.SelectedDisplays && !draft.IsBusy) Toggle(id, !draft.SelectedDisplays.Contains(id));
                };
                Canvas.SetLeft(tile, offsetX + (display.Bounds.X - left) * scale + 1.5);
                Canvas.SetTop(tile, offsetY + (display.Bounds.Y - top) * scale + 1.5);
                map.Children.Add(tile);
            }
        }

        void FillList()
        {
            list.Children.Clear();
            var displays = draft.DisplaySnapshot?.Displays ?? [];
            var selectable = draft.Source == NativeRemoteResizeSource.SelectedDisplays;
            for (var i = 0; i < displays.Length; i++)
            {
                var label = Describe(i, displays[i]);
                if (!selectable) { list.Children.Add(Ui.Text(label)); continue; }
                var id = displays[i].Id;
                var box = new CheckBox { Content = label, IsChecked = draft.SelectedDisplays.Contains(id), IsEnabled = !draft.IsBusy };
                AutomationProperties.SetAutomationId(box, "remoteResize.display." + i.ToString(CultureInfo.InvariantCulture));
                box.Click += (_, _) => Toggle(id, box.IsChecked == true);
                list.Children.Add(box);
            }
            var missing = draft.MissingDisplays;
            for (var i = 0; i < missing.Count; i++)
            {
                var id = missing[i];
                var box = new CheckBox
                {
                    Content = Strings.Format("settings.display.disconnected.selection", (i + 1).ToString(CultureInfo.CurrentCulture)),
                    IsChecked = true, IsEnabled = !draft.IsBusy,
                };
                box.Click += (_, _) => Toggle(id, box.IsChecked == true);
                list.Children.Add(box);
            }
        }

        void Refresh()
        {
            updating = true;
            source.SelectedIndex = Array.IndexOf(SourceValues, draft.Source);
            if (width.Text != draft.Width) width.Text = draft.Width;
            if (height.Text != draft.Height) height.Text = draft.Height;
            devicePixels.IsChecked = draft.DevicePixels;
            updating = false;
            var isCustom = draft.Source == NativeRemoteResizeSource.Custom;
            source.IsEnabled = width.IsEnabled = height.IsEnabled = devicePixels.IsEnabled = !draft.IsBusy;
            custom.Visibility = isCustom ? Visibility.Visible : Visibility.Collapsed;
            chooser.Visibility = isCustom ? Visibility.Collapsed : Visibility.Visible;
            var screens = draft.Baseline?.Layout.Screens.Count ?? 0;
            replaces.Text = screens > 1 ? Strings.Format("settings.resize.replaces.layout", screens.ToString("N0", CultureInfo.CurrentCulture)) : "";
            replaces.Visibility = screens > 1 ? Visibility.Visible : Visibility.Collapsed;
            if (!isCustom)
            {
                FillList();
                DrawMap();
                var layout = draft.DisplayLayout;
                requested.Text = layout is null ? "" : Strings.Format("settings.resize.requested.layout",
                    Number(layout.Width), Number(layout.Height), layout.Regions.Count.ToString("N0", CultureInfo.CurrentCulture));
                requested.Visibility = layout is null ? Visibility.Collapsed : Visibility.Visible;
                normalized.Visibility = layout?.Normalized == true ? Visibility.Visible : Visibility.Collapsed;
                problem.Text = draft.DisplayProblem is { } text ? Strings.Resolve(text) : "";
                problem.Visibility = problem.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            }
            busy.Visibility = undo.Visibility = draft.IsBusy ? Visibility.Visible : Visibility.Collapsed;
            result.Text = Message(draft);
            result.Foreground = draft.DidApply ? Ui.Secondary : Ui.Warning;
            result.Visibility = result.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            dialog.CloseButtonText = Strings.Get(draft.DidApply ? "action.done" : "action.cancel");
            dialog.IsSecondaryButtonEnabled = draft.CanReload;
            dialog.IsPrimaryButtonEnabled = draft.CanApply;
            dialog.DefaultButton = draft.CanApply ? ContentDialogButton.Primary : ContentDialogButton.Close;
        }
        draft.PropertyChanged += (_, _) => Refresh();
        Refresh();
        dialog.PrimaryButtonClick += (_, args) => { args.Cancel = true; draft.Apply(); };
        dialog.SecondaryButtonClick += (_, args) => { args.Cancel = true; draft.Reload(); };
        return dialog;
    }
}
