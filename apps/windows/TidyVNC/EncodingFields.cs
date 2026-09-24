// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TidyVNC.Native;

namespace TidyVNC;

/// <summary>
/// Encoding fields shared by the Encoding dialog and the Settings window
/// (macOS EncodingSettingsFields; PARITY O01-O08). Every default, range and
/// decoder choice comes from the core schema; each field shows where its
/// value came from.
/// </summary>
internal sealed partial class EncodingFields : UserControl
{
    private readonly Action<NativeEncodingOption, string> set;
    private readonly bool liveOnly;
    private readonly CheckBox automatic, fullColor, customCompression, allowJpeg;
    private readonly ComboBox preferred, reducedColors;
    private readonly NumberBox compression, quality;
    private readonly Dictionary<NativeEncodingOption, TextBlock> sources = [];
    private IReadOnlyDictionary<NativeEncodingOption, NativeEncodingValue> values = new Dictionary<NativeEncodingOption, NativeEncodingValue>();
    private IReadOnlyList<NativeEncodingSchema> schema = [];
    private IReadOnlyList<NativeEncodingChoice> choices = [];
    private bool updating;

    public EncodingFields(Action<NativeEncodingOption, string> set, bool liveOnly)
    {
        this.set = set;
        this.liveOnly = liveOnly;
        var grid = new Grid { ColumnSpacing = 12, RowSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });

        automatic = Check("settings.encoding.choose.encoding.and.quality.automatically", NativeEncodingOption.AutoSelect, "preferences.encoding.autoSelect");
        preferred = new ComboBox { Header = Strings.Get("settings.encoding.preferred.encoding"), MinWidth = 220 };
        AutomationProperties.SetAutomationId(preferred, "preferences.encoding.preferred");
        preferred.SelectionChanged += (_, _) =>
        {
            if (!updating && preferred.SelectedIndex >= 0 && preferred.SelectedIndex < choices.Count)
                set(NativeEncodingOption.Preferred, choices[preferred.SelectedIndex].Name);
        };
        fullColor = Check("settings.encoding.full.color", NativeEncodingOption.FullColor, "preferences.encoding.fullColor");
        reducedColors = new ComboBox { Header = Strings.Get("settings.encoding.reduced.colors"), MinWidth = 220 };
        AutomationProperties.SetAutomationId(reducedColors, "preferences.encoding.lowColorLevel");
        reducedColors.SelectionChanged += (_, _) =>
        {
            if (!updating && reducedColors.SelectedItem is ComboBoxItem { Tag: string level }) set(NativeEncodingOption.LowColorLevel, level);
        };
        customCompression = Check("settings.encoding.use.custom.compression", NativeEncodingOption.CustomCompression, "preferences.encoding.customCompression");
        compression = Number("settings.encoding.compression", NativeEncodingOption.Compression, "preferences.encoding.compression");
        allowJpeg = Check("settings.encoding.allow.jpeg", NativeEncodingOption.NoJpeg, "preferences.encoding.allowJpeg", inverted: true);
        quality = Number("settings.encoding.jpeg.quality", NativeEncodingOption.Quality, "preferences.encoding.quality");

