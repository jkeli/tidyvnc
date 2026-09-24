// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TidyVNC.Native;

namespace TidyVNC;

/// <summary>Text for connection values shared by the information dialog and the statistics overlay.</summary>
internal static class InformationTexts
{
    public static string Number(ulong value) => value.ToString("N0", CultureInfo.CurrentCulture);

    public static string Size(uint width, uint height) => Strings.Format("information.desktop.size", Number(width), Number(height));

    public static string LastEncoding(NativeConnectionInformation info) =>
        info.LastEncoding < 0 ? Strings.Get("information.not.received") : info.LastEncodingName;

    public static string Speed(NativeConnectionInformation info) =>
        info.Frames == 0 ? Strings.Get("information.not.sampled") : Strings.Format("information.speed", Number(info.BitsPerSecond / 1000));

    public static string Protocol(NativeConnectionInformation info) => $"RFB {info.ProtocolMajor}.{info.ProtocolMinor}";

    public static string OnOff(bool value) => Strings.Get(value ? "settings.input.on" : "settings.input.off");

    /// <summary>Label and value rows in a two-column grid (the macOS Grid).</summary>
    public static Grid Rows(IEnumerable<(string Label, string Value)> rows, double spacing, bool selectable)
    {
        var grid = new Grid { ColumnSpacing = 16, RowSpacing = spacing };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        var index = 0;
        foreach (var (label, value) in rows)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var name = Ui.Caption(label);
            var text = new TextBlock { Text = value, IsTextSelectionEnabled = selectable, TextWrapping = TextWrapping.Wrap, MaxLines = 3 };
            ToolTipService.SetToolTip(text, value);
            Grid.SetRow(name, index); Grid.SetRow(text, index); Grid.SetColumn(text, 1);
            grid.Children.Add(name); grid.Children.Add(text);
            index++;
        }
        return grid;
    }
}

/// <summary>
/// Connection statistics over a desktop view (macOS
/// NativeConnectionStatisticsOverlay; PARITY Q03-Q04): values only, never
/// hit-testable, on the window and on every full-screen surface.
/// </summary>
internal sealed partial class StatisticsOverlay : UserControl
{
    private readonly ContentControl rows = new();

    public StatisticsOverlay()
    {
        IsHitTestVisible = false;
        HorizontalAlignment = HorizontalAlignment.Right;
        VerticalAlignment = VerticalAlignment.Top;
        Margin = new Thickness(12);
        Visibility = Visibility.Collapsed;
        AutomationProperties.SetAutomationId(this, "connection.statistics");
        AutomationProperties.SetName(this, Strings.Get("information.connection.statistics"));
        AutomationProperties.SetHelpText(this, Strings.Get("information.use.show.connection.statistics.in.the.connection.menu.to.hide.these.statistics"));
        Content = new Border
        {
            Padding = new Thickness(12), CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1),
            Background = Ui.Brush("AcrylicInAppFillColorDefaultBrush"), BorderBrush = Ui.Brush("SurfaceStrokeColorDefaultBrush"),
            Child = Ui.Stack(8, Ui.Heading(Strings.Get("information.connection.statistics")), rows),
        };
    }

    /// <summary>Shows the latest values, or hides the overlay with null.</summary>
    public void Show(NativeConnectionInformation? info)
    {
        Visibility = info is null ? Visibility.Collapsed : Visibility.Visible;
        if (info is null) return;
        rows.Content = InformationTexts.Rows(
        [
            (Strings.Get("information.desktop"), InformationTexts.Size(info.Width, info.Height)),
            (Strings.Get("information.frames.received"), InformationTexts.Number(info.Frames)),
            (Strings.Get("settings.section.encoding"), InformationTexts.LastEncoding(info)),
            (Strings.Get("information.line.speed.estimate"), InformationTexts.Speed(info)),
            (Strings.Get("information.protocol"), InformationTexts.Protocol(info)),
            (Strings.Get("information.security.method"), info.SecurityName),
        ], 5, selectable: false);
    }
}

