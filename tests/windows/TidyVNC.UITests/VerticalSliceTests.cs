// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using System.Reflection;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Capturing;
using FlaUI.Core.Input;
using FlaUI.Core.WindowsAPI;
using FlaUI.UIA3;
using TidyVNC.Testing;

namespace TidyVNC.UITests;

/// <summary>
/// W3.6 vertical slice through the real app: connect, authenticate, render,
/// type, click, disconnect; close during authentication; two windows at once.
/// Controls are found by AutomationId (TESTING.md section 3).
/// </summary>
[TestClass]
[DoNotParallelize]
public sealed class VerticalSliceTests
{
    private static readonly TimeSpan Patience = TimeSpan.FromSeconds(20);

    public TestContext TestContext { get; set; } = null!;

    /// <summary>
    /// These tests show windows, take the foreground and inject a click and
    /// keys, so they run only when asked (TIDYVNC_UI_TESTS=1) and only on a
    /// desktop nobody has touched for a minute (TIDYVNC_UI_TESTS_FORCE=1
    /// skips the idle check). The check runs once per test run, because the
    /// tests' own injected input resets the idle clock. Injection also waits
    /// for the app to be in front.
    /// </summary>
    [TestInitialize]
    public void RequireIdleDesktop()
    {
        if (Environment.GetEnvironmentVariable("TIDYVNC_UI_TESTS") != "1")
            Assert.Inconclusive("UI automation takes over the desktop; set TIDYVNC_UI_TESTS=1 to run it");
        lock (DesktopGate)
        {
            desktopGranted ??= Environment.GetEnvironmentVariable("TIDYVNC_UI_TESTS_FORCE") == "1" || NativeMethods.IdleTime() >= TimeSpan.FromSeconds(60);
            if (desktopGranted != true)
                Assert.Inconclusive($"The desktop is in use (idle {NativeMethods.IdleTime().TotalSeconds:F0} s); not taking it over");
        }
    }

    private static readonly Lock DesktopGate = new();
    private static bool? desktopGranted;

    private static string AppPath =>
        typeof(VerticalSliceTests).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().First(a => a.Key == "TidyVncApp").Value!;

    private sealed class LaunchedApp(Process process) : IDisposable
    {
        public Process Process { get; } = process;
        public Application Application { get; } = Application.Attach(process.Id);
        public bool HasExited => Process.HasExited;
        public void Dispose()
        {
            // FlaUI may already have released the process object.
            try { if (!Process.HasExited) Process.Kill(); }
            catch (InvalidOperationException) { }
            Application.Dispose();
            Process.Dispose();
        }
    }

    /// <summary>
    /// The isolated state root for this run (TESTING.md section 2): stores,
    /// Credential Manager prefix, registry import root and log move with it,
    /// so the app never reads or writes the user's own settings.
    /// </summary>
    private static readonly string StateRoot = Path.Combine(Path.GetTempPath(), "tidyvnc-ui-" + Guid.NewGuid().ToString("N"));

    private static LaunchedApp Launch(string arguments, bool commandLine = false)
    {
        if (!File.Exists(AppPath)) Assert.Inconclusive($"Build the app first: {AppPath}");
        var start = new ProcessStartInfo(AppPath, arguments) { WorkingDirectory = Path.GetDirectoryName(AppPath)!, UseShellExecute = false };
        start.Environment["TIDYVNC_STATE_ROOT"] = StateRoot;
        // vncviewer.exe marks its launches this way (D8/D9); plain launches are shell-style.
        if (commandLine) start.Environment["TIDYVNC_COMMAND_LINE"] = "1";
        return new LaunchedApp(Process.Start(start)!);
    }

