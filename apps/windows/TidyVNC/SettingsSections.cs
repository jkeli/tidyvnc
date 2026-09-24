// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TidyVNC.Native;
using TidyVNC.Native.Desktop;
using TidyVNC.Native.Storage;
using TidyVNC.Native.Trust;

namespace TidyVNC;

/// <summary>
/// The connection-settings sections shared by Settings and Saved profiles
/// (UX.md section 8; macOS *DefaultsFields views): each field is a settings
/// card showing the effective value and where it comes from, with a choice
/// to inherit. The editor decides what an unset value inherits: built-in
/// values for app defaults, app defaults for a profile.
/// </summary>
internal sealed class SettingsSections(INativeSettingsEditor editor, Func<Window?> owner, string prefix = "preferences")
{
    /// <summary>The section order and names (macOS PreferencesSettingsView.Section).</summary>
    public static readonly (string Tag, string Key)[] All =
    [
        ("clipboard", "settings.section.clipboard"), ("encoding", "settings.section.encoding"), ("input", "settings.section.input"),
        ("scaling", "settings.section.scaling"), ("security", "settings.section.security"), ("connection", "settings.section.connection"),
        ("remoteResize", "settings.section.remoteResize"), ("fullscreen", "settings.section.fullscreen"),
    ];

    private readonly List<Action> fields = [];
    private bool updating;

    /// <summary>Asks the host to show another section (Security and Certificate files link to each other).</summary>
    public event Action<string>? Navigate;

    public void Refresh()
    {
        updating = true;
        try { foreach (var field in fields) field(); }
        finally { updating = false; }
    }

    private static string? Empty(string value) => value.Length == 0 ? null : value;

    /// <summary>Where a value comes from, as the Settings description says it.</summary>
    private string SourceText(NativeOptionSource source) => source switch
    {
        NativeOptionSource.Compiled => Strings.Get("settings.defaults.uses.the.built.in.default"),
        NativeOptionSource.AppDefaults when editor.OverrideSource == NativeOptionSource.AppDefaults => Strings.Get("settings.defaults.app.default.override"),
        _ => SettingsLabels.ConnectionSource(source),
    };

    /// <summary>The inherit choice: *Built-in default (On)*, or *App default (On)* for a profile.</summary>
    private string DefaultLabel(string name, string value) => $"{SettingsLabels.ShortSource(editor.Inherited(name).Source)} ({value})";

    private string InheritanceLabel(string name) => Strings.Get(editor.Inherited(name).Source == NativeOptionSource.Compiled
        ? "settings.defaults.use.built.in.defaults" : "settings.inheritance.use.app.defaults");

    // ---- Sections -------------------------------------------------------------------

