// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TidyVNC.Native;
using TidyVNC.Native.Storage;

namespace TidyVNC;

/// <summary>
/// Saved profiles (macOS ProfileLibraryView; PARITY P07, P08, C10): the
/// saved profiles on the left, the selected profile's address, gateway and
/// settings on the right. Settings use the same sections as Settings and
/// inherit the app defaults. Open connection creates a new connection window
/// for the profile; the user connects when ready.
/// </summary>
internal sealed partial class ProfilesWindow : Window
{
    private readonly NativeProfileLibrary library;
    private readonly SettingsSections sections;
    private readonly ListView list = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBlock empty = Ui.Caption("");
    private readonly Button create;
    private readonly TextBox name = new() { Header = Strings.Get("profiles.profile.name") };
    private readonly TextBox endpoint = new() { Header = Strings.Get("profiles.server.address"), IsSpellCheckEnabled = false };
    private readonly TextBlock endpointIssue = Ui.Caption("", Ui.Error);
    private readonly TextBox gateway = new() { Header = Strings.Get("profiles.ssh.gateway.optional"), IsSpellCheckEnabled = false };
    private readonly TextBlock gatewayIssue = Ui.Caption("", Ui.Error);
    private readonly TextBlock gatewayHelp = Ui.Caption(Strings.Get("profiles.ssh.reads.supported.settings.from.ssh.config.commands.and.proxy.hops.are"));
    private readonly SelectorBar sectionBar = new();
    private readonly ContentControl sectionPage = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly StackPanel editor;
    private readonly TextBlock choose = Ui.Caption(Strings.Get("profiles.choose.a.profile.or.create.a.new.one"));
    private readonly TextBlock error = Ui.Text("", "profiles.error");
    private readonly StackPanel busy = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly Button reload, delete, cancel, save, open;
    private bool updating;