    [ClassCleanup]
    public static void RemoveStateRoot()
    {
        try { if (Directory.Exists(StateRoot)) Directory.Delete(StateRoot, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static T WaitFor<T>(Func<T?> probe, string what, TimeSpan? timeout = null) where T : class
    {
        var clock = Stopwatch.StartNew();
        while (clock.Elapsed < (timeout ?? Patience))
        {
            if (probe() is { } found) return found;
            Thread.Sleep(50);
        }
        Assert.Fail($"Timed out waiting for {what}");
        return null!;
    }

    private static void Until(Func<bool> condition, string what, TimeSpan? timeout = null)
        => WaitFor(() => condition() ? new object() : null, what, timeout);

    private static AutomationElement ById(AutomationElement root, string id, TimeSpan? timeout = null)
        => WaitFor(() => root.FindFirstDescendant(cf => cf.ByAutomationId(id)), id, timeout);

    private static void Exits(LaunchedApp app)
    {
        Until(() => app.HasExited, "the app to exit", TimeSpan.FromSeconds(30));
        Assert.AreEqual(0, app.Process.ExitCode, "exit code");
    }

    /// <summary>Input is injected only while our window is in the foreground.</summary>
    private static void RequireForeground(Window window)
    {
        var process = window.Properties.ProcessId.Value;
        window.SetForeground();
        Until(() => ForegroundProcess() == (uint)process, "the app in the foreground");
    }

    private static uint ForegroundProcess()
    {
        _ = NativeMethods.GetWindowThreadProcessId(NativeMethods.GetForegroundWindow(), out var process);
        return process;
    }

    private static void Answer(Window window, string secret)
    {
        var password = ById(window, "authentication.password");
        if (password.Patterns.Value.IsSupported && !password.Patterns.Value.Pattern.IsReadOnly.Value)
            password.Patterns.Value.Pattern.SetValue(secret);
        else
        {
            RequireForeground(window);
            password.Focus();
            Keyboard.Type(secret);
        }
        // The dialog's primary button (Authenticate) is the ContentDialog template part.
        ById(window, "PrimaryButton").AsButton().Invoke();
    }

    /// <summary>Dumps the UIA tree and a screenshot of every app window into the test results.</summary>
    private void Diagnose(LaunchedApp app, UIA3Automation automation)
    {
        if (app.HasExited) { TestContext.WriteLine($"App exited with {app.Process.ExitCode}"); return; }
        var directory = Path.Combine(TestContext.TestResultsDirectory ?? Path.GetTempPath(), TestContext.TestName ?? "ui");
        Directory.CreateDirectory(directory);
        var index = 0;
        foreach (var window in app.Application.GetAllTopLevelWindows(automation))
        {
            void Dump(AutomationElement element, int depth)
            {
                if (depth > 25) return;
                string id = "", name = "";
                try { id = element.Properties.AutomationId.ValueOrDefault ?? ""; name = element.Properties.Name.ValueOrDefault ?? ""; } catch (Exception) { }
                TestContext.WriteLine($"{new string(' ', depth * 2)}{element.Properties.ControlType.ValueOrDefault} id={id} name={name}");
                foreach (var child in element.FindAllChildren()) Dump(child, depth + 1);
            }
            Dump(window, 0);
            try { Capture.Element(window).ToFile(Path.Combine(directory, $"window-{index++}.png")); } catch (Exception) { }
        }
        TestContext.WriteLine($"Screenshots in {directory}");
    }

    private static (int R, int G, int B) PixelAt(AutomationElement element, double fx, double fy)
    {
        using var image = Capture.Element(element);
        var bitmap = image.Bitmap;
        var colour = bitmap.GetPixel((int)(bitmap.Width * fx), (int)(bitmap.Height * fy));
        return (colour.R, colour.G, colour.B);
    }

    private static bool Near((int R, int G, int B) actual, (byte R, byte G, byte B) expected, int tolerance = 6) =>
        Math.Abs(actual.R - expected.R) <= tolerance && Math.Abs(actual.G - expected.G) <= tolerance && Math.Abs(actual.B - expected.B) <= tolerance;

    /// <summary>
    /// W4.10 / D8: a second shell launch redirects to the primary and exits;
    /// a connection file opens for review in the primary without connecting;
    /// a command-line launch keeps its own process.
    /// </summary>
    [TestMethod]
    public void ShellLaunchesRedirectToThePrimaryAndCommandLineLaunchesDoNot()
    {
        using var automation = new UIA3Automation();
        using var primary = Launch("");
        try
        {
            WaitFor(() => primary.Application.GetMainWindow(automation, TimeSpan.FromSeconds(1)), "the primary window");
            using (var second = Launch(""))
            {
                Exits(second);
            }
            Until(() => primary.Application.GetAllTopLevelWindows(automation).Length == 2, "a second window in the primary");

            var file = Path.Combine(Path.GetTempPath(), $"tidyvnc-review-{Guid.NewGuid():N}.tidyvnc");
            File.WriteAllText(file, "TidyVNC Configuration file Version 1.0\nServerName=review.example::5999\n");
            try
            {
                using (var third = Launch($"\"{file}\""))
                {
                    Exits(third);
                }
                // The file opens on its review page (F01); nothing connects until it is accepted.
                var reviewing = WaitFor(() => primary.Application.GetAllTopLevelWindows(automation).FirstOrDefault(w =>
                    w.FindFirstDescendant(cf => cf.ByAutomationId("document.review.title")) is not null), "the connection file for review in the primary");
                StringAssert.Contains(ById(reviewing, "document.server").Name, "review.example::5999");
                Assert.AreEqual(3, primary.Application.GetAllTopLevelWindows(automation).Length);
                ById(reviewing, "document.accept").AsButton().Invoke();
                Until(() => reviewing.FindFirstDescendant(cf => cf.ByAutomationId("connection.endpoint"))?.AsTextBox().Text == "review.example::5999",
                    "the file's address installed after review");
                Assert.AreEqual("Ready", ById(reviewing, "connection.status").Name, "accepting a file never connects");
            }
            finally { File.Delete(file); }

            using var commandLine = Launch("", commandLine: true);
            WaitFor(() => commandLine.Application.GetMainWindow(automation, TimeSpan.FromSeconds(1)), "the command-line process's own window");
            Thread.Sleep(1000);
            Assert.IsFalse(commandLine.HasExited, "a command-line launch is never redirected");
            Assert.AreEqual(3, primary.Application.GetAllTopLevelWindows(automation).Length, "and never receives into the primary");
        }
        catch
        {
            Diagnose(primary, automation);
            throw;
        }
    }

    [TestMethod]
    public async Task ConnectAuthenticateRenderTypeClickAndDisconnect()
    {
        await using var server = new RfbTestServer(password: "secret");
        using var app = Launch(server.Endpoint, commandLine: true);
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            Answer(window, "secret");
            Until(() => server.AuthenticatedClients == 1, "authentication");
            Until(() => window.Title.Contains(server.Name, StringComparison.Ordinal), "the connected title");

            // Render: the test desktop's background fills the centre; FixedRatio
            // letterboxes the 4:3 desktop in the wider window.
            var desktop = ById(window, "desktop.view");
            Until(() => Near(PixelAt(desktop, 0.5, 0.5), RfbTestServer.Background), "the remote desktop on screen");
            var bar = PixelAt(desktop, 0.01, 0.5);
            Assert.IsTrue(bar is { R: < 8, G: < 8, B: < 8 }, $"letterbox {bar}");

            // Click: focus and a left press/release near the remote centre.
            RequireForeground(window);
            var bounds = desktop.BoundingRectangle;
            Mouse.Click(new System.Drawing.Point(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2));
            Until(() => server.Pointers.Any(p => p.Buttons == 1), "a left button press");
            var press = server.Pointers.First(p => p.Buttons == 1);
            Assert.IsTrue(Math.Abs(press.X - 512) < 16 && Math.Abs(press.Y - 384) < 16, $"pointer at {press.X},{press.Y}");
            Until(() => server.Pointers.Reverse().First().Buttons == 0, "the release");

            // Type: a letter and Escape reach the server as press/release pairs.
            RequireForeground(window);
            Keyboard.Type('q');
            Keyboard.Type(VirtualKeyShort.ESCAPE);
            Until(() => server.Keys.Contains(new RfbTestServer.KeyRecord(false, 0xff1b)), "Escape released");
            var keys = server.Keys.ToArray();
            CollectionAssert.IsSubsetOf(new[] { new RfbTestServer.KeyRecord(true, 0x71), new RfbTestServer.KeyRecord(false, 0x71),
                new RfbTestServer.KeyRecord(true, 0xff1b), new RfbTestServer.KeyRecord(false, 0xff1b) }, keys, string.Join(", ", keys));
            // The server paints the last key into its bottom stripe: frames keep flowing.
            Until(() => Near(PixelAt(desktop, 0.5, 0.985), (0x00, 0xff, 0x1b), 40), "the Escape stripe on screen");

            ById(window, "connection.disconnect").AsButton().Invoke();
            Until(() => ById(window, "connection.status").Name == "Disconnected", "Disconnected");
            window.Close();
            Exits(app);
        }
        catch
        {
            // Bounded: UIA calls into a wedged app can block for a long time.
            try { _ = Task.Run(() => Diagnose(app, automation)).Wait(TimeSpan.FromSeconds(30)); }
            catch (Exception) { }
            throw;
        }
    }

    [TestMethod]
    public async Task ClosingDuringAuthenticationExitsCleanly()
    {
        await using var server = new RfbTestServer(password: "secret");
        using var app = Launch(server.Endpoint, commandLine: true);
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            ById(window, "authentication.password");
            window.Close();
            Exits(app);
            Assert.AreEqual(0, server.AuthenticatedClients);
        }
        catch
        {
            // Bounded: UIA calls into a wedged app can block for a long time.
            try { _ = Task.Run(() => Diagnose(app, automation)).Wait(TimeSpan.FromSeconds(30)); }
            catch (Exception) { }
            throw;
        }
    }

    /// <summary>
    /// W5.8 / D02: -FullScreen enters full screen on the window's display once
    /// connected, with the window chrome gone; the viewer shortcut
    /// (Ctrl+Alt+Enter) leaves it without sending Enter to the server.
    /// </summary>
    [TestMethod]
    public async Task FullScreenFromTheCommandLineAndTheShortcutLeavesIt()
    {
        await using var server = new RfbTestServer();
        using var app = Launch("-FullScreen " + server.Endpoint, commandLine: true);
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            Until(() => server.AuthenticatedClients == 1, "the connection");
            var handle = window.Properties.NativeWindowHandle.Value;
            Until(() => NativeMethods.WindowRect(handle) == NativeMethods.MonitorRect(handle), "the window filling its display");
            Until(() => window.FindFirstDescendant(cf => cf.ByAutomationId("menu.file")) is null or { IsOffscreen: true }, "the menu bar hidden");
            var desktop = ById(window, "desktop.view");
            Until(() => Near(PixelAt(desktop, 0.5, 0.5), RfbTestServer.Background), "the remote desktop on screen");

            RequireForeground(window);
            var bounds = desktop.BoundingRectangle;
            Mouse.Click(new System.Drawing.Point(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2));
            Until(() => server.Pointers.Any(p => p.Buttons == 1), "the desktop focused");
            Keyboard.TypeSimultaneously(VirtualKeyShort.CONTROL, VirtualKeyShort.ALT, VirtualKeyShort.RETURN);
            Until(() => NativeMethods.WindowRect(handle) != NativeMethods.MonitorRect(handle), "the window restored");
            Until(() => ById(window, "menu.file") is { IsOffscreen: false }, "the menu bar back");
            Assert.IsFalse(server.Keys.Any(k => k.KeySym is 0xff0d or 0xff8d), "Enter stays local");
            window.Close();
            Exits(app);
        }
        catch
        {
            try { _ = Task.Run(() => Diagnose(app, automation)).Wait(TimeSpan.FromSeconds(30)); }
            catch (Exception) { }
            throw;
        }
    }

