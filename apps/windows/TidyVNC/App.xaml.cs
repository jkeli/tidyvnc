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

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Dispatcher = new UiDispatcher(DispatcherQueue.GetForCurrentThread());
        Runtime = new NativeRuntime(Dispatcher);
        Keyboard = new KeyboardRouter();
        LaunchCredentials = CaptureLaunchCredentials();
        systemClipboard = new NativeWindowsClipboard();
        Clipboard = new NativeClipboardCoordinator(Dispatcher, systemClipboard);
        displayChanges = new NativeDisplayChangeListener();
        Displays = new NativeDisplayService(Dispatcher, listener: displayChanges);
        // vncviewer.exe (D9) signals this to close every window, e.g. on Ctrl+C.
        closeRequest = new EventWaitHandle(false, EventResetMode.ManualReset, $@"Local\TidyVNC-close-{Environment.ProcessId}");
        closeWait = ThreadPool.RegisterWaitForSingleObject(closeRequest, (_, _) => Dispatcher.TryEnqueue(CloseAll), null, -1, true);
        Documents = new NativeDocumentLaunchRouter(Dispatcher);
        Documents.Install(OpenDocument);
        Execute(NativeActivation.Classify(Environment.GetCommandLineArgs().Skip(1).ToArray(), Environment.CurrentDirectory));
        if (!Program.CommandLineLaunch)
        {
            // The primary instance: later shell launches arrive here, on the UI thread.
            Program.DeliverActivations(activation => Dispatcher.TryEnqueue(() => Redirected(activation)));
            PublishJumpList();
        }
    }

    /// <summary>Connection files from launches and redirected activations (reviewed before connecting).</summary>
    internal NativeDocumentLaunchRouter Documents { get; private set; } = null!;

    /// <summary>Opens what a launch asked for (SERVICES.md section 12).</summary>
    private void Execute(NativeActivationRequest request)
    {
        switch (request.Kind)
        {
            case NativeActivationKind.Address:
                OpenWindow(request.Address);
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

    /// <summary>
    /// Opens a connection file in a new window without connecting. The full
    /// review page (settings, monitor mapping, losses) is W5.14; until then
    /// the window shows the file's server for the user to confirm.
    /// </summary>
    private async void OpenDocument(NativeDocumentOpenRequest request)
    {
        var window = OpenWindow(null, connect: false);
        try
        {
            var bytes = await new NativeDocumentFileReader().ReadAsync(request.Path, CancellationToken.None);
            using var document = new NativeConnectionDocument(bytes);
            var index = document.Entries.ToList().FindIndex(e => string.Equals(e.Name, "ServerName", StringComparison.OrdinalIgnoreCase));
            window.ReviewDocument(index >= 0 ? document.DecodedValue(index) : null, null);
        }
        catch (Exception error) when (error is NativeDocumentOpenException or NativeDocumentFailure or NativeError)
        {
            window.ReviewDocument(null, "The connection file could not be opened.");
        }
    }

    /// <summary>Jump List tasks for this app's taskbar button; each is a shell launch that reaches this primary.</summary>
    private static void PublishJumpList()
    {
        try { NativeJumpList.Publish(NativeActivation.AppUserModelId, Environment.ProcessPath!, [new NativeJumpListTask("New connection", "")]); }
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

    private void CloseAll()
    {
        foreach (var window in windows.ToList()) _ = window.CloseGracefully();
    }

    internal ConnectionWindow OpenWindow(string? address = null, bool connect = true)
    {
        var window = new ConnectionWindow(address, connect);
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
        exiting = true;
        await Clipboard.CloseAsync();
        systemClipboard?.Dispose();
        Displays.Dispose();
        displayChanges?.Dispose();
        try { await Runtime.ShutdownAsync(); }
        catch (Exception error) { System.Diagnostics.Trace.TraceError($"Runtime shutdown failed: {error}"); }
        Keyboard.Dispose();
        LaunchCredentials?.Clear();
        closeWait?.Unregister(null);
        closeRequest?.Dispose();
        Exit();
    }
}