        var row = 0;
        void Add(FrameworkElement control, NativeEncodingOption option)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(control, row);
            grid.Children.Add(control);
            var source = Ui.Caption("");
            source.VerticalAlignment = VerticalAlignment.Center;
            source.TextAlignment = TextAlignment.Right;
            Grid.SetRow(source, row); Grid.SetColumn(source, 1);
            grid.Children.Add(source);
            sources[option] = source;
            row++;
        }
        Add(automatic, NativeEncodingOption.AutoSelect);
        Add(preferred, NativeEncodingOption.Preferred);
        Add(fullColor, NativeEncodingOption.FullColor);
        Add(reducedColors, NativeEncodingOption.LowColorLevel);
        Add(customCompression, NativeEncodingOption.CustomCompression);
        Add(compression, NativeEncodingOption.Compression);
        Add(allowJpeg, NativeEncodingOption.NoJpeg);
        Add(quality, NativeEncodingOption.Quality);
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var help = Ui.Caption(Strings.Get("settings.encoding.automatic.selection.can.adjust.the.encoding.color.depth.and.jpeg.quality.during"));
        Grid.SetRow(help, row); Grid.SetColumnSpan(help, 2);
        grid.Children.Add(help);
        Content = grid;
    }

    private CheckBox Check(string key, NativeEncodingOption option, string id, bool inverted = false)
    {
        var box = new CheckBox { Content = Strings.Get(key) };
        AutomationProperties.SetAutomationId(box, id);
        box.Click += (_, _) => { if (!updating) set(option, (box.IsChecked == true) != inverted ? "on" : "off"); };
        return box;
    }

    private NumberBox Number(string key, NativeEncodingOption option, string id)
    {
        var box = new NumberBox { Header = Strings.Get(key), SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline, SmallChange = 1, LargeChange = 1, MinWidth = 160 };
        AutomationProperties.SetAutomationId(box, id);
        box.ValueChanged += (_, e) =>
        {
            if (!updating && !double.IsNaN(e.NewValue)) set(option, ((int)Math.Round(e.NewValue)).ToString(CultureInfo.InvariantCulture));
        };
        return box;
    }

    private static string Source(NativeOptionSource? source) => Strings.Get(source switch
    {
        NativeOptionSource.Compiled => "settings.encoding.built.in",
        NativeOptionSource.AppDefaults => "settings.encoding.app.default",
        NativeOptionSource.Profile => "settings.encoding.profile",
        NativeOptionSource.Session => "settings.encoding.connection.override",
        NativeOptionSource.Document => "settings.encoding.connection.file",
        NativeOptionSource.CommandLine => "settings.encoding.command.line",
        _ => "settings.encoding.unavailable",
    });

    private static string ColorLabel(int value) => value switch
    {
        0 => Strings.Get("settings.encoding.8.colors"),
        1 => Strings.Get("settings.encoding.64.colors"),
        2 => Strings.Get("settings.encoding.256.colors"),
        _ => value.ToString(CultureInfo.CurrentCulture),
    };

    private bool ReadOnly(NativeEncodingOption option) => liveOnly && schema.FirstOrDefault(s => s.Id == option)?.Live != true;

    public void Refresh(IReadOnlyDictionary<NativeEncodingOption, NativeEncodingValue> current, IReadOnlyList<NativeEncodingSchema> fields,
                        IReadOnlyList<NativeEncodingChoice> decoders, bool enabled)
    {
        updating = true;
        try
        {
            values = current; schema = fields;
            string Value(NativeEncodingOption option) => values.TryGetValue(option, out var v) ? v.Value : "";
            var auto = Value(NativeEncodingOption.AutoSelect) == "on";
            automatic.IsChecked = auto;
            if (!ReferenceEquals(choices, decoders) || preferred.Items.Count != decoders.Count)
            {
                choices = decoders;
                preferred.Items.Clear();
                foreach (var choice in decoders)
                    preferred.Items.Add(new ComboBoxItem
                    {
                        Content = choice.Available ? choice.Name : Strings.Format("settings.encoding.choice.unavailable", choice.Name),
                        IsEnabled = choice.Available,
                    });
            }
            preferred.SelectedIndex = choices.ToList().FindIndex(c => c.Name == Value(NativeEncodingOption.Preferred));
            fullColor.IsChecked = Value(NativeEncodingOption.FullColor) == "on";
            if (schema.FirstOrDefault(s => s.Id == NativeEncodingOption.LowColorLevel) is { } levels && reducedColors.Items.Count != levels.Maximum - levels.Minimum + 1)
            {
                reducedColors.Items.Clear();
                for (var level = levels.Minimum; level <= levels.Maximum; level++)
                    reducedColors.Items.Add(new ComboBoxItem { Content = ColorLabel(level), Tag = level.ToString(CultureInfo.InvariantCulture) });
            }
            reducedColors.SelectedItem = reducedColors.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == Value(NativeEncodingOption.LowColorLevel));
            customCompression.IsChecked = Value(NativeEncodingOption.CustomCompression) == "on";
            allowJpeg.IsChecked = Value(NativeEncodingOption.NoJpeg) != "on";
            foreach (var (box, option) in new[] { (compression, NativeEncodingOption.Compression), (quality, NativeEncodingOption.Quality) })
            {
                if (schema.FirstOrDefault(s => s.Id == option) is { } range) { box.Minimum = range.Minimum; box.Maximum = range.Maximum; }
                box.Value = int.TryParse(Value(option), NumberStyles.Integer, CultureInfo.InvariantCulture, out var number) ? number : double.NaN;
            }
            automatic.IsEnabled = enabled && !ReadOnly(NativeEncodingOption.AutoSelect);
            preferred.IsEnabled = enabled && !auto && !ReadOnly(NativeEncodingOption.Preferred);
            fullColor.IsEnabled = enabled && !auto && !ReadOnly(NativeEncodingOption.FullColor);
            reducedColors.IsEnabled = enabled && !auto && fullColor.IsChecked != true && !ReadOnly(NativeEncodingOption.LowColorLevel);
            customCompression.IsEnabled = enabled && !ReadOnly(NativeEncodingOption.CustomCompression);
            compression.IsEnabled = enabled && customCompression.IsChecked == true && !ReadOnly(NativeEncodingOption.Compression);
            allowJpeg.IsEnabled = enabled && !ReadOnly(NativeEncodingOption.NoJpeg);
            quality.IsEnabled = enabled && !auto && allowJpeg.IsChecked == true && !ReadOnly(NativeEncodingOption.Quality);
            foreach (var (option, text) in sources) text.Text = Source(values.TryGetValue(option, out var v) ? v.Source : null);
        }
        finally { updating = false; }
    }
}