    /// <summary>A section's fields; the previous section's fields stop refreshing.</summary>
    public UIElement Build(string tag)
    {
        fields.Clear();
        var panel = new StackPanel { Spacing = 4 };
        AutomationProperties.SetAutomationId(panel, prefix + ".page." + tag);
        switch (tag)
        {
            case "clipboard":
                panel.Children.Add(Toggle("SendClipboard", "settings.defaults.send.clipboard.to.server", null, prefix + ".clipboard.send"));
                panel.Children.Add(Toggle("AcceptClipboard", "settings.defaults.receive.clipboard.from.server", null, prefix + ".clipboard.receive"));
                break;
            case "encoding":
                AddEncoding(panel);
                break;
            case "input":
                panel.Children.Add(Toggle("ViewOnly", "settings.input.view.only",
                    "settings.input.watch.the.remote.desktop.without.sending.keyboard.pointer.or.clipboard.input.enabling", prefix + ".input.viewOnly"));
                panel.Children.Add(Toggle("EmulateMiddleButton", "settings.input.emulate.middle.mouse.button",
                    "settings.input.press.the.left.and.right.mouse.buttons.together.for.a.middle.click", prefix + ".input.emulateMiddle"));
                panel.Children.Add(Toggle("FullscreenSystemKeys", "settings.input.capture.system.keys.in.full.screen",
                    "settings.input.keyboard.capture.requires.macos.accessibility.permission.and.stops.when.the.desktop.loses", prefix + ".input.systemKeys"));
                panel.Children.Add(Modifiers());
                panel.Children.Add(Cursor());
                break;
            case "scaling":
                panel.Children.Add(ScalingMode());
                panel.Children.Add(Choice("DesktopPixelUnits", "settings.scaling.size.units", "settings.scaling.fit.modes.use.the.available.window.space.this.unit.preference.is.kept",
                    prefix + ".scaling.units", ("Logical", Strings.Get("settings.scaling.logical.points")), ("Device", Strings.Get("settings.scaling.device.pixels"))));
                panel.Children.Add(Choice("ScalingQuality", "settings.scaling.scaling.quality", null, prefix + ".scaling.filter",
                    [.. Enum.GetValues<NativeScalingFilter>().Select(f => (f.Canonical(), SettingsLabels.Filter(f)))]));
                panel.Children.Add(Ui.Caption(Strings.Get("settings.scaling.scaling.changes.the.local.presentation.it.does.not.change.the.remote.desktop")));
                break;
            case "security":
                AddSecurity(panel);
                break;
            case "trust":
                AddTrustFiles(panel);
                break;
            case "connection":
                panel.Children.Add(Toggle("Shared", "settings.connection.share.server.with.other.viewers",
                    "settings.connection.requests.shared.access.when.connecting.with.sharing.off.the.server.may.disconnect", prefix + ".connection.shared"));
                panel.Children.Add(Toggle("ReconnectOnError", "settings.connection.offer.retry.after.connection.errors",
                    "settings.connection.shows.a.retry.action.for.recoverable.connection.errors.tidyvnc.reconnects.only.when", prefix + ".connection.retry"));
                panel.Children.Add(Ui.Caption(Strings.Get("settings.defaults.changes.apply.to.new.connection.windows")));
                break;
            case "remoteResize":
                panel.Children.Add(Toggle("RemoteResize", "settings.resize.resize.remote.desktop.with.window",
                    "settings.resize.follows.the.window.or.the.complete.fullscreen.display.arrangement.in.unscaled.mode", prefix + ".resize.enabled"));
                panel.Children.Add(Text("DesktopSize", "settings.resize.initial.size.in.remote.pixels",
                    "settings.resize.an.optional.widthxheight.such.as.1920x1080.is.requested.once.on.connection.when", prefix + ".resize.initialSize",
                    Strings.Get("settings.resize.use.the.server.s.size")));
                panel.Children.Add(Ui.Caption(Strings.Get("settings.resize.resizing.may.affect.other.viewers.windowed.and.initial.size.requests.use.one")));
                break;
            case "fullscreen":
                panel.Children.Add(Toggle("FullScreen", "settings.fullscreen.start.in.full.screen", null, prefix + ".fullscreen.start"));
                panel.Children.Add(Choice("FullScreenMode", "settings.fullscreen.use", null, prefix + ".fullscreen.mode",
                    ("Current", Strings.Get("settings.fullscreen.current.display")), ("All", Strings.Get("settings.fullscreen.all.displays")),
                    ("Selected", Strings.Get("settings.fullscreen.selected.displays"))));
                AddFullscreenDisplays(panel);
                break;
        }
        Refresh();
        return panel;
    }

    // ---- Field builders --------------------------------------------------------------

    private static string OnOff(string value) => Strings.Get(value == "on" ? "settings.input.on" : "settings.input.off");

    /// <summary>The description line: the effective value and where it comes from.</summary>
    private TextBlock SourceLine(string name, Func<string, string> label)
    {
        var line = Ui.Caption("");
        fields.Add(() => line.Text = Strings.Format("settings.inheritance.effective.value", label(editor.Effective(name))) + " · " + SourceText(editor.Source(name)));
        return line;
    }

