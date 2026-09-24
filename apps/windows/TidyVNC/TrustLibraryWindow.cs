// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TidyVNC.Native;
using TidyVNC.Native.Trust;

namespace TidyVNC;

/// <summary>
/// Saved server keys or saved certificate decisions (macOS TrustLibraryView; PARITY T07, UX.md
/// sections 2 and 4): the destination field with Ask again…, the saved entries with Forget for this
/// destination, and Reload. Forgetting also keeps older host-wide exceptions from applying to that
/// destination. Confirmations are flyouts on the buttons. Existing connections are unchanged.
/// </summary>
internal sealed partial class TrustLibraryWindow : Window
{
    private readonly NativeTrustLibrary model;
    private readonly TextBox destination = new() { IsSpellCheckEnabled = false };
    private readonly Button askAgain;
    private readonly StackPanel entries = new() { Spacing = 12 };
    private readonly TextBlock message = Ui.Text("", "trustLibrary.message", selectable: true);
    private readonly ProgressRing working = new() { IsActive = false, Width = 20, Height = 20 };
    private readonly Button reload;

    public TrustLibraryWindow(NativeTrustLibrary model)
    {
        this.model = model;
        var certificates = model.Kind == NativeTrustKind.Certificate;
        var title = Strings.Get(certificates ? "trust.library.ui.saved.certificate.decisions" : "trust.library.ui.saved.server.keys");
        Title = title;
        SystemBackdrop = new MicaBackdrop();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "tidyvnc.ico"));
        WindowSizes.Apply(AppWindow, 720, 560, 480, 420);

        var heading = Ui.Title(title, "trustLibrary.title");
        AutomationProperties.SetHeadingLevel(heading, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        var about = Ui.Caption(Strings.Get(certificates
            ? "trust.library.ui.exceptions.apply.to.the.displayed.destination.s.address.port.and.route.forget"
            : "trust.library.ui.rsa.aes.server.keys.are.saved.for.the.displayed.destination.s.address"));
        about.TextWrapping = TextWrapping.Wrap;

        destination.Header = Strings.Get("trust.library.ui.destination.host.display.or.host.port");
        AutomationProperties.SetAutomationId(destination, "trustLibrary.destination");
        destination.TextChanged += (_, _) => Refresh();
        askAgain = new Button { Content = Strings.Get("trust.library.ui.ask.again") };
        AutomationProperties.SetAutomationId(askAgain, "trustLibrary.askAgain");
        askAgain.Flyout = Confirmation(() => destination.Text, () => model.ForgetDestination(destination.Text.Trim()), "trustLibrary.askAgain.confirm");
        var askNote = Ui.Caption(Strings.Get(certificates
            ? "trust.library.ui.ask.again.also.suppresses.an.older.host.wide.exception.for.the.entered"
            : "trust.library.ui.ask.again.removes.any.saved.server.key.for.the.entered.destination"));
        askNote.TextWrapping = TextWrapping.Wrap;

        AutomationProperties.SetAutomationId(entries, "trustLibrary.entries");
        var list = new ScrollViewer { Content = entries, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        message.TextWrapping = TextWrapping.Wrap;
        reload = Ui.Button(Strings.Get("trust.library.ui.reload"), (_, _) => model.Reload(), "trustLibrary.reload");
        var footer = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, HorizontalAlignment = HorizontalAlignment.Right, Children = { working, reload } };

        var root = new Grid { Padding = new Thickness(24), RowSpacing = 12 };
        foreach (var height in new[] { GridLength.Auto, GridLength.Auto, GridLength.Auto, GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto })
            root.RowDefinitions.Add(new RowDefinition { Height = height });
        var destinationRow = new Grid { ColumnSpacing = 8 };
        destinationRow.ColumnDefinitions.Add(new ColumnDefinition());
        destinationRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        askAgain.VerticalAlignment = VerticalAlignment.Bottom;
        Grid.SetColumn(askAgain, 1);
        destinationRow.Children.Add(destination); destinationRow.Children.Add(askAgain);
        UIElement[] rows = [heading, about, destinationRow, askNote, list, message, footer];
        for (var i = 0; i < rows.Length; i++) { Grid.SetRow((FrameworkElement)rows[i], i); root.Children.Add(rows[i]); }
        Content = root;
        Strings.Localize(this);

        model.PropertyChanged += (_, _) => Refresh();
        var loaded = false;
        this.OnActivated((_, _) => { if (!loaded) { loaded = true; model.Reload(); } });
        this.OnClosed(() => _ = model.CloseAsync());
        Refresh();
    }

    /// <summary>A confirmation flyout on a button: the destination, and Forget saved key.</summary>
    private static Flyout Confirmation(Func<string> endpoint, Action confirm, string automationId)
    {
        var flyout = new Flyout();
        var question = Ui.Text(Strings.Get("trust.library.ui.forget.the.saved.key.for.this.destination"));
        question.TextWrapping = TextWrapping.Wrap;
        var target = Ui.Caption("");
        var forget = Ui.Button(Strings.Get("trust.library.ui.forget.saved.key"), (_, _) => { flyout.Hide(); confirm(); }, automationId, accent: true);
        flyout.Opening += (_, _) => target.Text = endpoint();
        flyout.Content = Ui.Stack(12, question, target, forget);
        return flyout;
    }

    private void Refresh()
    {
        var idle = !model.IsWorking && !model.NeedsReload && model.Snapshot is not null;
        askAgain.IsEnabled = idle && destination.Text.Trim().Length > 0 && NativeEndpoint.Issue(destination.Text.Trim()) is null;
        reload.IsEnabled = !model.IsWorking;
        working.IsActive = model.IsWorking;
        message.Text = model.Issue is { } issue ? Strings.Resolve(NativeTrustTexts.Storage(issue))
            : model.Forgot ? Strings.Get("trust.library.forgot.the.saved.key.this.destination.will.ask.again.when.identity.verification") : "";
        message.Visibility = message.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;

        entries.Children.Clear();
        if (model.Entries.Count == 0)
            entries.Children.Add(Ui.Caption(Strings.Get(model.Snapshot is null ? "trust.library.ui.decisions.have.not.loaded" : "trust.library.ui.no.saved.destination.decisions")));
        foreach (var entry in model.Entries)
        {
            var item = Ui.Stack(6, Ui.Text(entry.Scope.Endpoint, selectable: true));
            if (entry.Scope.RouteIdentity.Length > 0) item.Children.Add(Ui.Text(Strings.Format("trust.library.route", entry.Scope.RouteIdentity), selectable: true));
            if (entry.Fingerprint is { } fingerprint)
            {
                var saved = Ui.Text(Strings.Format(model.Kind == NativeTrustKind.Certificate ? "trust.library.saved.spki" : "trust.library.saved.serverKey", fingerprint), selectable: true);
                saved.FontFamily = new FontFamily("Cascadia Mono, Consolas");
                saved.TextWrapping = TextWrapping.Wrap;
                var forget = new Button { Content = Strings.Get("trust.library.ui.forget.for.this.destination"), IsEnabled = !model.IsWorking && !model.NeedsReload };
                AutomationProperties.SetAutomationId(forget, "trustLibrary.forget");
                var id = entry.Id;
                forget.Flyout = Confirmation(() => entry.Scope.Endpoint, () => model.Forget(id), "trustLibrary.forget.confirm");
                item.Children.Add(saved);
                item.Children.Add(forget);
            }
            else
            {
                item.Children.Add(Ui.Caption(Strings.Get(model.Kind == NativeTrustKind.Certificate
                    ? "trust.library.ui.ask.again.when.a.certificate.exception.is.needed.legacy.host.exceptions.are"
                    : "trust.library.ui.ask.again.before.trusting.the.server.key")));
            }
            entries.Children.Add(item);
            entries.Children.Add(new MenuFlyoutSeparator());
        }
    }
}
