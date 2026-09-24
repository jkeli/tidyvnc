// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using System.Runtime.InteropServices;
using Microsoft.Windows.AppLifecycle;
using TidyVNC.Native;
using TidyVNC.Native.Activation;
using TidyVNC.Native.Documents;
using TidyVNC.Native.Clipboard;
using TidyVNC.Native.Credentials;
using TidyVNC.Native.Platform;
using TidyVNC.Native.Storage;
using TidyVNC.Native.Trust;

namespace TidyVNC;

/// <summary>
/// The WinUI application (plans/native-ui-winui PLAN.md section 3): one UI
/// thread, one core runtime, one keyboard hook, any number of connection
/// windows. The process exits after the last window has closed and the
/// runtime has drained (SERVICES.md section 11).
/// </summary>
public partial class App : Application
{
    private readonly List<ConnectionWindow> windows = [];
    private bool exiting;
    private EventWaitHandle? closeRequest;
    private RegisteredWaitHandle? closeWait;

    public App()
    {
        InitializeComponent();
        // Until W4.11 routes this into the process log, TIDYVNC_CRASH_LOG names a
        // file that receives unhandled UI exceptions (tests and diagnosis).
        UnhandledException += (_, e) =>
        {
            System.Diagnostics.Trace.TraceError($"Unhandled UI exception: {e.Exception}");
            if (Environment.GetEnvironmentVariable("TIDYVNC_CRASH_LOG") is { Length: > 0 } path)
            {
                try { File.AppendAllText(path, e.Exception + Environment.NewLine); }
                catch (IOException) { }
            }
        };
    }