    private static SettingsCard Card(string labelKey, string? helpKey, UIElement control, TextBlock? source, string id)
    {
        var description = new StackPanel { Spacing = 2 };
        if (helpKey is not null) description.Children.Add(Ui.Caption(Strings.Get(helpKey)));
        if (source is not null) description.Children.Add(source);
        var card = new SettingsCard { Header = Strings.Get(labelKey), Description = description, Content = control };
        AutomationProperties.SetAutomationId(card, id + ".card");
        if (control is FrameworkElement element) AutomationProperties.SetName(element, Strings.Get(labelKey));
        return card;
    }

    /// <summary>An inherit/on/off field (UX.md section 8: *Use default (On)*, *On*, *Off*).</summary>
    private SettingsCard Toggle(string name, string labelKey, string? helpKey, string id)
    {
        var builtIn = editor.Inherited(name).Value;
        var box = new ComboBox { MinWidth = 200 };
        box.Items.Add(DefaultLabel(name, OnOff(builtIn)));
        box.Items.Add(Strings.Get("settings.input.on"));
        box.Items.Add(Strings.Get("settings.input.off"));
        AutomationProperties.SetAutomationId(box, id);
        box.SelectionChanged += (_, _) =>
        {
            if (!updating && box.SelectedIndex >= 0) editor.Set(name, box.SelectedIndex switch { 1 => "on", 2 => "off", _ => null });
        };
        fields.Add(() => box.SelectedIndex = editor.Get(name) switch { "on" => 1, "off" => 2, _ => 0 });
        return Card(labelKey, helpKey, box, SourceLine(name, OnOff), id);
    }

    private SettingsCard Choice(string name, string labelKey, string? helpKey, string id, params (string Value, string Label)[] choices)
    {
        string Label(string value) => choices.FirstOrDefault(c => c.Value == value).Label ?? value;
        var box = new ComboBox { MinWidth = 200 };
        box.Items.Add(DefaultLabel(name, Label(editor.Inherited(name).Value)));
        foreach (var (_, label) in choices) box.Items.Add(label);
        AutomationProperties.SetAutomationId(box, id);
        box.SelectionChanged += (_, _) =>
        {
            if (!updating && box.SelectedIndex >= 0) editor.Set(name, box.SelectedIndex == 0 ? null : choices[box.SelectedIndex - 1].Value);
        };
        fields.Add(() => box.SelectedIndex = editor.Get(name) is { } value ? Array.FindIndex(choices, c => c.Value == value) + 1 : 0);
        return Card(labelKey, helpKey, box, SourceLine(name, Label), id);
    }

