// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using TidyVNC.Native;

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

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Dispatcher = new UiDispatcher(DispatcherQueue.GetForCurrentThread());
        Runtime = new NativeRuntime(Dispatcher);
        Keyboard = new KeyboardRouter();
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
        if (windows.Count > 0 || exiting) return;
        exiting = true;
        try { await Runtime.ShutdownAsync(); }
        catch (Exception error) { System.Diagnostics.Trace.TraceError($"Runtime shutdown failed: {error}"); }
        Keyboard.Dispose();
        closeWait?.Unregister(null);
        closeRequest?.Dispose();
        Exit();
    }
}
