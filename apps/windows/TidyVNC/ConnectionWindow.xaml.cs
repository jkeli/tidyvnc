// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using System.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TidyVNC.Native;

namespace TidyVNC;

/// <summary>
/// The W3 vertical-slice connection window (TODO W3.5/W3.6): address, Connect,
/// the authentication dialog, the desktop and Disconnect. Closing waits for the
/// session to drain; closing during authentication dismisses the dialog.
/// </summary>
public sealed partial class ConnectionWindow : Window
{
    private readonly DesktopView desktop;
    private NativeSession? session;
    private CancellationTokenSource? connecting;
    private ContentDialog? dialog;
    private bool closed;

    internal ConnectionWindow(string? address)
    {
        InitializeComponent();
        var window = WinRT.Interop.WindowNative.GetWindowHandle(this);
        desktop = new DesktopView(window);
        desktop.RenderFailed += error => Status.Text = $"Display error: {error.Message}";
        DesktopHost.Child = desktop;
        Address.Text = address ?? "";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 800));
        AppWindow.Closing += OnClosing;
        Activated += (_, e) =>
        {
            if (e.WindowActivationState == WindowActivationState.Deactivated) desktop.ReleaseKeys();
        };
        UpdateState();
        // Dialogs need the loaded content's XamlRoot, so connect once it exists.
        if (!string.IsNullOrWhiteSpace(address))
            Root.Loaded += (_, _) => _ = ConnectAsync();
    }

    internal DesktopView Desktop => desktop;
    internal NativeSession? Session => session;

    private void AddressKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; _ = ConnectAsync(); }
    }

    private void ConnectClick(object sender, RoutedEventArgs e) => _ = ConnectAsync();

    private async void DisconnectClick(object sender, RoutedEventArgs e)
    {
        if (session is null) return;
        try { await session.DisconnectAsync(); }
        catch (Exception error) when (error is NativeError or NativeCommandFailure) { Status.Text = error.Message; }
    }

    private void NewWindowClick(object sender, RoutedEventArgs e) => App.Current.OpenWindow();

    internal async Task ConnectAsync()
    {
        var address = Address.Text.Trim();
        if (address.Length == 0 || closed) return;
        if (session is null)
        {
            session = App.Current.Runtime.CreateSession();
            session.PropertyChanged += SessionChanged;
            desktop.Session = session;
        }
        connecting?.Dispose();
        connecting = new CancellationTokenSource();
        Status.Text = $"Connecting to {address}…";
        try
        {
            await session.ConnectAsync(address, connecting.Token);
            desktop.Focus(FocusState.Programmatic);
        }
        catch (OperationCanceledException) { Status.Text = "Connection cancelled"; }
        catch (NativeCommandFailure failure) { Status.Text = Describe(failure.Snapshot); }
        catch (NativeError error) { Status.Text = error.Message; }
        UpdateState();
    }

    private void SessionChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (session is null) return;
        switch (e.PropertyName)
        {
            case nameof(NativeSession.Snapshot):
            case nameof(NativeSession.HasFrame):
                UpdateState();
                break;
            case nameof(NativeSession.Prompt):
                if (session.Prompt is { Kind: NativePrompt.PromptKind.Credentials } prompt) _ = AskCredentials(prompt);
                else if (session.Prompt is null) dialog?.Hide();
                break;
        }
    }

    private void UpdateState()
    {
        var state = session?.Snapshot.State ?? NativeSessionState.Idle;
        var active = state is not (NativeSessionState.Idle or NativeSessionState.Closed or NativeSessionState.Failed);
        ConnectButton.IsEnabled = !active && !closed;
        DisconnectButton.IsEnabled = active && !closed;
        Address.IsEnabled = !active;
        if (state == NativeSessionState.Connected)
        {
            Status.Text = session!.HasFrame ? "" : "Waiting for the desktop…";
            Title = $"{session.Information?.DesktopName ?? Address.Text} – TidyVNC";
        }
        else if (state is NativeSessionState.Closed or NativeSessionState.Failed && session is not null)
        {
            Status.Text = Describe(session.Snapshot);
            Title = "TidyVNC";
        }
        else if (state == NativeSessionState.Authenticating) Status.Text = "Authenticating…";
    }

    private static string Describe(NativeSnapshot snapshot) => snapshot.EndReason switch
    {
        NativeEndReason.None or NativeEndReason.Cancelled => "Disconnected",
        NativeEndReason.PeerClosed => "The server closed the connection",
        NativeEndReason.AuthenticationRejected => "Authentication failed",
        NativeEndReason.Resolution or NativeEndReason.ResolutionTimeout => "The server name could not be resolved",
        NativeEndReason.Connection or NativeEndReason.ConnectionTimeout => "Could not connect to the server",
        NativeEndReason.InvalidEndpoint or NativeEndReason.UnsupportedEndpoint => "The server address is not valid",
        NativeEndReason.PromptTimeout => "Authentication timed out",
        _ => $"Connection ended ({snapshot.EndReason})",
    };

    private async Task AskCredentials(NativePrompt prompt)
    {
        dialog?.Hide();
        if (Content.XamlRoot is null) return; // Not loaded: connections start after Loaded.
        var username = new TextBox { Header = "Username", Visibility = prompt.UsernameRequired ? Visibility.Visible : Visibility.Collapsed };
        var password = new PasswordBox { Header = "Password" };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(username, "authentication.username");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(password, "authentication.password");
        var panel = new StackPanel { Spacing = 12, MinWidth = 320 };
        panel.Children.Add(new TextBlock { Text = prompt.ServerName, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(username);
        panel.Children.Add(password);
        dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Authentication",
            Content = panel,
            PrimaryButtonText = "OK",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        var shown = dialog;
        shown.Opened += (_, _) => (prompt.UsernameRequired ? (Control)username : password).Focus(FocusState.Programmatic);
        var result = await shown.ShowAsync();
        if (!ReferenceEquals(dialog, shown)) return;
        dialog = null;
        if (session is null || session.Prompt?.Id != prompt.Id) return; // Dismissed by the session (timeout, close).
        if (result == ContentDialogResult.Primary)
        {
            try { session.ReplyCredentials(prompt, Encoding.UTF8.GetBytes(username.Text), Encoding.UTF8.GetBytes(password.Password)); }
            catch (NativeError error) { Status.Text = error.Message; }
        }
        else
        {
            connecting?.Cancel();
        }
    }

    private void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (closed) return;
        args.Cancel = true;
        _ = CloseGracefully();
    }

    /// <summary>Dismisses prompts, closes and drains the session, then closes the window.</summary>
    internal async Task CloseGracefully()
    {
        if (closed) return;
        closed = true;
        UpdateState();
        dialog?.Hide();
        connecting?.Cancel();
        if (session is not null)
        {
            try { await session.CloseAsync(); }
            catch (Exception error) { System.Diagnostics.Trace.TraceError($"Session close failed: {error}"); }
        }
        desktop.Dispose();
        connecting?.Dispose();
        Close();
    }
}
