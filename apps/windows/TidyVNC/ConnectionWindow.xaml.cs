// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using System.Globalization;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using TidyVNC.Native;
using TidyVNC.Native.Clipboard;
using TidyVNC.Native.Storage;
using TidyVNC.Native.Tunnel;

namespace TidyVNC;

/// <summary>
/// A connection window (UX.md section 3, PARITY C01-C10 and V01) over one
/// <see cref="NativeConnectionController"/>. The window only presents the
/// controller's state and forwards commands; admission, retry, history and
/// close ordering live in the controller. Prompts and alerts go through the
/// window's <see cref="DialogPresenter"/> in the macOS priority order.
/// </summary>
public sealed partial class ConnectionWindow : Window
{
    private readonly DesktopView desktop;
    private readonly DialogPresenter dialogs;
    private NativeSession? session;
    private readonly IDisposable scalingCheck;
    private bool closed, updatingFields;

    internal NativeConnectionController Controller { get; }
    internal DesktopView Desktop => desktop;
    internal NativeSession? Session => session;
    /// <summary>The latest clipboard problem for this connection; the status bar shows it.</summary>
    internal NativeClipboardNotice? ClipboardNotice { get; private set; }

    internal ConnectionWindow(NativeConnectionController controller)
    {
        InitializeComponent();
        Controller = controller;
        var window = WinRT.Interop.WindowNative.GetWindowHandle(this);
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        TitleIcon.ImageSource = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "tidyvnc_32.png")));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "tidyvnc.ico"));
        WindowSizes.Apply(AppWindow, 960, 700, 640, 420);
        desktop = new DesktopView(window);
        desktop.RenderFailed += _ => ShowFatal(NativePresentationIssues.From(new NativeError(NativeStatus.Failed, "render"), NativePresentationContext.Desktop).Message());
        DesktopHost.Child = desktop;
        dialogs = new DialogPresenter(() => Content?.XamlRoot, DesiredDialog);
        RecentPanel.Selected += destination => { Controller.SelectDestination(destination); RecentFlyout.Hide(); };
        GatewayHelp.Visibility = Visibility.Collapsed;
        if (NativeSshConfiguration.ClientPath is null)
        {
            // C09: without the Windows OpenSSH Client the gateway cannot work; say how to add it.
            Gateway.IsEnabled = false;
            GatewayIssue.Text = Strings.Get("profiles.ssh.windows.client.missing");
            GatewayIssue.Visibility = Visibility.Visible;
        }

        controller.PropertyChanged += ControllerChanged;
        controller.Defaults.PropertyChanged += (_, _) => Update();
        controller.Credentials.PropertyChanged += (_, _) => { Update(); dialogs.Update(); };
        controller.Trust.PropertyChanged += (_, _) => dialogs.Update();
        controller.SshInteraction.PropertyChanged += (_, _) => dialogs.Update();
        controller.SessionReady += Attach;
        // The desktop renders the connection's scaling and refuses sizes it cannot hold.
        scalingCheck = controller.Scaling.Register(desktop.CanRender);
        controller.Scaling.PropertyChanged += (_, _) => desktop.Scaling = controller.Scaling.Value;
        if (controller.History is { } history)
        {
            history.PropertyChanged += (_, _) => Update();
            RecentPanel.History = history;
        }
        if (controller.Session is { } ready) Attach(ready);

        AppWindow.Closing += OnClosing;
        Activated += (_, e) =>
        {
            var active = e.WindowActivationState != WindowActivationState.Deactivated;
            if (!active) desktop.ReleaseKeys();
            App.Current.WindowActivationChanged(this, active);
        };
        Root.Loaded += (_, _) => { dialogs.Update(); Address.Focus(FocusState.Programmatic); };
        Update();
    }

    private void Attach(NativeSession value)
    {
        if (ReferenceEquals(session, value)) return;
        session = value;
        session.PropertyChanged += SessionChanged;
        App.Current.Clipboard.Register(session, notice => { ClipboardNotice = notice; Update(); });
        session.BellHandler = App.Current.Bell.Ring;
        desktop.Session = session;
        desktop.Scaling = Controller.Scaling.Value;
        updatingFields = true;
        Address.Text = Controller.Endpoint;
        Gateway.Text = Controller.SshGatewayText;
        updatingFields = false;
        Update();
        dialogs.Update();
    }

    private void ControllerChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(NativeConnectionController.Endpoint) when Address.Text != Controller.Endpoint:
                updatingFields = true; Address.Text = Controller.Endpoint; updatingFields = false;
                break;
            case nameof(NativeConnectionController.SshGatewayText) when Gateway.Text != Controller.SshGatewayText:
                updatingFields = true; Gateway.Text = Controller.SshGatewayText; updatingFields = false;
                break;
            case nameof(NativeConnectionController.ClosesAfterFailure) when Controller.ClosesAfterFailure:
                _ = CloseGracefully();
                return;
        }
        Update();
        dialogs.Update();
    }

    private void SessionChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(NativeSession.Snapshot) or nameof(NativeSession.HasFrame) or nameof(NativeSession.ClipboardSendEnabled)
            or nameof(NativeSession.ClipboardReceiveEnabled)) Update();
        if (e.PropertyName is nameof(NativeSession.Prompt) or nameof(NativeSession.Snapshot)) dialogs.Update();
        if (e.PropertyName == nameof(NativeSession.Snapshot) && session?.Snapshot.State == NativeSessionState.Connected && session.HasFrame is false)
            desktop.Focus(FocusState.Programmatic);
    }

    // ---- Presentation ---------------------------------------------------------------

    private void Update()
    {
        if (closed) return;
        var controller = Controller;
        var defaults = controller.Defaults;
        var state = session?.Snapshot.State ?? NativeSessionState.Idle;
        var connected = state == NativeSessionState.Connected;

        // Title: the server first so taskbar thumbnails can be told apart (UX.md section 2).
        var title = controller.IsReverse ? Strings.Get("app.incoming.connection")
            : defaults.DocumentRequest is { } document && session is null ? Path.GetFileName(document.Path)
            : connected ? (session!.Information?.DesktopName is { Length: > 0 } name ? name : controller.Endpoint) + " – TidyVNC" : "TidyVNC";
        Title = title;
        AppTitleBar.Title = title;

        // Address row.
        var editable = controller.CanEditDestination;
        Address.IsReadOnly = !editable;
        Gateway.IsReadOnly = !editable;
        ToolTipService.SetToolTip(Address, Strings.Get(controller.IsReverse
            ? "app.source.address.of.this.incoming.connection.it.is.not.an.outbound.destination"
            : "profiles.enter.host.display.host.port.ipv6.display.or.a.unix.socket.path"));
        var issue = NativeTexts.Endpoint(controller.EndpointIssue);
        AddressIssue.Text = issue is null ? "" : Strings.Resolve(issue);
        AddressIssuePanel.Visibility = issue is null ? Visibility.Collapsed : Visibility.Visible;
        BusyRing.IsActive = controller.Busy;
        CancelButton.Visibility = controller.Busy ? Visibility.Visible : Visibility.Collapsed;
        DisconnectButton.Visibility = !controller.Busy && connected ? Visibility.Visible : Visibility.Collapsed;
        ConnectButton.Visibility = !controller.Busy && !connected && !controller.IsReverse ? Visibility.Visible : Visibility.Collapsed;
        ConnectButton.IsEnabled = controller.CanConnect;

        // Gateway.
        if (NativeSshConfiguration.ClientPath is not null)
        {
            GatewayIssue.Text = controller.GatewayIssue is { } gatewayIssue ? Strings.Resolve(gatewayIssue) : "";
            GatewayIssue.Visibility = controller.GatewayIssue is null ? Visibility.Collapsed : Visibility.Visible;
        }
        GatewayHelp.Visibility = controller.SshGatewayText.Length != 0 ? Visibility.Visible : Visibility.Collapsed;
        Gateway.Visibility = controller.IsReverse ? Visibility.Collapsed : Visibility.Visible;

        // Toolbar and the Connection menu (the same items as the toolbar's More button).
        ConnectionMenu.Fill(ConnectionMenuItem.Items, this);
        RecentButton.Visibility = controller.History is null ? Visibility.Collapsed : Visibility.Visible;
        RecentPanel.CanSelect = editable;
        ClipboardButton.IsEnabled = defaults.IsReady && session is not null;
        EncodingButton.IsEnabled = InputButton.IsEnabled = ScalingButton.IsEnabled = CanOpenConnectedEditor;

        // Notices, in the macOS order.
        ReverseNotice.IsOpen = controller.IsReverse;
        if (controller.History is { Error: { } historyError } history)
        {
            HistoryNotice.Message = Strings.Resolve(NativeTexts.History(historyError));
            ReloadHistoryButton.IsEnabled = !history.IsBusy;
            HistoryNotice.IsOpen = true;
        }
        else HistoryNotice.IsOpen = false;
        if (controller.Credentials.Notice is { } notice)
        {
            CredentialNotice.Message = Strings.Resolve(NativeTexts.Credential(notice));
            CredentialNotice.IsOpen = true;
        }
        else CredentialNotice.IsOpen = false;
        ProfileSource.Text = defaults.Profile is { } profile ? Strings.Format("app.profile.source", profile.Name) : "";
        ProfileSource.Visibility = defaults.Profile is null ? Visibility.Collapsed : Visibility.Visible;

        // Desktop, placeholder and pre-session pages.
        UpdateSetupPage();
        var hasFrame = session?.HasFrame == true;
        Placeholder.Visibility = session is not null && !hasFrame ? Visibility.Visible : Visibility.Collapsed;
        PlaceholderTitle.Text = state == NativeSessionState.Idle ? Strings.Get("help.guide.connect.title") : Strings.Resolve(NativeTexts.Status(state));
        PlaceholderDescription.Text = state == NativeSessionState.Idle ? Strings.Get("app.enter.a.vnc.server.address.to.begin") : "";
        PlaceholderDescription.Visibility = PlaceholderDescription.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;

        // Status bar.
        StatusText.Text = Strings.Resolve(NativeTexts.Status(state));
        ClipboardStatus.Text = ClipboardNotice is { } clipboard ? Strings.Resolve(NativeTexts.Clipboard(clipboard)) : "";
        ClipboardStatus.Visibility = ClipboardNotice is null ? Visibility.Collapsed : Visibility.Visible;
        DesktopSize.Text = session is { Snapshot.Width: > 0 } s
            ? Strings.Format("information.desktop.size", s.Snapshot.Width, s.Snapshot.Height) : "";
    }

    private void UpdateSetupPage()
    {
        var defaults = Controller.Defaults;
        object? page = null;
        if (session is null)
        {
            if (defaults.MonitorMapping is { } mapping)
                page = SetupPages.Mapping(mapping, defaults.DocumentRequest is null ? defaults.InvocationIssue : defaults.DocumentIssue,
                    defaults.InvocationRequest?.Endpoint ?? "", assignments => defaults.ResolveMapping(mapping.Id, assignments), () => defaults.CancelMapping(mapping.Id));
            else if (defaults.DocumentReview is { } review)
                page = SetupPages.Review(review, () => defaults.EditDocumentMapping(review.Id), () => defaults.AcceptDocument(review.Id),
                    () => defaults.CancelDocument(review.Id));
            else if (defaults.InvocationIssue is { } invocation)
                page = SetupPages.Problem(invocation, "invocation.error", ("app.retry.command.line.options", "invocation.retry", defaults.Load));
            else if (defaults.DocumentIssue is { } documentIssue)
                page = SetupPages.Problem(documentIssue, "document.error", ("listener.reload.connection.file", "document.reload", defaults.Load));
            else if (defaults.ProfileError is { } profileError)
                page = SetupPages.Problem(NativeTexts.Profile(profileError), "profile.error", ("app.retry.profile", "profile.retry", defaults.Load));
            else if (defaults.Error is { } error)
                page = SetupPages.Problem(NativeTexts.Preferences(error), "defaults.error", ("listener.retry.defaults", "defaults.retry", defaults.Load),
                    ("app.use.built.in.defaults.for.this.connection", "defaults.builtIn", defaults.UseBuiltInDefaults));
            else page = SetupPages.Loading();
        }
        if (page is null)
        {
            SetupContent.Content = null;
            SetupPage.Visibility = Visibility.Collapsed;
            return;
        }
        // Keep the same page (and its focus) while its request is unchanged.
        if (SetupContent.Content is FrameworkElement current && current.Tag is { } key && page is FrameworkElement next && Equals(key, next.Tag)) return;
        SetupContent.Content = page;
        SetupPage.Visibility = Visibility.Visible;
    }

    /// <summary>The dialog that should be showing now, in the macOS sheet priority order.</summary>
    private DialogRequest? DesiredDialog()
    {
        if (closed) return null;
        if (Controller.SshInteraction.Question is { } question)
            return new DialogRequest("ssh:" + question.Id, () => SshDialog.Create(Controller.SshInteraction, question),
                _ => Controller.SshInteraction.Cancel(question.Id));
        if (session?.Prompt is { } prompt)
        {
            if (prompt.Kind == NativePrompt.PromptKind.Credentials)
                return new DialogRequest($"auth:{prompt.Generation}:{prompt.Id}", () => AuthenticationDialog.Create(Controller, prompt),
                    result => { if (result != ContentDialogResult.Primary) Controller.Cancel(); });
            return new DialogRequest($"trust:{prompt.Generation}:{prompt.Id}", () => TrustDialog.Create(Controller, prompt),
                result => { if (result != ContentDialogResult.Primary) Controller.Cancel(); });
        }
        if (Controller.Editor is { } editor && EditorDialog(editor) is { } editing) return editing;
        if (Controller.ConnectionProblem is { } problem)
            return new DialogRequest("problem:" + problem.Id, () => ProblemDialog.Create(Controller, problem), result =>
            {
                if (result == ContentDialogResult.Primary && Controller.CanRetry(problem)) Controller.Retry(problem);
                else Controller.DismissProblem(problem.Id);
            });
        if (Controller.Message is { } message)
            return new DialogRequest("message:" + message.Key + string.Join('|', message.Arguments), () => ProblemDialog.Create(message),
                _ => Controller.DismissMessage());
        return null;
    }

    private void ShowFatal(NativeText text) => Controller.ReportFatal(text);

    /// <summary>The settings dialog for the open editor; closing or superseding it ends the editor.</summary>
    private DialogRequest? EditorDialog(object editor)
    {
        var key = "editor:" + System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(editor);
        Func<ContentDialog>? create = editor switch
        {
            NativeSessionEncodingDraft encoding => () => EncodingDialog.Create(encoding),
            NativeSessionSecurityDraft security => () => SecurityDialog.Create(security, this),
            NativeInputDraft input => () => InputDialog.Create(input),
            NativeScalingDraft scaling => () => ScalingDialog.Create(scaling),
            NativeConnectionDraft connection => () => ConnectionOptionsDialog.Create(connection),
            NativeRemoteResizePolicyDraft policy => () => RemoteResizePolicyDialog.Create(policy),
            NativeRemoteResizeDraft resize => () => RemoteResizeDialog.Create(resize),
            _ => null,
        };
        return create is null ? null : new DialogRequest(key, create, _ => Controller.EndEditor(editor), () => Controller.EndEditor(editor));
    }

    // ---- Settings dialogs (only one editor at a time; see NativeConnectionController.BeginEditor) ----

    internal bool CanOpenConnectedEditor => Controller.EditorsIdle && session?.Snapshot.State == NativeSessionState.Connected;

    internal bool CanOpenDisconnectedEditor => Controller.EditorsIdle &&
        session?.Snapshot.State is NativeSessionState.Idle or NativeSessionState.Closed or NativeSessionState.Failed;

    internal bool CanOpenAnyEditor => Controller.EditorsIdle && session is { IsClosing: false };

    internal bool CanResizeRemote => CanOpenConnectedEditor &&
        session is { Snapshot: { SupportsResize: true, ResizePending: false }, IsViewOnly: false };

    internal void OpenConnectionOptions()
    {
        if (!CanOpenDisconnectedEditor || session is null) return;
        var draft = new NativeConnectionDraft(session);
        if (!Controller.BeginEditor(draft, NativeEditorScope.Disconnected, () => { draft.Stop(); return Task.CompletedTask; })) { draft.Stop(); return; }
        draft.Reload();
        dialogs.Update();
    }

    internal void OpenResizePolicy()
    {
        if (!CanOpenAnyEditor || session is null) return;
        var draft = new NativeRemoteResizePolicyDraft(session);
        if (Controller.BeginEditor(draft, NativeEditorScope.Any, () => { draft.Cancel(); return Task.CompletedTask; })) dialogs.Update();
        else draft.Cancel();
    }

    internal void OpenRemoteResize()
    {
        if (!CanResizeRemote || session is null) return;
        var draft = new NativeRemoteResizeDraft(session, App.Current.Displays);
        if (!Controller.BeginEditor(draft, NativeEditorScope.Connected, async () => { await draft.CloseAsync(); draft.Dispose(); })) { draft.Dispose(); return; }
        draft.Reload();
        dialogs.Update();
    }

    internal void OpenSecurity()
    {
        if (!CanOpenDisconnectedEditor || session is null) return;
        NativeSessionSecurityDraft draft;
        try { draft = new NativeSessionSecurityDraft(session, Controller.SecurityApplied); }
        catch (NativeError)
        {
            Controller.ReportFatal(new NativeText("connection.recovery.security.settings.are.unavailable.for.this.connection"));
            return;
        }
        if (!Controller.BeginEditor(draft, NativeEditorScope.Disconnected, async () => { await draft.CloseAsync(); draft.Dispose(); })) { draft.Dispose(); return; }
        draft.Reload();
        dialogs.Update();
    }

    internal void OpenInput()
    {
        if (!CanOpenConnectedEditor) return;
        var draft = new NativeInputDraft(Controller.Input);
        if (Controller.BeginEditor(draft, NativeEditorScope.Connected, () => { draft.Cancel(); return Task.CompletedTask; })) dialogs.Update();
    }

    internal void OpenScaling()
    {
        if (!CanOpenConnectedEditor) return;
        var draft = new NativeScalingDraft(Controller.Scaling);
        if (Controller.BeginEditor(draft, NativeEditorScope.Connected, () => { draft.Cancel(); return Task.CompletedTask; })) dialogs.Update();
    }

    internal void OpenEncoding()
    {
        if (!CanOpenConnectedEditor || session is null) return;
        var draft = new NativeSessionEncodingDraft(session);
        if (!Controller.BeginEditor(draft, NativeEditorScope.Connected, async () => { await draft.CloseAsync(); draft.Dispose(); })) { draft.Dispose(); return; }
        draft.Reload();
        dialogs.Update();
    }

    // ---- Commands -------------------------------------------------------------------

    private void AddressChanged(object sender, TextChangedEventArgs e)
    {
        if (!updatingFields) Controller.Endpoint = Address.Text;
    }

    private void GatewayChanged(object sender, TextChangedEventArgs e)
    {
        if (!updatingFields) Controller.SshGatewayText = Gateway.Text;
    }

    private void AddressKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case Windows.System.VirtualKey.Enter:
                e.Handled = true;
                if (Controller.CanConnect) Controller.Connect();
                break;
            case Windows.System.VirtualKey.Escape when Controller.Busy:
                // C04: Escape in the address row cancels an attempt.
                e.Handled = true;
                Controller.Cancel();
                break;
        }
    }

    private void ConnectClick(object sender, RoutedEventArgs e) => Controller.Connect();
    private void EncodingClick(object sender, RoutedEventArgs e) => OpenEncoding();
    private void InputClick(object sender, RoutedEventArgs e) => OpenInput();
    private void ScalingClick(object sender, RoutedEventArgs e) => OpenScaling();
    private void DisconnectClick(object sender, RoutedEventArgs e) => Controller.Disconnect();
    private void CancelClick(object sender, RoutedEventArgs e) => Controller.Cancel();
    private void NewConnectionClick(object sender, RoutedEventArgs e) => App.Current.OpenWindow();
    private void OpenFileClick(object sender, RoutedEventArgs e) => App.Current.OpenConnectionFile(this);
    private void CloseWindowClick(object sender, RoutedEventArgs e) => _ = CloseGracefully();
    private void ExitClick(object sender, RoutedEventArgs e) => App.Current.ExitApplication();
    private void ProjectLinkClick(object sender, RoutedEventArgs e) => App.OpenLink(NativeHelpLink.Project);
    private void IssueLinkClick(object sender, RoutedEventArgs e) => App.OpenLink(NativeHelpLink.Issues);
    private void ReloadHistoryClick(object sender, RoutedEventArgs e) => Controller.History?.Reload();
    private void CredentialNoticeClosed(InfoBar sender, object args) => Controller.Credentials.DismissNotice();

    private void RecentOpening(object? sender, object e)
    {
        if (Controller.History is { IsBusy: false } history) history.Reload();
    }

    private void ClipboardOpening(object? sender, object e)
    {
        if (session is null) return;
        ClipboardSendItem.IsChecked = session.ClipboardSendEnabled;
        ClipboardReceiveItem.IsChecked = session.ClipboardReceiveEnabled;
        ClipboardSendSource.Text = Strings.Format("app.clipboard.send.source", Strings.Get(ClipboardSource("SendClipboard", session.ClipboardSendEnabled)));
        ClipboardReceiveSource.Text = Strings.Format("app.clipboard.receive.source", Strings.Get(ClipboardSource("AcceptClipboard", session.ClipboardReceiveEnabled)));
    }

    /// <summary>Where a clipboard direction comes from (macOS source(): override, file, profile, app default, built-in).</summary>
    private string ClipboardSource(string parameter, bool current)
    {
        var configured = Controller.Defaults.Prepared?.Configuration;
        var initial = parameter == "SendClipboard" ? configured?.ClipboardSend : configured?.ClipboardReceive;
        if (initial is { } value && value != current) return "settings.encoding.connection.override";
        return Controller.Defaults.Setup?.Resolution[parameter]?.Source switch
        {
            NativeOptionSource.Document => "settings.encoding.connection.file",
            NativeOptionSource.CommandLine => "settings.encoding.command.line",
            NativeOptionSource.Profile => "settings.encoding.profile",
            NativeOptionSource.AppDefaults => "settings.encoding.app.default",
            _ => "settings.defaults.built.in.default",
        };
    }

    private void ClipboardToggled(object sender, RoutedEventArgs e)
    {
        try
        {
            if (ReferenceEquals(sender, ClipboardSendItem)) Controller.Defaults.SetClipboard(send: ClipboardSendItem.IsChecked);
            else Controller.Defaults.SetClipboard(receive: ClipboardReceiveItem.IsChecked);
            ClipboardNotice = null;
        }
        catch (Exception error) when (error is NativeError or NativeStorageException)
        {
            ClipboardStatus.Text = Strings.Get("app.clipboard.settings.could.not.be.changed.try.again");
            ClipboardStatus.Visibility = Visibility.Visible;
        }
        Update();
    }

    private void ActionsOpening(object? sender, object e) => ConnectionMenu.Fill(ActionsFlyout.Items, this);

    // ---- Close ---------------------------------------------------------------------

    private void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (closed) return;
        args.Cancel = true;
        _ = CloseGracefully();
    }

    /// <summary>Dismisses dialogs, closes and drains the connection, then closes the window.</summary>
    internal async Task CloseGracefully()
    {
        if (closed) return;
        closed = true;
        dialogs.Close();
        if (session is not null) App.Current.Clipboard.Unregister(session);
        try { await Controller.CloseAsync(); }
        catch (Exception error) { System.Diagnostics.Trace.TraceError($"Connection close failed: {error}"); }
        Controller.Dispose();
        scalingCheck.Dispose();
        desktop.Dispose();
        Close();
    }
}