    /// <summary>A text field committed on Enter or when focus leaves; empty inherits.</summary>
    private SettingsCard Text(string name, string labelKey, string? helpKey, string id, string placeholder)
    {
        var box = new TextBox { MinWidth = 200, PlaceholderText = placeholder, IsSpellCheckEnabled = false };
        AutomationProperties.SetAutomationId(box, id);
        void Commit()
        {
            if (updating) return;
            var text = box.Text.Trim();
            if (text != (editor.Get(name) ?? "")) editor.Set(name, text.Length == 0 ? null : text);
        }
        box.LostFocus += (_, _) => Commit();
        box.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { Commit(); e.Handled = true; } };
        fields.Add(() => { if (box.FocusState == FocusState.Unfocused) box.Text = editor.Get(name) ?? ""; });
        return Card(labelKey, helpKey, box, SourceLine(name, v => v.Length == 0 ? placeholder : v), id);
    }

    private SettingsCard Modifiers()
    {
        const string name = "ShortcutModifiers";
        var @override = new CheckBox { Content = Strings.Get("settings.input.override.viewer.shortcut.modifiers") };
        AutomationProperties.SetAutomationId(@override, prefix + ".input.overrideModifiers");
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var boxes = new List<(NativeShortcutModifiers Bit, CheckBox Box)>();
        var index = 0;
        foreach (var (bit, key) in new[] { (NativeShortcutModifiers.Control, "settings.input.control"), (NativeShortcutModifiers.Shift, "settings.input.shift"),
                                           (NativeShortcutModifiers.Option, "settings.input.option"), (NativeShortcutModifiers.Command, "settings.input.command") })
        {
            var box = new CheckBox { Content = Strings.Get(key) };
            AutomationProperties.SetAutomationId(box, prefix + ".input.modifier." + (uint)bit);
            Grid.SetRow(box, index / 2); Grid.SetColumn(box, index % 2);
            grid.Children.Add(box);
            boxes.Add((bit, box));
            index++;
        }
        NativeShortcutModifiers Current() => NativeInputSettings.ParseModifiers(editor.Effective(name));
        void Write()
        {
            if (updating) return;
            if (@override.IsChecked != true) { editor.Set(name, null); return; }
            var mask = boxes.Where(b => b.Box.IsChecked == true).Aggregate(NativeShortcutModifiers.None, (m, b) => m | b.Bit);
            editor.Set(name, NativeInputSettings.Canonical(mask));
        }
        @override.Click += (_, _) => Write();
        foreach (var (_, box) in boxes) box.Click += (_, _) => Write();
        fields.Add(() =>
        {
            var overriding = editor.Get(name) is not null;
            @override.IsChecked = overriding;
            var current = Current();
            foreach (var (bit, box) in boxes) { box.IsChecked = current.HasFlag(bit); box.IsEnabled = overriding; }
        });
        var control = Ui.Stack(6, @override, grid);
        return Card("settings.input.viewer.shortcut.modifiers", "settings.input.press.these.modifiers.alone.to.release.keyboard.capture.add.g.to.capture",
            control, SourceLine(name, v => SettingsLabels.Modifiers(NativeInputSettings.ParseModifiers(v))), prefix + ".input.modifiers");
    }

    /// <summary>Cursor fallback: AlwaysCursor and CursorType together (hidden, dot, system pointer).</summary>
    private SettingsCard Cursor()
    {
        static NativeCursorFallback Of(string always, string type) =>
            always != "on" ? NativeCursorFallback.Hidden : type == "System" ? NativeCursorFallback.System : NativeCursorFallback.Dot;
        var box = new ComboBox { MinWidth = 200 };
        var builtIn = Of(editor.Inherited("AlwaysCursor").Value, editor.Inherited("CursorType").Value);
        box.Items.Add(DefaultLabel("AlwaysCursor", SettingsLabels.Cursor(builtIn)));
        var values = new[] { NativeCursorFallback.Hidden, NativeCursorFallback.Dot, NativeCursorFallback.System };
        foreach (var value in values) box.Items.Add(SettingsLabels.Cursor(value));
        AutomationProperties.SetAutomationId(box, prefix + ".input.cursor");
        box.SelectionChanged += (_, _) =>
        {
            if (updating || box.SelectedIndex < 0) return;
            if (box.SelectedIndex == 0) { editor.Set(("AlwaysCursor", null), ("CursorType", null)); return; }
            editor.Set(values[box.SelectedIndex - 1] switch
            {
                NativeCursorFallback.Hidden => [("AlwaysCursor", "off"), ("CursorType", null)],
                NativeCursorFallback.System => [("AlwaysCursor", "on"), ("CursorType", "System")],
                _ => [("AlwaysCursor", "on"), ("CursorType", "Dot")],
            });
        };
        var line = Ui.Caption("");
        fields.Add(() =>
        {
            var overriding = editor.Get("AlwaysCursor") is not null || editor.Get("CursorType") is not null;
            var effective = Of(editor.Effective("AlwaysCursor"), editor.Effective("CursorType"));
            box.SelectedIndex = overriding ? Array.IndexOf(values, effective) + 1 : 0;
            line.Text = Strings.Format("settings.inheritance.effective.value", SettingsLabels.Cursor(effective)) + " · " +
                SourceText(overriding ? editor.OverrideSource : editor.Inherited("AlwaysCursor").Source);
        });
        return Card("settings.input.cursor.fallback", "settings.input.used.when.the.server.supplies.no.visible.cursor.view.only.mode.always", box, line,
            prefix + ".input.cursorCard");
    }

    /// <summary>The scaling mode, with a value for the custom modes (macOS ScalingDefaultsFields).</summary>
    private SettingsCard ScalingMode()
    {
        const string name = "ScalingFactor";
        var modes = Enum.GetValues<NativeScalingMode>();
        static NativeScalingMode ModeOf(string canonical)
        {
            try { return NativeScaling.Parse(canonical).Mode; }
            catch (NativeError) { return NativeScalingMode.FixedRatio; }
        }
        var box = new ComboBox { MinWidth = 240 };
        box.Items.Add(DefaultLabel(name, SettingsLabels.Mode(ModeOf(editor.Inherited(name).Value))));
        foreach (var mode in modes) box.Items.Add(SettingsLabels.Mode(mode));
        AutomationProperties.SetAutomationId(box, prefix + ".scaling.mode");
        var value = new TextBox { IsSpellCheckEnabled = false, Header = Strings.Get("settings.scaling.scaling.value") };
        AutomationProperties.SetAutomationId(value, prefix + ".scaling.value");
        box.SelectionChanged += (_, _) =>
        {
            if (updating || box.SelectedIndex < 0) return;
            if (box.SelectedIndex == 0) { editor.Set(name, null); return; }
            var mode = modes[box.SelectedIndex - 1];
            // A custom mode starts from its example unless the current value already uses it.
            if (editor.Get(name) is { } current && ModeOf(current) == mode) return;
            editor.Set(name, mode.InitialText());
        };
        void Commit()
        {
            if (!updating && value.Text.Trim() is { Length: > 0 } text && text != editor.Get(name)) editor.Set(name, text);
        }
        value.LostFocus += (_, _) => Commit();
        value.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { Commit(); e.Handled = true; } };
        fields.Add(() =>
        {
            var current = editor.Get(name);
            var mode = ModeOf(editor.Effective(name));
            box.SelectedIndex = current is null ? 0 : Array.IndexOf(modes, mode) + 1;
            value.Visibility = current is not null && mode.Custom() ? Visibility.Visible : Visibility.Collapsed;
            if (value.FocusState == FocusState.Unfocused) value.Text = current ?? "";
        });
        var control = Ui.Stack(6, box, value);
        return Card("settings.scaling.mode", "settings.scaling.choose.a.mode.or.enter.dimensions.such.as.1920x1080.a.percentage.such", control,
            SourceLine(name, v => SettingsLabels.Mode(ModeOf(v))), prefix + ".scaling.modeCard");
    }

    private void AddEncoding(StackPanel panel)
    {
        var schema = NativeEncodingOptions.Schema().Where(s => NativeSettings.Allowed.Contains(s.Name)).ToList();
        var decoders = NativeEncodingOptions.Choices();
        var encoding = new EncodingFields((option, value) => editor.Set(schema.First(s => s.Id == option).Name, value), liveOnly: false);
        var reset = Ui.Button(Strings.Get("settings.defaults.use.built.in.defaults"),
            (_, _) => editor.Set([.. schema.Select(s => (s.Name, (string?)null))]), prefix + ".encoding.reset");
        var source = Ui.Caption("");
        fields.Add(() =>
        {
            var patch = schema.Where(s => editor.Get(s.Name) is not null).Select(s => new NativeEncodingAssignment(s.Name, editor.Get(s.Name)!)).ToList();
            var inherited = schema.Where(s => editor.Inherited(s.Name).Source != NativeOptionSource.Compiled)
                .Select(s => new NativeEncodingAssignment(s.Name, editor.Inherited(s.Name).Value)).ToList();
            using var baseline = new NativeEncodingOptions(inherited, NativeOptionSource.AppDefaults);
            using var options = baseline.Applying(patch, editor.OverrideSource);
            encoding.Refresh(schema.ToDictionary(s => s.Id, s => options.Value(s.Id)), schema, decoders, editor.CanEdit);
            source.Text = SourceText(patch.Count == 0 ? editor.Inherited(schema[0].Name).Source : editor.OverrideSource);
        });
        var card = new SettingsExpander
        {
            Header = Strings.Get("settings.section.encoding"), Description = source, Content = reset, IsExpanded = true,
            ItemsHeader = encoding,
        };
        AutomationProperties.SetAutomationId(card, prefix + ".encoding");
        panel.Children.Add(card);
    }

    private void AddSecurity(StackPanel panel)
    {
        var security = new SecurityFields(() => new NativeSecurityPatch(editor.Get("SecurityTypes"), editor.Get("GnuTLSPriority")),
            patch => editor.Set(("SecurityTypes", patch.Types), ("GnuTLSPriority", patch.TlsPriority)),
            Strings.Get("settings.defaults.changes.apply.to.new.connection.windows"));
        var inherited = new NativeSecuritySelection();
        var choices = NativeSecuritySelection.Choices();
        fields.Add(() =>
        {
            NativeSecuritySelection selection;
            try { selection = new NativeSecuritySelection(editor.Inherited("SecurityTypes").Source == NativeOptionSource.Compiled ? null : editor.Inherited("SecurityTypes").Value); }
            catch (NativeError) { selection = inherited; }
            security.Refresh(selection, choices, InheritanceLabel("SecurityTypes"), editor.Inherited("GnuTLSPriority").Value, editor.CanEdit);
        });
        var files = Ui.Button(Strings.Get("settings.defaults.certificate.files"), (_, _) => Navigate?.Invoke("trust"), "security.files");
        panel.Children.Add(security);
        panel.Children.Add(files);
    }

    private void AddTrustFiles(StackPanel panel)
    {
        var files = new TrustFileFields(() => new NativeTrustFiles(editor.Get("X509CA"), editor.Get("X509CRL")),
            value => editor.Set(("X509CA", value.CaFile), ("X509CRL", value.CrlFile)), owner,
            Strings.Get("settings.defaults.changes.apply.to.new.connection.windows"));
        fields.Add(() => files.Refresh(new NativeTrustFiles(Empty(editor.Inherited("X509CA").Value), Empty(editor.Inherited("X509CRL").Value)),
            InheritanceLabel("X509CA"), editor.CanEdit));
        panel.Children.Add(files);
        panel.Children.Add(Ui.Button(Strings.Get("settings.defaults.authentication.encryption"), (_, _) => Navigate?.Invoke("security"), prefix + ".security"));
    }

    private void AddFullscreenDisplays(StackPanel panel)
    {
        var chooser = new DisplayChooser(prefix + ".fullscreen");
        var help = Ui.Caption(Strings.Get("settings.fullscreen.selections.are.kept.when.displays.disconnect.if.none.are.available.the.current"));
        var warning = Ui.Caption("", Tone.Warning);
        var group = Ui.Stack(8, chooser.Map, chooser.List, help, warning);
        var card = Card("settings.fullscreen.selected.displays", null, group, null, prefix + ".fullscreen.displays");
        void Toggle(string id, bool selected)
        {
            var own = editor.Values.FullscreenDisplays;
            var next = (own.IsEmpty ? editor.InheritedFullscreenDisplays : own).ToHashSet(StringComparer.Ordinal);
            if (selected) next.Add(id); else next.Remove(id);
            editor.SetFullscreenDisplays(next);
        }
        fields.Add(() =>
        {
            var selecting = editor.Effective("FullScreenMode") == "Selected";
            card.Visibility = selecting ? Visibility.Visible : Visibility.Collapsed;
            if (!selecting) return;
            var displays = App.Current.Displays.Snapshot;
            var own = editor.Values.FullscreenDisplays;
            var selected = (own.IsEmpty ? editor.InheritedFullscreenDisplays : own).ToHashSet(StringComparer.Ordinal);
            var missing = selected.Where(id => displays.Find(id) is null).Order(StringComparer.Ordinal).ToList();
            chooser.Show(displays.Displays, selected.Contains, true, selected, missing, editor.CanEdit, Toggle);
            warning.Text = displays.Error is not null ? Strings.Get("settings.fullscreen.display.information.is.unavailable.saved.selections.are.kept")
                : selected.Count == 0 ? Strings.Get("settings.fullscreen.selected.displays.mode.requires.at.least.one.selected.display") : "";
            warning.Visibility = warning.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        });
        panel.Children.Add(card);
    }

}