/// <summary>The per-connection encoding dialog (macOS SessionEncodingSheet; PARITY O05-O08).</summary>
internal static class EncodingDialog
{
    public static NativeText Message(NativeEncodingDraftError error) => new(error switch
    {
        NativeEncodingDraftError.Unavailable => "settings.encoding.session.encoding.settings.are.available.while.this.connection.is.connected",
        NativeEncodingDraftError.InvalidValue => "settings.encoding.session.the.encoding.value.is.invalid.check.the.value.and.try.again",
        NativeEncodingDraftError.UnsupportedValue => "settings.encoding.session.this.encoding.is.unavailable.in.this.build.choose.an.available.encoding",
        NativeEncodingDraftError.Changed => "settings.encoding.session.the.connection.or.its.settings.changed.reload.before.applying.your.edits",
        NativeEncodingDraftError.Cancelled => "settings.encoding.session.apply.was.cancelled.some.changes.may.already.have.taken.effect.reload.to",
        _ => "settings.encoding.session.the.change.could.not.be.confirmed.reload.to.check.the.current.settings",
    });

    public static ContentDialog Create(NativeSessionEncodingDraft draft)
    {
        var fields = new EncodingFields(draft.SetEncoding, liveOnly: true);
        var error = Ui.Text("", "encoding.error");
        error.Foreground = Ui.Error;
        var reload = Ui.Button("", (_, _) => draft.Reload(), "encoding.reload");
        var applied = Ui.Caption(Strings.Get("settings.encoding.session.settings.applied.to.this.connection.image.quality.can.change.as.updates.arrive"));
        var busy = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        busy.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        busy.Children.Add(Ui.Caption(Strings.Get("settings.encoding.session.applying.encoding.settings")));
        var cancelApply = Ui.Button(Strings.Get("settings.encoding.session.cancel.apply"), (_, _) => draft.CancelApply(), "encoding.cancelApply");
        busy.Children.Add(cancelApply);
        var group = new Expander { Header = Strings.Get("settings.section.encoding"), Content = fields, IsExpanded = true, HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var panel = Ui.Stack(16,
            Ui.Caption(Strings.Get("settings.encoding.session.changes.apply.only.to.this.connection.and.are.kept.when.it.reconnects")),
            group, error, reload, applied, busy);
        var dialog = Ui.Dialog(Strings.Get("settings.encoding.session.connection.encoding"), panel, 560);
        dialog.PrimaryButtonText = Strings.Get("action.apply");
        AutomationProperties.SetAutomationId(dialog, "encoding.dialog");

        void Refresh()
        {
            fields.Refresh(draft.Values, draft.Schema, draft.Choices, !draft.IsBusy && !draft.NeedsReload && draft.IsAvailable);
            error.Text = draft.Error is { } value ? Strings.Resolve(Message(value)) : "";
            error.Visibility = draft.Error is null ? Visibility.Collapsed : Visibility.Visible;
            reload.Content = Strings.Get(draft.HasChanges ? "action.discard.edits.reload" : "settings.encoding.session.reload.current.settings");
            reload.Visibility = draft.NeedsReload ? Visibility.Visible : Visibility.Collapsed;
            reload.IsEnabled = draft.CanReload;
            applied.Visibility = draft.DidApply ? Visibility.Visible : Visibility.Collapsed;
            busy.Visibility = draft.IsBusy ? Visibility.Visible : Visibility.Collapsed;
            dialog.IsPrimaryButtonEnabled = draft.CanApply;
            dialog.CloseButtonText = Strings.Get(draft.HasChanges ? "action.cancel" : "action.done");
            // Apply is the default only while the draft can be applied (UX.md section 5).
            dialog.DefaultButton = draft.CanApply ? ContentDialogButton.Primary : ContentDialogButton.Close;
        }
        draft.PropertyChanged += (_, _) => Refresh();
        Refresh();
        dialog.PrimaryButtonClick += (_, args) => { args.Cancel = true; draft.Apply(); };
        dialog.Closing += (sender, args) =>
        {
            // A running apply is cancelled explicitly first, never abandoned by closing.
            if (draft.IsBusy && !DialogPresenter.IsWithdrawn(sender)) args.Cancel = true;
            else draft.CancelEdits();
        };
        return dialog;
    }
}
