// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.Windows.AppLifecycle;
using TidyVNC.Native.Activation;

namespace TidyVNC;

/// <summary>
/// Process entry (SERVICES.md section 12, DECISIONS.md D8/D9). Shell launches
/// (Start menu, Explorer file opens, Jump List tasks) register or find the
/// primary instance; a second shell launch redirects its activation there
/// and exits. Launches from vncviewer.exe are marked by an inherited
/// environment variable, keep their own process (they may own launch
/// credentials) and never redirect or register.
/// </summary>
internal static partial class Program
{
    private const string PrimaryKey = "primary";
    private static readonly ConcurrentQueue<AppActivationArguments> Pending = new();
    private static Action<AppActivationArguments>? deliver;

    /// <summary>True when vncviewer.exe started this process.</summary>
    internal static bool CommandLineLaunch { get; private set; }

    [LibraryImport("ole32.dll")]
    private static partial int CoWaitForMultipleObjects(uint flags, uint timeout, uint count, [In] nint[] handles, out uint index);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AllowSetForegroundWindow(uint processId);

    [LibraryImport("user32.dll", EntryPoint = "MessageBoxW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int MessageBox(nint owner, string text, string caption, uint type);

    /// <summary>Windows 11 is build 22000 (DECISIONS.md D6).</summary>
    internal const int FirstSupportedBuild = 22000;

    /// <summary>The Windows build; TIDYVNC_TEST_WINDOWS_BUILD lets the refusal be tested on Windows 11.</summary>
    private static int WindowsBuild =>
        int.TryParse(Environment.GetEnvironmentVariable("TIDYVNC_TEST_WINDOWS_BUILD"), out var build) ? build : Environment.OSVersion.Version.Build;

    [STAThread]
    private static int Main()
    {
        CommandLineLaunch = NativeActivation.TakeCommandLineMarker();
        if (WindowsBuild < FirstSupportedBuild)
        {
            // D6 / W15: older Windows keeps the FLTK viewer; say so and stop before any window.
            const uint IconError = 0x10;
            _ = MessageBox(0, Strings.Get("app.windows.11.required"), "TidyVNC", IconError);
            return 1;
        }
        WinRT.ComWrappersSupport.InitializeComWrappers();
        try { NativeActivation.ApplyAppUserModelId(); }
        catch (COMException error) { System.Diagnostics.Trace.TraceWarning($"AppUserModelID not set: {error.HResult:x8}"); }
        if (!CommandLineLaunch)
        {
            var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            var primary = AppInstance.FindOrRegisterForKey(PrimaryKey);
            if (!primary.IsCurrent)
            {
                Redirect(activation, primary);
                return 0;
            }
            primary.Activated += (_, redirected) => Receive(redirected);
        }
        Microsoft.UI.Xaml.Application.Start(start =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App();
        });
        return 0;
    }

    /// <summary>The primary process: redirected activations arrive on a background thread.</summary>
    private static void Receive(AppActivationArguments activation)
    {
        Pending.Enqueue(activation);
        Volatile.Read(ref deliver)?.Invoke(activation);
    }

    /// <summary>The app takes over delivery once its UI thread exists; earlier activations are replayed.</summary>
    internal static void DeliverActivations(Action<AppActivationArguments> handler)
    {
        Volatile.Write(ref deliver, _ =>
        {
            while (Pending.TryDequeue(out var next)) handler(next);
        });
        while (Pending.TryDequeue(out var next)) handler(next);
    }

    /// <summary>
    /// Sends this launch to the primary and lets it take the foreground. The
    /// wait pumps COM, as RedirectActivationToAsync requires on an STA thread.
    /// </summary>
    private static void Redirect(AppActivationArguments activation, AppInstance primary)
    {
        using var done = new ManualResetEvent(false);
        AllowSetForegroundWindow(primary.ProcessId);
        _ = Task.Run(() =>
        {
            try { primary.RedirectActivationToAsync(activation).AsTask().Wait(TimeSpan.FromSeconds(30)); }
            catch (AggregateException error) { System.Diagnostics.Trace.TraceWarning($"Redirection failed: {error.InnerException?.GetType().Name}"); }
            finally { done.Set(); }
        });
        CoWaitForMultipleObjects(0, 0xFFFFFFFF, 1, [done.SafeWaitHandle.DangerousGetHandle()], out _);
    }
}
