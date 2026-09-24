// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native;

namespace TidyVNC.Cli;

/// <summary>
/// vncviewer.exe (DECISIONS.md D9). Syntax errors, help and version never
/// start the GUI; a launch runs TidyVNC.exe with the same arguments, working
/// directory and environment and returns its exit code. Ctrl+C and Ctrl+Break
/// ask the GUI to close its windows through its per-process close event.
/// </summary>
internal static class Program
{
    /// <summary>The GUI's close-request event name (App.xaml.cs opens the same).</summary>
    internal static string CloseEventName(int processId) => $@"Local\TidyVNC-close-{processId}";

    private static int Main(string[] args)
    {
        // D6: a copied folder on older Windows says why instead of failing later.
        if (!TidyVNC.Native.Platform.NativeWindowsVersion.IsSupported(TidyVNC.Native.Platform.NativeWindowsVersion.CurrentBuild))
            return Fail(TidyVNC.Native.Platform.NativeWindowsVersion.RefusalText);
        NativeInvocation invocation;
        try
        {
            invocation = NativeInvocation.Parse(args);
        }
        catch (NativeInvocationFailure failure)
        {
            return Fail(failure.Message);
        }
        catch (Exception error) when (error is NativeError or DllNotFoundException or EntryPointNotFoundException)
        {
            return Fail("Unable to initialize the native command line.");
        }
        if (NativeInvocationTerminal.For(invocation) is { } terminal)
        {
            Console.Error.Write(terminal.Text);
            return terminal.ExitCode;
        }

        var gui = Path.Combine(AppContext.BaseDirectory, "TidyVNC.exe");
        if (!File.Exists(gui)) return Fail("TidyVNC.exe was not found beside vncviewer.exe.");
        var start = new ProcessStartInfo(gui) { UseShellExecute = false, WorkingDirectory = Environment.CurrentDirectory };
        foreach (var argument in args) start.ArgumentList.Add(argument);
        // Marks a command-line launch: its own process, never redirected to or registered as the primary (D8).
        start.Environment[TidyVNC.Native.Activation.NativeActivation.CommandLineVariable] = "1";
        using var process = Process.Start(start);
        if (process is null) return Fail("TidyVNC.exe could not be started.");
        using var close = new EventWaitHandle(false, EventResetMode.ManualReset, CloseEventName(process.Id));
        Console.CancelKeyPress += (_, e) =>
        {
            // Keep waiting: the GUI closes its windows and exits with its own code.
            e.Cancel = true;
            close.Set();
        };
        process.WaitForExit();
        return process.ExitCode;
    }

    private static int Fail(string message)
    {
        Console.Error.Write($"vncviewer: {message}\n");
        return 1;
    }
}