    internal static new App Current => (App)Application.Current;
    internal UiDispatcher Dispatcher { get; private set; } = null!;
    internal NativeRuntime Runtime { get; private set; } = null!;
    internal KeyboardRouter Keyboard { get; private set; } = null!;
    /// <summary>
    /// VNC_USERNAME / VNC_PASSWORD and the PasswordFile, captured once at
    /// launch and removed from the environment block; the first ordinary
    /// connection window claims them (CREDENTIAL-INPUTS.md, SERVICES.md 3).
    /// </summary>
    internal NativeLaunchCredentialInputs? LaunchCredentials { get; private set; }
    /// <summary>The app-wide clipboard router over the Windows clipboard (SERVICES.md section 6).</summary>
    internal NativeClipboardCoordinator Clipboard { get; private set; } = null!;
    private NativeWindowsClipboard? systemClipboard;
    /// <summary>Display topology with stable IDs and change generations (SERVICES.md section 7).</summary>
    internal NativeDisplayService Displays { get; private set; } = null!;
    private NativeDisplayChangeListener? displayChanges;
    private readonly HashSet<ConnectionWindow> activeWindows = [];
    private readonly TaskCompletionSource shutdownComplete = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private NativeSessionEvents? sessionEvents;
    /// <summary>The bell, coalesced per delivery turn (SERVICES.md section 14).</summary>
    internal NativeBell Bell { get; private set; } = null!;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Dispatcher = new UiDispatcher(DispatcherQueue.GetForCurrentThread());
        NativeText.SetResolver(Strings.Resolve);
        ConfigureLogging();
        Runtime = new NativeRuntime(Dispatcher);
        Bell = new NativeBell(Dispatcher);
        sessionEvents = new NativeSessionEvents(EndSessionAsync);
        sessionEvents.Changed += change => Dispatcher.TryEnqueue(() => SessionChanged(change));
        Keyboard = new KeyboardRouter();
        LaunchCredentials = CaptureLaunchCredentials();
        systemClipboard = new NativeWindowsClipboard();
        Clipboard = new NativeClipboardCoordinator(Dispatcher, systemClipboard);
        displayChanges = new NativeDisplayChangeListener();
        Displays = new NativeDisplayService(Dispatcher, listener: displayChanges);
        // vncviewer.exe (D9) signals this to close every window, e.g. on Ctrl+C.
        closeRequest = new EventWaitHandle(false, EventResetMode.ManualReset, $@"Local\TidyVNC-close-{Environment.ProcessId}");
        closeWait = ThreadPool.RegisterWaitForSingleObject(closeRequest, (_, _) => Dispatcher.TryEnqueue(CloseAll), null, -1, true);
        CreateStores();
        Documents = new NativeDocumentLaunchRouter(Dispatcher);
        Documents.Install(OpenDocument);
        if (Program.CommandLineLaunch) ExecuteCommandLine();
        else Execute(NativeActivation.Classify(Environment.GetCommandLineArgs().Skip(1).ToArray(), Environment.CurrentDirectory));
        if (!Program.CommandLineLaunch)
        {
            // The primary instance: later shell launches arrive here, on the UI thread.
            Program.DeliverActivations(activation => Dispatcher.TryEnqueue(() => Redirected(activation)));
            PublishJumpList();
        }
    }

    /// <summary>Connection files from launches and redirected activations (reviewed before connecting).</summary>
    internal NativeDocumentLaunchRouter Documents { get; private set; } = null!;
    /// <summary>App defaults, profiles and history, credentials and trust decisions (SERVICES.md sections 2-5).</summary>
    internal NativePreferencesStore Preferences { get; private set; } = null!;
    internal NativeProfileHistoryStore Profiles { get; private set; } = null!;
    internal NativeRecentHistory History { get; private set; } = null!;
    private NativeCredentialStore? credentialStore;
    private NativeTrustStore? certificateTrust, hostKeyTrust;

    /// <summary>What every connection window shares.</summary>
    internal NativeConnectionServices Services => new(Runtime, Preferences)
    {
        Profiles = Profiles, History = History, Credentials = credentialStore, LegacyTrust = NativeLegacyTrustFiles.Default(),
        Certificates = certificateTrust, HostKeys = hostKeyTrust,
        Displays = () => { Displays.Refresh(); return NativeSessionDefaults.DisplaysOf(Displays.Snapshot); },
    };

    private void CreateStores()
    {
        var root = NativeStateRoot.Directory;
        Preferences = new NativePreferencesStore(root);
        Profiles = new NativeProfileHistoryStore(root);
        History = new NativeRecentHistory(Dispatcher, Profiles);
        History.Reload();
        credentialStore = new NativeCredentialStore();
        certificateTrust = new NativeTrustStore(NativeTrustKind.Certificate, root);
        hostKeyTrust = new NativeTrustStore(NativeTrustKind.HostKey, root);
    }

    /// <summary>A launch through vncviewer.exe (D9): the retained viewer's behaviour, connecting a given address at once.</summary>
    private void ExecuteCommandLine()
    {
        var arguments = Environment.GetCommandLineArgs().Skip(1).ToArray();
        NativeInvocation invocation;
        try { invocation = NativeInvocation.Parse(arguments); }
        catch (Exception error) when (error is NativeInvocationFailure or NativeError)
        {
            OpenWindow(); // vncviewer.exe has already reported the syntax error.
            return;
        }
        var request = NativeActivation.Classify(arguments, Environment.CurrentDirectory);
        if (request.Kind == NativeActivationKind.Document)
        {
            OpenWindow(new NativeConnectionRequest
            {
                Invocation = new NativeInvocationLayer(invocation, "", Environment.CurrentDirectory),
                Document = new NativeDocumentOpenRequest(Guid.NewGuid(), request.DocumentPath!, Environment.CurrentDirectory),
                LaunchCredentials = LaunchCredentials,
            });
            return;
        }
        var endpoint = request.Kind == NativeActivationKind.Address ? request.Address! : "";
        OpenWindow(new NativeConnectionRequest
        {
            Invocation = new NativeInvocationLayer(invocation, endpoint, Environment.CurrentDirectory),
            ConnectOnReady = endpoint.Length != 0,
            LaunchCredentials = LaunchCredentials,
        });
    }

    /// <summary>Opens what a launch asked for (SERVICES.md section 12).</summary>
    private void Execute(NativeActivationRequest request)
    {
        switch (request.Kind)
        {
            case NativeActivationKind.Address:
                // A shell launch fills the address; connecting waits for the user (SERVICES.md section 12).
                OpenWindow(new NativeConnectionRequest
                {
                    Invocation = new NativeInvocationLayer(NativeInvocation.Parse([]), request.Address!, null),
                    LaunchCredentials = LaunchCredentials,
                });
                break;
            case NativeActivationKind.Document when Documents.Route([request.DocumentPath!], Environment.CurrentDirectory):
                break;
            default:
                // NewWindow, Listen (the listener window is W5), Invalid and unroutable documents.
                OpenWindow();
                break;
        }
    }

    /// <summary>A shell launch redirected from a second process (plain launch, file open or Jump List task).</summary>
    private void Redirected(AppActivationArguments activation)
    {
        if (exiting) return;
        NativeActivationRequest request;
        if (activation.Kind == ExtendedActivationKind.Launch && activation.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch)
        {
            var arguments = NativeActivation.SplitCommandLine(launch.Arguments ?? "").ToList();
            // Unpackaged launches may carry the executable as the first token.
            if (arguments.Count > 0 && arguments[0].EndsWith("TidyVNC.exe", StringComparison.OrdinalIgnoreCase)) arguments.RemoveAt(0);
            // The sender's working directory is not part of the activation: only full paths are documents.
            request = NativeActivation.Classify(arguments);
        }
        else if (activation.Kind == ExtendedActivationKind.File && activation.Data is Windows.ApplicationModel.Activation.IFileActivatedEventArgs file)
        {
            var paths = file.Files.Select(f => f.Path).Where(p => !string.IsNullOrEmpty(p)).ToList();
            if (paths.Count > 0 && Documents.Route(paths, Environment.CurrentDirectory)) return;
            request = new NativeActivationRequest(NativeActivationKind.NewWindow);
        }
        else request = new NativeActivationRequest(NativeActivationKind.NewWindow);
        Execute(request);
    }

    /// <summary>Opens a connection file for review in a new window (nothing connects until the user chooses Connect).</summary>
    private void OpenDocument(NativeDocumentOpenRequest request) => OpenWindow(new NativeConnectionRequest { Document = request });

    /// <summary>File > Open connection file… (C06): the common dialog with the Review button, then review in a new window.</summary>
    internal void OpenConnectionFile(Window owner)
    {
        var text = new NativeFileDialogText(Strings.Get("app.open.connection.file"), Strings.Get("app.review"),
            Strings.Get("document.files.tidyvnc"), Strings.Get("document.files.tigervnc"), AllFiles: Strings.Get("document.files.all"));
        string? path;
        try { path = NativeFileDialogs.Show(WinRT.Interop.WindowNative.GetWindowHandle(owner), NativeFileDialogKind.OpenConnection, text); }
        catch (InvalidOperationException) { return; } // Another file dialog is already open.
        if (path is not null && !exiting) Documents.Route([path], Environment.CurrentDirectory);
    }

    /// <summary>File > Exit: the coordinated shutdown of every window.</summary>
    internal void ExitApplication() => CloseAll();

    /// <summary>Jump List tasks for this app's taskbar button; each is a shell launch that reaches this primary.</summary>
    private static void PublishJumpList()
    {
        try { NativeJumpList.Publish(NativeActivation.AppUserModelId, Environment.ProcessPath!, [new NativeJumpListTask(Strings.Get("import.defaults.new.connection"), "")]); }
        catch (COMException error) { System.Diagnostics.Trace.TraceWarning($"Jump List not published: {error.HResult:x8}"); }
    }

    private static NativeLaunchCredentialInputs? CaptureLaunchCredentials()
    {
        string? passwordFile = null;
        try
        {
            var invocation = NativeInvocation.Parse(Environment.GetCommandLineArgs().Skip(1).ToArray());
            passwordFile = NativeLaunchCredentialInputs.PasswordFile(invocation, Environment.CurrentDirectory);
        }
        catch (Exception error) when (error is NativeInvocationFailure or NativeError or NativeLaunchCredentialException)
        {
            // The console launcher reports argument errors; fixed text only here.
            System.Diagnostics.Trace.TraceWarning($"PasswordFile unavailable: {error.GetType().Name}");
        }
        try { return NativeLaunchCredentialInputs.Capture(passwordFile); }
        catch (Exception error) when (error is NativeLaunchCredentialException or NativeCredentialException)
        {
            // Never echo a value; the variables are already cleared.
            System.Diagnostics.Trace.TraceWarning($"Launch credentials unavailable: {error.GetType().Name}");
            return null;
        }
    }

    /// <summary>The app is active while any of its windows is; clipboard routing follows it.</summary>
    internal void WindowActivationChanged(ConnectionWindow window, bool active)
    {
        var wasActive = activeWindows.Count > 0;
        if (active) activeWindows.Add(window); else activeWindows.Remove(window);
        if (wasActive != activeWindows.Count > 0) Clipboard.SetApplicationActive(activeWindows.Count > 0);
    }

    /// <summary>
    /// Exit order (SERVICES.md section 13, the macOS AppCoordinator): stop
    /// document routing and any open file dialog, then close every window's
    /// session; the last window closing drains the observers and the runtime.
    /// </summary>
    private void CloseAll()
    {
        Documents?.Stop();
        NativeFileDialogs.CancelActive();
        foreach (var window in windows.ToList()) _ = window.CloseGracefully();
        if (windows.Count == 0 && !exiting) _ = ShutdownAsync();
    }

    /// <summary>Sign-out or restart: the same shutdown, which the session thread waits for (bounded).</summary>
    private Task EndSessionAsync()
    {
        Dispatcher.TryEnqueue(CloseAll);
        return shutdownComplete.Task;
    }

    /// <summary>Lock and suspend release captured keys and anything held on the remote side, as macOS does on sleep.</summary>
    private void SessionChanged(NativeSessionEvent change)
    {
        if (change is not (NativeSessionEvent.Locked or NativeSessionEvent.Suspending)) return;
        var reason = change == NativeSessionEvent.Locked ? NativeKeyboardCaptureRelease.Lock : NativeKeyboardCaptureRelease.Sleep;
        foreach (var window in windows)
        {
            window.Desktop.Capture.Release(reason);
            window.Desktop.ReleaseKeys();
        }
    }

    /// <summary>Process logging from the last Log parameter, committed before the first runtime (SERVICES.md section 14).</summary>
    private static void ConfigureLogging()
    {
        try
        {
            var invocation = NativeInvocation.Parse(Environment.GetCommandLineArgs().Skip(1).ToArray());
            var policy = NativeProcessLogging.Selection(invocation);
            // Isolated test roots (Debug) also move the log file (TESTING.md section 2).
            if (TidyVNC.Native.Storage.NativeStateRoot.LogFile is { } file) NativeProcessLogging.Configure(policy, file);
            else NativeProcessLogging.Configure(policy);
        }
        catch (Exception error) when (error is NativeInvocationFailure or NativeError)
        {
            // The console launcher reports invalid Log values; shell launches keep the default route.
            System.Diagnostics.Trace.TraceWarning($"Logging not configured: {error.GetType().Name}");
        }
    }

    /// <summary>Opens one of the fixed project links in the default browser.</summary>
    internal static void OpenLink(NativeHelpLink link) => _ = Windows.System.Launcher.LaunchUriAsync(NativeHelpLinks.For(link));

    internal ConnectionWindow OpenWindow(NativeConnectionRequest? request = null)
    {
        var window = new ConnectionWindow(new NativeConnectionController(Services, request));
        windows.Add(window);
        window.Closed += (_, _) => WindowClosed(window);
        window.Activate();
        return window;
    }

    private async void WindowClosed(ConnectionWindow window)
    {
        windows.Remove(window);
        WindowActivationChanged(window, false);
        if (windows.Count > 0 || exiting) return;
        await ShutdownAsync();
    }

    private async Task ShutdownAsync()
    {
        exiting = true;
        Documents?.Stop();
        await Clipboard.CloseAsync();
        await History.CloseAsync();
        if (credentialStore is not null) await credentialStore.DisposeAsync();
        foreach (var store in new IDisposable?[] { Preferences, Profiles, certificateTrust, hostKeyTrust }) store?.Dispose();
        systemClipboard?.Dispose();
        Displays.Dispose();
        displayChanges?.Dispose();
        try { await Runtime.ShutdownAsync(); }
        catch (Exception error) { System.Diagnostics.Trace.TraceError($"Runtime shutdown failed: {error}"); }
        Keyboard.Dispose();
        LaunchCredentials?.Clear();
        closeWait?.Unregister(null);
        closeRequest?.Dispose();
        // Release a waiting WM_ENDSESSION before the session thread stops.
        shutdownComplete.TrySetResult();
        sessionEvents?.Dispose();
        Exit();
    }
}