    [TestMethod]
    public async Task TwoWindowsConnectAtOnce()
    {
        await using var server = new RfbTestServer();
        using var app = Launch(server.Endpoint, commandLine: true);
        using var automation = new UIA3Automation();
        try
        {
            var first = app.Application.GetMainWindow(automation, Patience)!;
            Until(() => server.AuthenticatedClients == 1, "the first connection");
            // File > New connection.
            ById(first, "menu.file").Patterns.ExpandCollapse.Pattern.Expand();
            WaitFor(() => first.FindFirstDescendant(cf => cf.ByAutomationId("menu.newConnection")) ??
                          automation.GetDesktop().FindFirstDescendant(cf => cf.ByAutomationId("menu.newConnection")), "New connection").AsMenuItem().Invoke();
            var second = WaitFor(() => app.Application.GetAllTopLevelWindows(automation).FirstOrDefault(w => w.Title == "TidyVNC"), "the second window");
            var endpoint = ById(second, "connection.endpoint").AsTextBox();
            endpoint.Text = server.Endpoint;
            ById(second, "connection.connect").AsButton().Invoke();
            Until(() => server.AuthenticatedClients == 2, "the second connection");
            Until(() => app.Application.GetAllTopLevelWindows(automation).Count(w => w.Title.Contains(server.Name, StringComparison.Ordinal)) == 2,
                  "both windows connected");
            foreach (var window in app.Application.GetAllTopLevelWindows(automation)) window.Close();
            Exits(app);
        }
        catch
        {
            // Bounded: UIA calls into a wedged app can block for a long time.
            try { _ = Task.Run(() => Diagnose(app, automation)).Wait(TimeSpan.FromSeconds(30)); }
            catch (Exception) { }
            throw;
        }
    }
}

