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
        Ui.SetTone(error, Tone.Error);
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
        Ui.SetTone(error, Tone.Warning);
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
            enabledSource.Text = SettingsLabels.ShortSource(draft.Source(NativeResizeOption.Enabled));
            sizeSource.Text = SettingsLabels.ShortSource(draft.Source(NativeResizeOption.InitialSize));
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
        var replaces = Ui.Caption("", Tone.Warning);
        var custom = Ui.Stack(8, width, height,
            Ui.Caption(Strings.Get("settings.resize.enter.whole.numbers.from.1.to.65535.the.server.and.this.connection")), replaces);

        var chooser = new DisplayChooser("remoteResize");
        var devicePixels = new CheckBox { Content = Strings.Get("settings.resize.use.device.pixels") };
        AutomationProperties.SetAutomationId(devicePixels, "remoteResize.devicePixels");
        devicePixels.Click += (_, _) => { if (!updating) draft.DevicePixels = devicePixels.IsChecked == true; };
        var requested = Ui.Text("", "remoteResize.requested");
        var normalized = Ui.Caption(Strings.Get("settings.resize.the.remote.arrangement.is.adjusted.to.keep.displays.with.different.pixel.densities"));
        var problem = Ui.Text("", "remoteResize.displayProblem");
        Ui.SetTone(problem, Tone.Warning);
        var chooserPanel = Ui.Stack(10, chooser.Map, chooser.List, devicePixels,
            Ui.Caption(Strings.Get("settings.resize.creates.one.remote.screen.per.selected.local.display.this.changes.the.server")),
            requested, normalized, problem);

        var busy = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        busy.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        busy.Children.Add(Ui.Text(Strings.Get("settings.resize.waiting.for.the.server")));
        var result = Ui.Text("", "remoteResize.result");
        var undo = Ui.Caption(Strings.Get("settings.resize.closing.this.sheet.cannot.undo.a.request.already.sent.to.the.server"));
        var panel = Ui.Stack(12,
            Ui.Caption(Strings.Get("settings.resize.request.a.new.resolution.from.the.server.this.may.affect.other.viewers")),
            source, custom, chooserPanel, busy, result, undo);
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
            chooserPanel.Visibility = isCustom ? Visibility.Collapsed : Visibility.Visible;
            var screens = draft.Baseline?.Layout.Screens.Count ?? 0;
            replaces.Text = screens > 1 ? Strings.Format("settings.resize.replaces.layout", screens.ToString("N0", CultureInfo.CurrentCulture)) : "";
            replaces.Visibility = screens > 1 ? Visibility.Visible : Visibility.Collapsed;
            if (!isCustom)
            {
                var all = draft.Source == NativeRemoteResizeSource.AllDisplays;
                chooser.Show(draft.DisplaySnapshot?.Displays ?? [], id => all || draft.SelectedDisplays.Contains(id),
                    draft.Source == NativeRemoteResizeSource.SelectedDisplays, draft.SelectedDisplays, draft.MissingDisplays, !draft.IsBusy, Toggle);
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
            Ui.SetTone(result, draft.DidApply ? Tone.Secondary : Tone.Warning);
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

/// <summary>
/// The display arrangement picture and list shared by the full-screen and
/// remote resize dialogs (macOS RemoteDisplayChooser and the fullscreen
/// sheet's tiles): chosen displays are highlighted; in selection mode tiles
/// and check boxes toggle a display, and disconnected selections stay listed.
/// </summary>
internal sealed class DisplayChooser
{
    private readonly string prefix;
    private IReadOnlyList<NativeDisplayInfo> displays = [];
    private Func<string, bool> chosen = _ => false;
    private bool selectable, enabled;
    private Action<string, bool> toggle = (_, _) => { };

    public Canvas Map { get; } = new() { Height = 110 };
    public StackPanel List { get; } = new() { Spacing = 6 };

    public DisplayChooser(string prefix)
    {
        this.prefix = prefix;
        AutomationProperties.SetAccessibilityView(Map, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        AutomationProperties.SetAutomationId(List, prefix + ".displays");
        Map.SizeChanged += (_, _) => Draw();
    }

    /// <summary>"1. Name — W × H effective pixels, S%" (the Windows form of settings.display.description).</summary>
    public static string Describe(int index, NativeDisplayInfo display) => Strings.Format("settings.display.description",
        (index + 1).ToString(CultureInfo.CurrentCulture), display.Name,
        Math.Round(display.LogicalBounds.Width).ToString("N0", CultureInfo.CurrentCulture),
        Math.Round(display.LogicalBounds.Height).ToString("N0", CultureInfo.CurrentCulture),
        Math.Round(display.Scale * 100).ToString("N0", CultureInfo.CurrentCulture));

    public void Show(IReadOnlyList<NativeDisplayInfo> displays, Func<string, bool> chosen, bool selectable, IReadOnlySet<string> selected,
                     IReadOnlyList<string> missing, bool enabled, Action<string, bool> toggle)
    {
        this.displays = displays; this.chosen = chosen; this.selectable = selectable; this.enabled = enabled; this.toggle = toggle;
        Draw();
        List.Children.Clear();
        for (var i = 0; i < displays.Count; i++)
        {
            var label = Describe(i, displays[i]);
            if (!selectable) { List.Children.Add(Ui.Text(label)); continue; }
            var id = displays[i].Id;
            var box = new CheckBox { Content = label, IsChecked = selected.Contains(id), IsEnabled = enabled };
            AutomationProperties.SetAutomationId(box, prefix + ".display." + i.ToString(CultureInfo.InvariantCulture));
            box.Click += (_, _) => toggle(id, box.IsChecked == true);
            List.Children.Add(box);
        }
        if (!selectable) return;
        for (var i = 0; i < missing.Count; i++)
        {
            var id = missing[i];
            var box = new CheckBox
            {
                Content = Strings.Format("settings.display.disconnected.selection", (i + 1).ToString(CultureInfo.CurrentCulture)),
                IsChecked = true, IsEnabled = enabled,
            };
            box.Click += (_, _) => toggle(id, box.IsChecked == true);
            List.Children.Add(box);
        }
    }

    private void Draw()
    {
        Map.Children.Clear();
        Map.Visibility = displays.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (displays.Count == 0 || Map.ActualWidth <= 12) return;
        double left = displays.Min(d => d.Bounds.X), top = displays.Min(d => d.Bounds.Y);
        double right = displays.Max(d => d.Bounds.X + d.Bounds.Width), bottom = displays.Max(d => d.Bounds.Y + d.Bounds.Height);
        var scale = Math.Min((Map.ActualWidth - 12) / Math.Max(1, right - left), (Map.ActualHeight - 12) / Math.Max(1, bottom - top));
        double offsetX = (Map.ActualWidth - (right - left) * scale) / 2, offsetY = (Map.ActualHeight - (bottom - top) * scale) / 2;
        for (var i = 0; i < displays.Count; i++)
        {
            var display = displays[i];
            var on = chosen(display.Id);
            var tile = Ui.Surface(new Grid
            {
                Width = Math.Max(1, display.Bounds.Width * scale - 3), Height = Math.Max(1, display.Bounds.Height * scale - 3),
                CornerRadius = new CornerRadius(5), BorderThickness = new Thickness(2),
            }, on ? "TidyDisplayTileChosen" : "TidyDisplayTile");
            tile.Children.Add(new TextBlock
            {
                Text = (i + 1).ToString(CultureInfo.CurrentCulture), FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            });
            var id = display.Id;
            tile.Tapped += (_, _) => { if (selectable && enabled) toggle(id, !chosen(id)); };
            Canvas.SetLeft(tile, offsetX + (display.Bounds.X - left) * scale + 1.5);
            Canvas.SetTop(tile, offsetY + (display.Bounds.Y - top) * scale + 1.5);
            Map.Children.Add(tile);
        }
    }
}

/// <summary>Full-screen display settings for this connection (macOS FullscreenSettingsSheet; PARITY D02-D05).</summary>
internal static class FullscreenDialog
{
    private static readonly NativeFullscreenMode[] Modes = Enum.GetValues<NativeFullscreenMode>();

    private static string Title(NativeFullscreenMode mode) => Strings.Get(mode switch
    {
        NativeFullscreenMode.All => "settings.fullscreen.all.displays",
        NativeFullscreenMode.Selected => "settings.fullscreen.selected.displays",
        _ => "settings.fullscreen.current.display",
    });

    public static ContentDialog Create(NativeFullscreenDraft draft)
    {
        var updating = false;
        var start = new CheckBox { Content = Strings.Get("settings.fullscreen.start.in.full.screen") };
        AutomationProperties.SetAutomationId(start, "fullscreen.start");
        start.Click += (_, _) => { if (!updating) draft.StartsFullscreen = start.IsChecked == true; };
        var startSource = Ui.Caption("");
        var mode = SettingsLabels.Choice(Strings.Get("settings.fullscreen.use"), "fullscreen.mode", [.. Modes.Select(Title)]);
        mode.SelectionChanged += (_, _) => { if (!updating && mode.SelectedIndex >= 0) draft.Mode = Modes[mode.SelectedIndex]; };
        var modeSource = Ui.Caption("");
        var chooser = new DisplayChooser("fullscreen");
        var selectedSource = Ui.Caption("");
        var kept = Ui.Caption(Strings.Get("settings.fullscreen.disconnected.selections.are.kept.available.selected.displays.are.used.if.none.remain"));
        var issue = Ui.Text("", "fullscreen.issue");
        Ui.SetTone(issue, Tone.Warning);
        var restore = Ui.Button(Strings.Get("settings.fullscreen.restore.initial.settings"), (_, _) => draft.RestoreInitial(), "fullscreen.restore");
        var panel = Ui.Stack(8,
            Ui.Caption(Strings.Get("settings.fullscreen.choose.where.this.connection.appears.when.you.enter.full.screen.exit.full")),
            start, startSource, mode, modeSource, chooser.Map, chooser.List, selectedSource, kept,
            Ui.Caption(Strings.Get("settings.fullscreen.display.changes.apply.the.next.time.full.screen.opens.reconnecting.restores.full")),
            issue, restore);
        var dialog = Ui.Dialog(Strings.Get("settings.fullscreen.fullscreen.displays"), panel, 520);
        dialog.PrimaryButtonText = Strings.Get("action.apply");
        dialog.SecondaryButtonText = Strings.Get("settings.fullscreen.review.displays");
        dialog.CloseButtonText = Strings.Get("action.cancel");
        AutomationProperties.SetAutomationId(dialog, "fullscreen.dialog");

        void Toggle(string id, bool selected)
        {
            var next = new HashSet<string>(draft.SelectedDisplays, StringComparer.Ordinal);
            if (selected) next.Add(id); else next.Remove(id);
            draft.SelectedDisplays = next;
        }

        void Refresh()
        {
            updating = true;
            start.IsChecked = draft.StartsFullscreen;
            mode.SelectedIndex = Array.IndexOf(Modes, draft.Mode);
            updating = false;
            startSource.Text = SettingsLabels.ShortSource(draft.Source(NativeFullscreenOption.StartsFullscreen));
            modeSource.Text = SettingsLabels.ShortSource(draft.Source(NativeFullscreenOption.Mode));
            var chosen = draft.ChosenDisplays.Select(d => d.Id).ToHashSet(StringComparer.Ordinal);
            var selecting = draft.Mode == NativeFullscreenMode.Selected;
            chooser.Show(draft.Snapshot.Displays, chosen.Contains, selecting, draft.SelectedDisplays, draft.Missing, true, Toggle);
            selectedSource.Text = Strings.Format("settings.fullscreen.selected.source", SettingsLabels.ShortSource(draft.Source(NativeFullscreenOption.SelectedDisplays)));
            kept.Visibility = selecting && draft.Missing.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            issue.Text = draft.Changed ? Strings.Get("settings.fullscreen.the.connection.changed.close.and.reopen.this.sheet")
                : draft.Validation is { } text ? Strings.Resolve(text) : "";
            issue.Visibility = issue.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            dialog.IsSecondaryButtonEnabled = draft.NeedsReview;
            dialog.IsPrimaryButtonEnabled = draft.CanApply;
            dialog.DefaultButton = draft.CanApply ? ContentDialogButton.Primary : ContentDialogButton.Close;
        }
        draft.PropertyChanged += (_, _) => Refresh();
        Refresh();
        dialog.PrimaryButtonClick += (_, args) => { if (!draft.Apply()) args.Cancel = true; };
        dialog.SecondaryButtonClick += (_, args) => { args.Cancel = true; draft.ReviewDisplays(); };
        dialog.Closed += (_, _) => draft.Cancel();
        return dialog;
    }
}