    public ProfilesWindow(NativeProfileLibrary library)
    {
        this.library = library;
        sections = new SettingsSections(library, () => this, "profiles");
        sections.Navigate += tag => sectionBar.SelectedItem = sectionBar.Items.First(i => (string)i.Tag == tag);
        Title = Strings.Get("profiles.saved.profiles");
        SystemBackdrop = new MicaBackdrop();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "tidyvnc.ico"));
        WindowSizes.Apply(AppWindow, 960, 680, 640, 480);

        // Profiles.
        AutomationProperties.SetAutomationId(list, "profiles.list");
        AutomationProperties.SetName(list, Strings.Get("profiles.saved.profiles"));
        list.SelectionChanged += (_, _) =>
        {
            if (!updating && list.SelectedItem is ListViewItem { Tag: Guid id }) library.Select(id);
        };
        create = Ui.Button(Strings.Get("profiles.new.profile"), (_, _) => library.NewProfile(), "profiles.new");
        var left = new Grid { RowSpacing = 8, Width = 240 };
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.RowDefinitions.Add(new RowDefinition());
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(list, 1); Grid.SetRow(create, 2);
        left.Children.Add(empty); left.Children.Add(list); left.Children.Add(create);

        // Editor.
        AutomationProperties.SetAutomationId(name, "profiles.name");
        AutomationProperties.SetAutomationId(endpoint, "profiles.endpoint");
        AutomationProperties.SetAutomationId(gateway, "profiles.sshGateway");
        ToolTipService.SetToolTip(endpoint, Strings.Get("profiles.enter.host.display.host.port.ipv6.display.or.a.unix.socket.path"));
        ToolTipService.SetToolTip(gateway, Strings.Get("profiles.enter.user.host.or.ssh.user.host.port.leave.empty.for.a"));
        name.TextChanged += (_, _) => { if (!updating) library.SetName(name.Text); };
        endpoint.TextChanged += (_, _) => { if (!updating) library.SetEndpoint(endpoint.Text); };
        gateway.TextChanged += (_, _) => { if (!updating && library.CanEdit) library.GatewayText = gateway.Text; };
        foreach (var (tag, key) in SettingsSections.All.SelectMany(s => s.Tag == "security"
                     ? new[] { s, ("trust", "settings.section.certificateFiles") } : [s]))
        {
            var item = new SelectorBarItem { Text = Strings.Get(key), Tag = tag };
            AutomationProperties.SetAutomationId(item, "profiles.section." + tag);
            sectionBar.Items.Add(item);
        }
        sectionBar.SelectionChanged += (_, _) =>
        {
            if (sectionBar.SelectedItem is { Tag: string tag }) sectionPage.Content = sections.Build(tag);
        };
        editor = Ui.Stack(8, name, endpoint, endpointIssue, gateway, gatewayIssue, gatewayHelp,
            Ui.Caption(Strings.Get("profiles.settings.without.a.profile.override.use.app.defaults.for.each.new.connection")), sectionBar, sectionPage);
        var right = new ScrollViewer { Content = new Grid { Children = { editor, choose } }, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                                       HorizontalScrollMode = ScrollMode.Disabled };

        // Footer.
        error.Foreground = Ui.Error;
        busy.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        busy.Children.Add(Ui.Caption(Strings.Get("profiles.updating.profiles")));
        reload = Ui.Button("", (_, _) => library.Reload(), "profiles.reload");
        delete = Ui.Button(Strings.Get("profiles.delete"), (_, _) => { }, "profiles.delete");
        // P07: a flyout on the button, not a second dialog.
        var confirm = Ui.Button(Strings.Get("profiles.delete.profile"), (_, _) => { }, "profiles.confirmDelete");
        var flyout = new Flyout
        {
            Content = Ui.Stack(8, Ui.Text(Strings.Get("profiles.delete.this.saved.profile")),
                Ui.Caption(Strings.Get("profiles.existing.connections.recent.history.and.stored.credentials.are.kept")), confirm),
        };
        confirm.Click += (_, _) => { flyout.Hide(); library.DeleteSelected(); };
        delete.Flyout = flyout;
        cancel = Ui.Button(Strings.Get("settings.defaults.cancel.edits"), (_, _) => library.CancelEdits(), "profiles.cancel");
        cancel.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = Windows.System.VirtualKey.Escape });
        save = Ui.Button(Strings.Get("profiles.save"), (_, _) => library.Save(), "profiles.save", accent: true);
        open = Ui.Button(Strings.Get("profiles.open.connection"), (_, _) => Open(), "profiles.open");
        var buttons = new Grid { ColumnSpacing = 8 };
        for (var i = 0; i < 6; i++) buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = i == 2 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
        foreach (var (button, column) in new[] { (reload, 0), (delete, 1), (cancel, 3), (save, 4), (open, 5) })
        {
            Grid.SetColumn(button, column);
            buttons.Children.Add(button);
        }

        var header = Ui.Stack(4, Ui.Title(Strings.Get("profiles.saved.profiles"), "profiles.title"),
            Ui.Caption(Strings.Get("profiles.save.an.address.and.its.connection.settings.open.creates.a.new.connection")));
        var middle = new Grid { ColumnSpacing = 16 };
        middle.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        middle.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        middle.ColumnDefinitions.Add(new ColumnDefinition());
        var divider = new Border { Width = 1, Background = Ui.Brush("DividerStrokeColorDefaultBrush") };
        Grid.SetColumn(divider, 1); Grid.SetColumn(right, 2);
        middle.Children.Add(left); middle.Children.Add(divider); middle.Children.Add(right);
        var root = new Grid { Padding = new Thickness(24, 16, 24, 16), RowSpacing = 12 };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition());
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(middle, 1); Grid.SetRow(error, 2); Grid.SetRow(busy, 3); Grid.SetRow(buttons, 4);
        root.Children.Add(header); root.Children.Add(middle); root.Children.Add(error); root.Children.Add(busy); root.Children.Add(buttons);
        Content = root;

        library.PropertyChanged += (_, _) => Refresh();
        Activated += (_, e) => { if (e.WindowActivationState != WindowActivationState.Deactivated) library.RefreshIfClean(); };
        Closed += (_, _) => library.Stop();
        sectionBar.SelectedItem = sectionBar.Items[0];
        Refresh();
    }

    /// <summary>The Saved profiles text for a store problem (macOS profileMessage).</summary>
    private static string Message(NativeStorageError? failure, NativePreferencesProblem? problem) => problem switch
    {
        NativePreferencesProblem.InvalidPriority => Strings.Get("profiles.the.tls.priority.expression.is.invalid.correct.it.or.use.the.library"),
        NativePreferencesProblem.InvalidValue => Strings.Get("profiles.the.profile.could.not.be.saved.check.the.name.address.and.settings"),
        _ => failure switch
        {
            null => "",
            NativeStorageError.FutureSchema or NativeStorageError.UnsupportedFields =>
                Strings.Get("profiles.saved.profiles.require.a.newer.version.of.tidyvnc.existing.data.has.been"),
            NativeStorageError.Denied => Strings.Get("profiles.access.to.saved.profiles.was.denied.check.the.native.storage.folder.s"),
            NativeStorageError.Conflict => Strings.Get("profiles.saved.profiles.or.recent.connections.changed.elsewhere.reload.before.saving.or.deleting"),
            NativeStorageError.NotFound => Strings.Get("profiles.this.saved.profile.is.no.longer.available.choose.another.profile.or.create"),
            NativeStorageError.Invalid or NativeStorageError.TooLarge or NativeStorageError.ResourceLimit =>
                Strings.Get("profiles.the.profile.could.not.be.saved.check.the.name.address.and.settings"),
            NativeStorageError.Corrupt => Strings.Get("profiles.saved.profiles.could.not.be.read.existing.data.has.been.preserved"),
            NativeStorageError.Cancelled or NativeStorageError.IOFailure => Strings.Get("profiles.the.profile.operation.could.not.be.confirmed.reload.to.check.the.saved"),
            _ => Strings.Get("profiles.saved.profiles.are.unavailable.try.reloading"),
        },
    };

    private void Refresh()
    {
        updating = true;
        try
        {
            // The list, keeping the selection on the draft's profile.
            var items = library.Profiles.Select(profile =>
            {
                var text = Ui.Stack(2, Ui.Text(profile.Name), Ui.Caption(profile.Endpoint));
                if (profile.SshGateway is { } via) text.Children.Add(Ui.Caption(Strings.Format("history.gateway", via.CanonicalUri)));
                var item = new ListViewItem { Content = text, Tag = profile.Id };
                AutomationProperties.SetName(item, profile.Name);
                return item;
            }).ToList();
            if (list.Items.Count != items.Count || !list.Items.OfType<ListViewItem>().Select(i => (Guid)i.Tag)
                    .SequenceEqual(library.Profiles.Select(p => p.Id)) || list.Items.OfType<ListViewItem>()
                    .Zip(library.Profiles).Any(p => AutomationProperties.GetName(p.First) != p.Second.Name))
            {
                list.Items.Clear();
                foreach (var item in items) list.Items.Add(item);
            }
            list.SelectedItem = list.Items.OfType<ListViewItem>().FirstOrDefault(i => library.Draft?.Id is { } id && (Guid)i.Tag == id);
            list.IsEnabled = library.HasLoaded && !library.IsBusy && !library.HasChanges;
            empty.Text = library.Profiles.IsEmpty ? Strings.Get(library.HasLoaded ? "profiles.no.saved.profiles" : "profiles.profiles.have.not.loaded") : "";
            empty.Visibility = empty.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            create.IsEnabled = library.HasLoaded && !library.IsBusy && !library.NeedsReload && !library.HasChanges &&
                               library.Profiles.Length < NativeProfileHistoryStore.ProfileCapacity;

            // The editor.
            var draft = library.Draft;
            editor.Visibility = draft is null ? Visibility.Collapsed : Visibility.Visible;
            choose.Visibility = draft is null ? Visibility.Visible : Visibility.Collapsed;
            editor.IsHitTestVisible = library.CanEdit;
            name.IsEnabled = endpoint.IsEnabled = gateway.IsEnabled = library.CanEdit;
            if (draft is not null)
            {
                if (name.Text != draft.Name) name.Text = draft.Name;
                if (endpoint.Text != draft.Endpoint) endpoint.Text = draft.Endpoint;
                if (gateway.Text != library.GatewayText) gateway.Text = library.GatewayText;
            }
            endpointIssue.Text = NativeTexts.Endpoint(library.EndpointIssue) is { } issue ? Strings.Resolve(issue) : "";
            endpointIssue.Visibility = endpointIssue.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            gatewayIssue.Text = library.GatewayIssue is { } problem ? Strings.Resolve(problem) : "";
            gatewayIssue.Visibility = gatewayIssue.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            gatewayHelp.Visibility = library.GatewayText.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        finally
        {
            updating = false;
        }
        sections.Refresh();
        error.Text = Message(library.Error, library.Problem);
        error.Visibility = error.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        busy.Visibility = library.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        reload.Content = Strings.Get(library.HasChanges ? "action.discard.edits.reload" : "trust.library.ui.reload");
        reload.IsEnabled = !library.IsBusy;
        delete.IsEnabled = library.CanUse;
        cancel.IsEnabled = !library.IsBusy && library.HasChanges;
        save.IsEnabled = library.CanSave;
        open.IsEnabled = library.CanUse;
    }

    private void Open()
    {
        if (!library.CanUse || library.Draft is not { } profile) return;
        App.Current.OpenWindow(new NativeConnectionRequest { ProfileId = profile.Id });
    }
}
