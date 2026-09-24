// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TidyVNC.Native;

namespace TidyVNC;

/// <summary>
/// Listen for connections (macOS ListenerView; PARITY L07, L08, W12): a TCP
/// port and address families, Start and Stop listening, the addresses being
/// listened on and the incoming connections waiting to be accepted into a new
/// connection window or rejected.
/// </summary>
internal sealed partial class ListenerWindow : Window
{
    private readonly NativeListenerModel model;
    private readonly TextBox port = new() { Header = Strings.Get("listener.tcp.port"), IsSpellCheckEnabled = false, MaxWidth = 200, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly CheckBox ipv4 = new() { Content = "IPv4" };
    private readonly CheckBox ipv6 = new() { Content = "IPv6" };
    private readonly Button start, stop;
    private readonly TextBlock status = Ui.Text("", "listener.status");
    private readonly StackPanel addresses = new() { Spacing = 2 };
    private readonly StackPanel incoming = new() { Spacing = 8 };
    private readonly TextBlock issue = Ui.Text("", "listener.issue");
    private bool updating, closing;

    public ListenerWindow(NativeListenerModel model)
    {
        this.model = model;
        Title = Strings.Get("listener.listen.for.connections");
        SystemBackdrop = new MicaBackdrop();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "tidyvnc.ico"));
        WindowSizes.Apply(AppWindow, 520, 560, 420, 400);

        AutomationProperties.SetAutomationId(port, "listener.port");
        AutomationProperties.SetAutomationId(ipv4, "listener.ipv4");
        AutomationProperties.SetAutomationId(ipv6, "listener.ipv6");
        port.TextChanged += (_, _) => { if (!updating) model.Port = port.Text; };
        ipv4.Click += (_, _) => model.Ipv4 = ipv4.IsChecked == true;
        ipv6.Click += (_, _) => model.Ipv6 = ipv6.IsChecked == true;
        start = Ui.Button(Strings.Get("listener.start.listening"), (_, _) => model.Start(), "listener.start", accent: true);
        stop = Ui.Button(Strings.Get("listener.stop.listening"), (_, _) => model.Stop(), "listener.stop");
        issue.Foreground = Ui.Error;
        var families = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, Children = { ipv4, ipv6 } };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { start, stop } };
        AutomationProperties.SetAutomationId(incoming, "listener.incoming");
        var panel = Ui.Stack(12,
            Ui.Title(Strings.Get("listener.listen.for.connections"), "listener.title"),
            Ui.Caption(Strings.Get("listener.start.a.listener.then.ask.the.remote.vnc.server.to.connect.to")),
            port, families, buttons, status, addresses, issue,
            Ui.Heading(Strings.Get("listener.incoming.connections")), incoming,
            Ui.Caption(Strings.Get("listener.waiting.connections.expire.after.30.seconds.stopping.the.listener.leaves.accepted.connections")));
        panel.Padding = new Thickness(24);
        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        Strings.Localize(this);

        model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NativeListenerModel.ClosesAfterFailure) && model.ClosesAfterFailure) Close();
            else Refresh();
        };
        Activated += (_, _) => model.StartLaunchIfNeeded();
        AppWindow.Closing += (_, _) => { closing = true; model.RequestClose(); };
        Refresh();
    }

    private static string Text(NativeListenerIssue value) => Strings.Get(value switch
    {
        NativeListenerIssue.InvalidPort => "listener.enter.a.tcp.port.from.0.to.65535.port.0.chooses.an",
        NativeListenerIssue.NoFamily => "listener.enable.ipv4.or.ipv6.to.listen.for.connections",
        NativeListenerIssue.Bind => "listener.the.listener.could.not.bind.this.port.check.whether.another.listener.is",
        NativeListenerIssue.Overflow => "listener.the.incoming.connection.queue.filled.before.it.could.be.processed.start.the",
        NativeListenerIssue.Delivery => "listener.listener.updates.could.not.be.delivered.stop.and.restart.the.listener",
        NativeListenerIssue.StartFailed => "listener.the.listener.could.not.start.check.its.port.and.network.settings.then",
        NativeListenerIssue.Unavailable => "listener.this.incoming.connection.is.no.longer.available",
        NativeListenerIssue.OpenFailed => "listener.a.connection.window.could.not.be.opened.try.again.or.reject.the",
        _ => "listener.the.listener.stopped.because.it.could.not.receive.incoming.connections.start.it",
    });

    private void Refresh()
    {
        if (closing) return;
        updating = true;
        try
        {
            if (port.Text != model.Port) port.Text = model.Port;
            ipv4.IsChecked = model.Ipv4; ipv6.IsChecked = model.Ipv6;
        }
        finally { updating = false; }
        var editable = model.CanStart;
        port.IsEnabled = ipv4.IsEnabled = ipv6.IsEnabled = editable;
        start.IsEnabled = model.CanStart;
        stop.IsEnabled = model.CanStop;
        status.Text = Strings.Get(model.Phase switch
        {
            NativeListenerPhase.Starting => "listener.starting.listener",
            NativeListenerPhase.Listening => "listener.listening.for.connections",
            NativeListenerPhase.Stopping => "listener.stopping.listener",
            NativeListenerPhase.Stopped => "listener.listener.stopped",
            NativeListenerPhase.Failed => "listener.listener.could.not.continue",
            _ => "listener.ready.to.listen",
        });
        addresses.Children.Clear();
        foreach (var address in model.Addresses)
            addresses.Children.Add(Ui.Caption(Strings.Format("listener.address.port", address.Host.Contains(':', StringComparison.Ordinal) ? "IPv6" : "IPv4",
                address.Port.ToString(CultureInfo.InvariantCulture))));
        incoming.Children.Clear();
        if (model.Incoming.IsEmpty) incoming.Children.Add(Ui.Caption(Strings.Get("listener.no.incoming.connections.are.waiting")));
        foreach (var peer in model.Incoming)
        {
            var reserved = model.Reserved.Contains(peer.Id);
            var accept = Ui.Button(Strings.Get(reserved ? "listener.opening" : "listener.accept"), (_, _) => model.Accept(peer), $"listener.accept.{peer.Id}", accent: true);
            var reject = Ui.Button(Strings.Get("listener.reject"), (_, _) => model.Reject(peer), $"listener.reject.{peer.Id}");
            accept.IsEnabled = reject.IsEnabled = model.CanAccept(peer);
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var text = Ui.Stack(2, Ui.Text(peer.Address.Host),
                Ui.Caption(Strings.Format("listener.source.port", peer.Address.Port.ToString(CultureInfo.InvariantCulture))));
            Grid.SetColumn(accept, 1); Grid.SetColumn(reject, 2);
            row.Children.Add(text); row.Children.Add(accept); row.Children.Add(reject);
            incoming.Children.Add(row);
        }
        issue.Text = model.Issue is { } problem ? Text(problem) : "";
        issue.Visibility = issue.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }
}
