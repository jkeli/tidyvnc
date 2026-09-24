// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using TidyVNC.Native;
using TidyVNC.Native.Clipboard;
using TidyVNC.Native.Credentials;

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
    private readonly HashSet<ConnectionWindow> activeWindows = [];

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Dispatcher = new UiDispatcher(DispatcherQueue.GetForCurrentThread());
        Runtime = new NativeRuntime(Dispatcher);
        Keyboard = new KeyboardRouter();
        LaunchCredentials = CaptureLaunchCredentials();
        systemClipboard = new NativeWindowsClipboard();
        Clipboard = new NativeClipboardCoordinator(Dispatcher, systemClipboard);
        // vncviewer.exe (D9) signals this to close every window, e.g. on Ctrl+C.
        closeRequest = new EventWaitHandle(false, EventResetMode.ManualReset, $@"Local\TidyVNC-close-{Environment.ProcessId}");
        closeWait = ThreadPool.RegisterWaitForSingleObject(closeRequest, (_, _) => Dispatcher.TryEnqueue(CloseAll), null, -1, true);
        OpenWindow(StartupAddress());
    }

    /// <summary>
    /// The server address operand, through the shared parser. The console
    /// launcher has already reported syntax errors; connection files and the
    /// remaining parameters are applied in W4 (activation and documents).
    /// </summary>
    private static string? StartupAddress()
    {
        try
        {
            var invocation = NativeInvocation.Parse(Environment.GetCommandLineArgs().Skip(1).ToArray());
            var operand = invocation.Operand;
            return invocation.Action == NativeInvocationAction.Launch && invocation.Value("listen") != "on" &&
                   operand is not null && !operand.Contains('/', StringComparison.Ordinal) && !operand.Contains('\\', StringComparison.Ordinal)
                ? operand : null;
        }
        catch (Exception error) when (error is NativeInvocationFailure or NativeError)
        {
            return null;
        }
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

    internal ConnectionWindow OpenWindow(string? address = null)
    {
        var window = new ConnectionWindow(address);
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
        try { await Runtime.ShutdownAsync(); }
        catch (Exception error) { System.Diagnostics.Trace.TraceError($"Runtime shutdown failed: {error}"); }
        Keyboard.Dispose();
        LaunchCredentials?.Clear();
        closeWait?.Unregister(null);
        closeRequest?.Dispose();
        Exit();
    }
}