/// <summary>The editor-slot request for Connection information (it is read-only).</summary>
internal sealed record ConnectionInformationRequest(Guid Id);

/// <summary>
/// Connection information (macOS ConnectionInformationSheet; PARITY Q01-Q02):
/// live values while open, and Copy diagnostics, which copies a redacted
/// summary as local text (never marked as remote clipboard content).
/// </summary>
internal static class ConnectionInformationDialog
{
    public static ContentDialog Create(NativeSession session, string endpoint)
    {
        var body = new ContentControl();
        var copied = Ui.Caption("");
        var dialog = Ui.Dialog(Strings.Get("information.connection.information"), Ui.Stack(12, body, copied), 520);
        dialog.SecondaryButtonText = Strings.Get("information.copy.diagnostics");
        dialog.CloseButtonText = Strings.Get("action.done");
        dialog.DefaultButton = ContentDialogButton.Close;
        AutomationProperties.SetAutomationId(dialog, "information.dialog");

        void Refresh()
        {
            var snapshot = session.Snapshot;
            var info = session.Information;
            var rows = new List<(string, string)> { (Strings.Get("information.server"), endpoint) };
            if (info is not null)
            {
                rows.Add((Strings.Get("information.desktop.name"), info.DesktopName.Length == 0 ? Strings.Get("information.unnamed")
                    : info.DesktopName + (info.NameTruncated ? "…" : "")));
                rows.Add((Strings.Get("information.protocol"), InformationTexts.Protocol(info)));
                rows.Add((Strings.Get("information.security.method"), info.SecurityName));
                rows.Add((Strings.Get("information.pixel.format"), info.PixelFormat));
                rows.Add((Strings.Get("information.requested.encoding"), info.RequestedEncodingName));
                rows.Add((Strings.Get("information.last.used.encoding"), InformationTexts.LastEncoding(info)));
                rows.Add((Strings.Get("information.line.speed.estimate"), InformationTexts.Speed(info)));
            }
            rows.Add((Strings.Get("information.desktop.size.title"), InformationTexts.Size(snapshot.Width, snapshot.Height)));
            rows.Add((Strings.Get("information.frames.received"), InformationTexts.Number(snapshot.Frames)));
            rows.Add((Strings.Get("information.remote.resize"), Strings.Get(snapshot.SupportsResize
                ? snapshot.ResizePending ? "information.requested" : "information.available" : "settings.encoding.unavailable")));
            rows.Add((Strings.Get("settings.section.input"), Strings.Get(session.IsViewOnly ? "settings.input.view.only" : "information.keyboard.and.pointer")));
            rows.Add((Strings.Get("information.middle.button.emulation"), InformationTexts.OnOff(session.EmulatesMiddleButton)));
            rows.Add((Strings.Get("information.send.clipboard"), InformationTexts.OnOff(session.ClipboardSendEnabled)));
            rows.Add((Strings.Get("information.receive.clipboard"), InformationTexts.OnOff(session.ClipboardReceiveEnabled)));
            body.Content = InformationTexts.Rows(rows, 10, selectable: true);
            dialog.IsSecondaryButtonEnabled = info is not null;
        }
        void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs e) => Refresh();
        session.PropertyChanged += Changed;
        dialog.Closed += (_, _) => session.PropertyChanged -= Changed;
        dialog.SecondaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (session.Information is not { } info) return;
            var deferral = args.GetDeferral();
            try
            {
                await App.Current.Clipboard.CopyLocalAsync(info.RedactedDiagnostics);
                copied.Text = Strings.Get("information.copies.connection.details.without.the.server.address.or.desktop.name");
            }
            catch (Exception error) when (error is NativeError or System.Runtime.InteropServices.COMException or InvalidOperationException)
            {
                copied.Text = Strings.Get("app.clipboard.settings.could.not.be.changed.try.again");
            }
            finally { deferral.Complete(); }
        };
        ToolTipService.SetToolTip(dialog, Strings.Get("information.copies.connection.details.without.the.server.address.or.desktop.name"));
        Refresh();
        return dialog;
    }
}