internal static partial class NativeMethods
{
    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    internal static partial IntPtr GetForegroundWindow();

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    internal static partial uint GetWindowThreadProcessId(IntPtr window, out uint process);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct LastInputInfo
    {
        public uint Size;
        public uint Time;
    }

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static partial bool GetLastInputInfo(ref LastInputInfo info);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left, Top, Right, Bottom;
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct MonitorInfo
    {
        public uint Size;
        public Rect Monitor, Work;
        public uint Flags;
    }

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static partial bool GetWindowRect(IntPtr window, out Rect rect);

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    private static partial IntPtr MonitorFromWindow(IntPtr window, uint flags);

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "GetMonitorInfoW")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static partial bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

    internal static (int, int, int, int) WindowRect(IntPtr window) =>
        GetWindowRect(window, out var rect) ? (rect.Left, rect.Top, rect.Right, rect.Bottom) : default;

    /// <summary>The full bounds of the display holding most of the window.</summary>
    internal static (int, int, int, int) MonitorRect(IntPtr window)
    {
        var info = new MonitorInfo { Size = 40 };
        return GetMonitorInfo(MonitorFromWindow(window, 2), ref info) ? (info.Monitor.Left, info.Monitor.Top, info.Monitor.Right, info.Monitor.Bottom) : (-1, -1, -1, -1);
    }

    /// <summary>Time since the last keyboard or mouse input in this session.</summary>
    internal static TimeSpan IdleTime()
    {
        var info = new LastInputInfo { Size = 8 };
        return GetLastInputInfo(ref info) ? TimeSpan.FromMilliseconds(unchecked((uint)Environment.TickCount - info.Time)) : TimeSpan.Zero;
    }
}
