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

    private static LaunchedApp Launch(string arguments, bool commandLine = false, string? stateRoot = null, string? language = null,
                                      string? windowsBuild = null, (string Name, string Value)[]? environment = null)
    {
        if (!File.Exists(AppPath)) Assert.Inconclusive($"Build the app first: {AppPath}");
        var start = new ProcessStartInfo(AppPath, arguments) { WorkingDirectory = Path.GetDirectoryName(AppPath)!, UseShellExecute = false };
        start.Environment["TIDYVNC_STATE_ROOT"] = stateRoot ?? StateRoot;
        // vncviewer.exe marks its launches this way (D8/D9); plain launches are shell-style.
        if (commandLine) start.Environment["TIDYVNC_COMMAND_LINE"] = "1";
        if (language is not null) start.Environment["TIDYVNC_UI_LANGUAGE"] = language;
        if (windowsBuild is not null) start.Environment["TIDYVNC_TEST_WINDOWS_BUILD"] = windowsBuild;
        foreach (var (name, value) in environment ?? []) start.Environment[name] = value;
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

    /// <summary>A menu bar item, opening its menu again until the item appears (menus can close while the app settles).</summary>
    private static FlaUI.Core.AutomationElements.MenuItem MenuItem(Window window, UIA3Automation automation, string menu, string item) =>
        WaitFor(() =>
        {
            if (window.FindFirstDescendant(cf => cf.ByAutomationId(item)) is { } found) return found;
            var bar = ById(window, menu);
            try
            {
                // Expanding an open menu can close it: open a collapsed one; a menu that reports
                // itself open without the item (it closed after the last command) is collapsed first.
                var pattern = bar.Patterns.ExpandCollapse.Pattern;
                if (pattern.ExpandCollapseState.Value == FlaUI.Core.Definitions.ExpandCollapseState.Expanded) pattern.Collapse();
                else pattern.Expand();
            }
            catch (Exception error) when (error is FlaUI.Core.Exceptions.FlaUIException or System.Runtime.InteropServices.COMException
                                              or System.ComponentModel.Win32Exception) { return null; }
            // Give a menu that just opened a moment to show its items before toggling it again.
            var opened = Stopwatch.StartNew();
            while (opened.Elapsed < TimeSpan.FromSeconds(1))
            {
                if (window.FindFirstDescendant(cf => cf.ByAutomationId(item)) is { } shown) return shown;
                Thread.Sleep(50);
            }
            return automation.GetDesktop().FindFirstDescendant(cf => cf.ByAutomationId(item));
        }, item).AsMenuItem();

    /// <summary>Opens a menu; a window that has just appeared may refuse until its content is ready.</summary>
    private static void Expand(AutomationElement menu) => Until(() =>
    {
        try { menu.Patterns.ExpandCollapse.Pattern.Expand(); return true; }
        catch (Exception error) when (error is FlaUI.Core.Exceptions.FlaUIException or System.Runtime.InteropServices.COMException
                                          or System.ComponentModel.Win32Exception) { return false; }
    }, "the menu to open");

    /// <summary>Input is injected only while our window is in the foreground.</summary>
    /// <summary>A left click there, reached with real mouse movement (see NativeMethods.MovePointer).</summary>
    private static void ClickAt(System.Drawing.Point point)
    {
        NativeMethods.MovePointer(point);
        Thread.Sleep(100);
        Mouse.Click();
    }

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
            // Screen pixels are only this window's while nothing covers it (a new window can open behind others).
            RequireForeground(window);
            Until(() => Near(PixelAt(desktop, 0.5, 0.5), RfbTestServer.Background), "the remote desktop on screen");
            var bar = PixelAt(desktop, 0.01, 0.5);
            Assert.IsTrue(bar is { R: < 8, G: < 8, B: < 8 }, $"letterbox {bar}");

            // Click: focus and a left press/release near the remote centre.
            RequireForeground(window);
            var bounds = desktop.BoundingRectangle;
            ClickAt(new System.Drawing.Point(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2));
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
    public async Task LargeRemoteCursorsAreDrawnOverTheDesktop()
    {
        // A 16x16 cursor on a 2x2 desktop scaled to the window is thousands of device pixels across,
        // larger than any Windows cursor, so the view draws it over the desktop (DESKTOP.md section 3).
        var red = ((byte)220, (byte)30, (byte)30);
        await using var server = new RfbTestServer(width: 2, height: 2, cursor: (16, 16, red));
        using var app = Launch(server.Endpoint, commandLine: true);
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            Until(() => window.Title.Contains(server.Name, StringComparison.Ordinal), "the connected title");
            var desktop = ById(window, "desktop.view");
            // Screen pixels are only this window's while nothing covers it (a new window can open behind others).
            RequireForeground(window);
            Until(() => Near(PixelAt(desktop, 0.5, 0.5), RfbTestServer.Background), "the remote desktop on screen");

            // The pointer at the centre: the cursor's top-left (its hotspot) is there, drawn down and right.
            var bounds = desktop.BoundingRectangle;
            var centre = new System.Drawing.Point(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2);
            NativeMethods.MovePointer(new System.Drawing.Point(centre.X - 20, centre.Y - 20));
            NativeMethods.MovePointer(centre);
            // Where the cursor really is: over a remote session, the client's own pointer can move it back.
            var placed = NativeMethods.CursorPosition();
            Until(() => Near(PixelAt(desktop, 0.55, 0.55), red),
                  $"the cursor drawn at the pointer (view {bounds}, window {window.BoundingRectangle}, pointer {centre}, placed {placed}, now {NativeMethods.CursorPosition()}, pixel {PixelAt(desktop, 0.55, 0.55)})");
            Assert.IsTrue(Near(PixelAt(desktop, 0.45, 0.45), RfbTestServer.Background), "nothing above and left of the hotspot");
            // Clipped to the desktop: the square desktop is letterboxed in the wider window, and the bar stays black.
            var bar = PixelAt(desktop, 0.995, 0.6);
            Assert.IsTrue(bar is { R: < 8, G: < 8, B: < 8 }, $"letterbox beside the cursor {bar}");

            // Leaving the view removes it.
            NativeMethods.MovePointer(new System.Drawing.Point(bounds.X + bounds.Width / 2, bounds.Y - 40));
            Until(() => Near(PixelAt(desktop, 0.55, 0.55), RfbTestServer.Background), "the cursor gone with the pointer");
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

    /// <summary>
    /// W3.5: the shell's address, Connect, authentication dialog and Disconnect, without screen
    /// capture (the render and input half is ConnectAuthenticateRenderTypeClickAndDisconnect, W3.6).
    /// </summary>
    [TestMethod]
    public async Task AuthenticateAndDisconnect()
    {
        await using var server = new RfbTestServer(password: "secret");
        using var app = Launch("");
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            ById(window, "connection.endpoint").AsTextBox().Text = server.Endpoint;
            ById(window, "connection.connect").AsButton().Invoke();
            Answer(window, "secret");
            Until(() => server.AuthenticatedClients == 1, "authentication");
            Until(() => window.Title.Contains(server.Name, StringComparison.Ordinal), "the connected title");
            Assert.IsNotNull(ById(window, "desktop.view"), "the desktop view");
            ById(window, "connection.disconnect").AsButton().Invoke();
            Until(() => ById(window, "connection.status").Name == "Disconnected", "Disconnected");
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
            ClickAt(new System.Drawing.Point(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2));
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

    /// <summary>
    /// W5.9 / P01-P05: File > Settings opens the connection defaults; a
    /// section edit is only a draft until Apply, which writes preferences.json
    /// in the isolated state root; Cancel edits returns to what was saved.
    /// </summary>
    [TestMethod]
    public void SettingsApplyAndCancelEdits()
    {
        using var app = Launch("");
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            MenuItem(window, automation, "menu.file", "menu.settings").Invoke();
            var settings = WaitFor(() => app.Application.GetAllTopLevelWindows(automation).FirstOrDefault(w => w.Title == "Settings"), "the Settings window");

            ById(settings, "preferences.section.connection").Patterns.SelectionItem.Pattern.Select();
            var shared = ById(settings, "preferences.connection.shared").AsComboBox();
            Until(() => shared.IsEnabled, "the defaults read");
            shared.Select(1); // On
            var apply = ById(settings, "preferences.apply").AsButton();
            Until(() => apply.IsEnabled, "Apply enabled");
            var preferences = Path.Combine(StateRoot, "preferences.json");
            Assert.IsFalse(File.Exists(preferences) && File.ReadAllText(preferences).Contains("\"Shared\"", StringComparison.Ordinal), "a draft until Apply");
            apply.Invoke();
            Until(() => File.Exists(preferences) && File.ReadAllText(preferences).Contains("\"Shared\": \"on\"", StringComparison.Ordinal), "Shared saved");
            Until(() => !apply.IsEnabled, "nothing left to apply");

            // Cancel edits returns to what was saved.
            ById(settings, "preferences.connection.retry").AsComboBox().Select(2); // Off
            Until(() => apply.IsEnabled, "a new edit");
            ById(settings, "preferences.cancel").AsButton().Invoke();
            Until(() => ById(settings, "preferences.connection.retry").AsComboBox().SelectedItem?.Text?.StartsWith("Built-in", StringComparison.Ordinal) == true,
                  "the edit discarded");
            Assert.IsFalse(File.ReadAllText(preferences).Contains("ReconnectOnError", StringComparison.Ordinal));
            settings.Close();
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

    /// <summary>
    /// W5.10 / P07-P08: File > Saved profiles creates a profile with an
    /// address and a settings override, opens a connection window for it
    /// without connecting, and deletes it through the confirmation flyout.
    /// </summary>
    [TestMethod]
    public void SavedProfilesCreateOpenAndDelete()
    {
        using var app = Launch("");
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            MenuItem(window, automation, "menu.file", "menu.savedProfiles").Invoke();
            var library = WaitFor(() => app.Application.GetAllTopLevelWindows(automation).FirstOrDefault(w => w.Title == "Saved profiles"), "the profiles window");
            var create = ById(library, "profiles.new").AsButton();
            Until(() => create.IsEnabled, "profiles read");
            create.Invoke();
            ById(library, "profiles.name").AsTextBox().Text = "UI test profile";
            ById(library, "profiles.endpoint").AsTextBox().Text = "127.0.0.1::5999";
            ById(library, "profiles.section.connection").Patterns.SelectionItem.Pattern.Select();
            ById(library, "profiles.connection.shared").AsComboBox().Select(1); // On
            var save = ById(library, "profiles.save").AsButton();
            Until(() => save.IsEnabled, "Save enabled");
            save.Invoke();
            var history = Path.Combine(StateRoot, "profiles-history.json");
            Until(() => File.Exists(history) && File.ReadAllText(history).Contains("UI test profile", StringComparison.Ordinal), "the profile saved");
            StringAssert.Contains(File.ReadAllText(history), "\"Shared\": \"on\"");

            var open = ById(library, "profiles.open").AsButton();
            Until(() => open.IsEnabled, "Open connection enabled");
            open.Invoke();
            Until(() => app.Application.GetAllTopLevelWindows(automation).Any(w =>
                w.FindFirstDescendant(cf => cf.ByAutomationId("connection.endpoint"))?.AsTextBox().Text == "127.0.0.1::5999"), "a window for the profile");

            // Activating the library window reloads it, briefly disabling Delete.
            var delete = ById(library, "profiles.delete").AsButton();
            Until(() =>
            {
                try { delete.Invoke(); return true; }
                catch (FlaUI.Core.Exceptions.ElementNotEnabledException) { return false; }
            }, "Delete invoked");
            WaitFor(() => library.FindFirstDescendant(cf => cf.ByAutomationId("profiles.confirmDelete")) ??
                          automation.GetDesktop().FindFirstDescendant(cf => cf.ByAutomationId("profiles.confirmDelete")), "the delete confirmation").AsButton().Invoke();
            Until(() => !File.ReadAllText(history).Contains("UI test profile", StringComparison.Ordinal), "the profile deleted");
            foreach (var each in app.Application.GetAllTopLevelWindows(automation)) each.Close();
            Exits(app);
        }
        catch
        {
            try { _ = Task.Run(() => Diagnose(app, automation)).Wait(TimeSpan.FromSeconds(30)); }
            catch (Exception) { }
            throw;
        }
    }

    /// <summary>
    /// W5.11 / M05-M07, K: the viewer chord + M opens the Connection menu over
    /// the desktop without sending M; Hold Ctrl and Send Ctrl+Alt+Del from the
    /// menus reach the server; Ctrl+N inside the desktop goes to the server
    /// rather than opening a window.
    /// </summary>
    [TestMethod]
    public async Task ConnectionMenuCommandsReachTheServer()
    {
        await using var server = new RfbTestServer();
        using var app = Launch(server.Endpoint, commandLine: true);
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            Until(() => server.AuthenticatedClients == 1, "the connection");
            var desktop = ById(window, "desktop.view");
            RequireForeground(window);
            var bounds = desktop.BoundingRectangle;
            ClickAt(new System.Drawing.Point(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2));
            Until(() => server.Pointers.Any(p => p.Buttons == 1), "the desktop focused");

            // Ctrl+N inside the desktop is remote input.
            Keyboard.TypeSimultaneously(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_N);
            Until(() => server.Keys.Contains(new RfbTestServer.KeyRecord(true, 0x6e)), "n reaches the server");
            Assert.AreEqual(1, app.Application.GetAllTopLevelWindows(automation).Length, "no new window from inside the desktop");

            // The chord + M opens the Connection menu; M stays local. Left Ctrl and left Alt: FlaUI sends ALT
            // as the extended (right) Alt, which with Ctrl is AltGr, not the chord.
            Keyboard.TypeSimultaneously(VirtualKeyShort.LCONTROL, VirtualKeyShort.LMENU, VirtualKeyShort.KEY_M);
            var hold = WaitFor(() => automation.GetDesktop().FindFirstDescendant(cf => cf.ByAutomationId("desktop.holdControl")), "the context menu");
            Assert.IsFalse(server.Keys.Any(k => k.KeySym is 0x6d or 0x4d), "M stays local");
            hold.Patterns.Toggle.Pattern.Toggle(); // A toggle menu item.
            Until(() => server.Keys.Contains(new RfbTestServer.KeyRecord(true, 0xffe3)), "Ctrl held on the server");

            MenuItem(window, automation, "menu.connection", "desktop.controlAltDelete").Invoke();
            Until(() => server.Keys.Contains(new RfbTestServer.KeyRecord(false, 0xffff)), "Delete released on the server");
            var keys = server.Keys.ToArray();
            var delete = Array.IndexOf(keys, new RfbTestServer.KeyRecord(true, 0xffff));
            Assert.IsTrue(delete > 0 && Array.IndexOf(keys, new RfbTestServer.KeyRecord(true, 0xffe9)) is >= 0 and var alt && alt < delete, string.Join(", ", keys));
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

    /// <summary>
    /// W5.12 / L07-L08: vncviewer -listen starts a listener window at once; a
    /// server dialling in waits until accepted, then gets its own connection
    /// window; Stop listening leaves that connection open.
    /// </summary>
    [TestMethod]
    public async Task ListenAcceptsAReverseConnection()
    {
        await using var server = new RfbTestServer();
        // "-listen 0" would read as listen=off (the retained boolean parsing), so pick a free port.
        var probe = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        probe.Start();
        var free = ((System.Net.IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        using var app = Launch("-listen " + free.ToString(System.Globalization.CultureInfo.InvariantCulture), commandLine: true);
        using var automation = new UIA3Automation();
        try
        {
            var listener = WaitFor(() => app.Application.GetAllTopLevelWindows(automation).FirstOrDefault(w => w.Title == "Listen for connections"),
                "the listener window");
            Until(() => ById(listener, "listener.status").Name == "Listening for connections", "listening");
            var address = WaitFor(() => listener.FindAllDescendants().Select(e => e.Properties.Name.ValueOrDefault)
                .FirstOrDefault(name => name?.StartsWith("IPv4 port ", StringComparison.Ordinal) == true), "the address");
            var port = int.Parse(address["IPv4 port ".Length..], System.Globalization.CultureInfo.InvariantCulture);
            Assert.AreEqual(free, port, "the -listen operand is the port");
            // W12: listening on every address brings the Windows Firewall notice (SERVICES.md section 10).
            StringAssert.Contains(WaitFor(() => listener.FindFirstDescendant(cf => cf.ByAutomationId("listener.firewall")), "the firewall notice")
                .FindAllDescendants().Select(e => e.Properties.Name.ValueOrDefault).FirstOrDefault(n => n?.Contains("Firewall", StringComparison.Ordinal) == true) ?? "",
                "Firewall");

            await server.ConnectReverseAsync(port);
            var accept = WaitFor(() => listener.FindAllDescendants().FirstOrDefault(e =>
                e.Properties.AutomationId.ValueOrDefault?.StartsWith("listener.accept.", StringComparison.Ordinal) == true), "the incoming connection");
            Assert.AreEqual(0, server.AuthenticatedClients, "nothing happens before Accept");
            accept.AsButton().Invoke();
            Until(() => server.AuthenticatedClients == 1, "the accepted connection");
            // An incoming connection's window is titled for the incoming connection, not the server.
            bool Connected() => app.Application.GetAllTopLevelWindows(automation).Any(w => w.Title != "Listen for connections" &&
                w.FindFirstDescendant(cf => cf.ByAutomationId("connection.status"))?.Name == "Connected");
            Until(Connected, "its window");

            ById(listener, "listener.stop").AsButton().Invoke();
            Until(() => ById(listener, "listener.status").Name == "Listener stopped", "stopped");
            Until(() => listener.FindFirstDescendant(cf => cf.ByAutomationId("listener.firewall")) is not { IsOffscreen: false },
                  "the notice gone when stopped");
            Assert.IsTrue(Connected(), "the connection stays");
            foreach (var each in app.Application.GetAllTopLevelWindows(automation)) each.Close();
            Exits(app);
        }
        catch
        {
            try { _ = Task.Run(() => Diagnose(app, automation)).Wait(TimeSpan.FromSeconds(30)); }
            catch (Exception) { }
            throw;
        }
    }

    /// <summary>
    /// W5.12 / L07, F01: vncviewer -listen &lt;file&gt; reviews the file in the listener
    /// window before anything binds; accepting listens on the file's ServerName
    /// port, and the accepted connection is made with the file's settings.
    /// </summary>
    [TestMethod]
    public async Task ListenWithAFileReviewsItFirst()
    {
        await using var server = new RfbTestServer();
        var probe = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        probe.Start();
        var free = ((System.Net.IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        var folder = Path.Combine(Path.GetTempPath(), "tidyvnc-ui-listen-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var file = Path.Combine(folder, "listen.tidyvnc");
        File.WriteAllText(file, $"TidyVNC Configuration file Version 1.0\nServerName={free}\nShared=off\nFuture=1\n");
        using var app = Launch($"-listen \"{file}\"", commandLine: true);
        using var automation = new UIA3Automation();
        try
        {
            var listener = WaitFor(() => app.Application.GetAllTopLevelWindows(automation).FirstOrDefault(w => w.Title == "Listen for connections"),
                "the listener window");
            ById(listener, "document.review.title");
            Assert.IsTrue(listener.FindFirstDescendant(cf => cf.ByAutomationId("listener.status")) is null or { IsOffscreen: true },
                "the listener controls wait for the review");
            ById(listener, "document.accept").AsButton().Invoke();
            Until(() => ById(listener, "listener.status").Name == "Listening for connections", "listening");
            await server.ConnectReverseAsync(free);
            var accept = WaitFor(() => listener.FindAllDescendants().FirstOrDefault(e =>
                e.Properties.AutomationId.ValueOrDefault?.StartsWith("listener.accept.", StringComparison.Ordinal) == true), "the incoming connection");
            accept.AsButton().Invoke();
            Until(() => server.AuthenticatedClients == 1, "the accepted connection");
            foreach (var each in app.Application.GetAllTopLevelWindows(automation)) each.Close();
            Exits(app);
        }
        catch
        {
            try { _ = Task.Run(() => Diagnose(app, automation)).Wait(TimeSpan.FromSeconds(30)); }
            catch (Exception) { }
            throw;
        }
        finally
        {
            try { Directory.Delete(folder, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    /// <summary>
    /// W5.15 / Q01, Q03: Connection information shows the server and live
    /// values; Show connection statistics puts the statistics over the desktop
    /// and takes them away again.
    /// </summary>
    [TestMethod]
    public async Task ConnectionInformationAndStatistics()
    {
        await using var server = new RfbTestServer();
        using var app = Launch(server.Endpoint, commandLine: true);
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            Until(() => server.AuthenticatedClients == 1, "the connection");
            MenuItem(window, automation, "menu.connection", "desktop.information").Invoke();
            var dialog = ById(window, "information.dialog");
            Until(() => dialog.FindFirstDescendant(cf => cf.ByName(server.Endpoint)) is not null, "the server row");
            Until(() => dialog.FindFirstDescendant(cf => cf.ByName("RFB 3.8")) is not null, "the protocol row");
            ById(window, "CloseButton").AsButton().Invoke();
            Until(() => window.FindFirstDescendant(cf => cf.ByAutomationId("information.dialog")) is null, "the dialog closed");

            MenuItem(window, automation, "menu.connection", "desktop.statistics").Patterns.Toggle.Pattern.Toggle();
            Until(() => window.FindFirstDescendant(cf => cf.ByAutomationId("connection.statistics")) is { IsOffscreen: false }, "statistics shown");
            MenuItem(window, automation, "menu.connection", "desktop.statistics").Patterns.Toggle.Pattern.Toggle();
            Until(() => window.FindFirstDescendant(cf => cf.ByAutomationId("connection.statistics")) is null or { IsOffscreen: true }, "statistics hidden");
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

    /// <summary>
    /// W5.17 / H01-H03: Help shows the guide and the bundled licence; About
    /// shows the version and architecture and links to the licence.
    /// </summary>
    [TestMethod]
    public void HelpAndAbout()
    {
        using var app = Launch("");
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            MenuItem(window, automation, "menu.help", "menu.helpContents").Invoke();
            var help = WaitFor(() => app.Application.GetAllTopLevelWindows(automation).FirstOrDefault(w => w.Title == "TidyVNC help"), "the help window");
            ById(help, "help.topic.licence").Patterns.SelectionItem.Pattern.Select();
            Until(() => ById(help, "help.document").Name.Contains("GNU GENERAL PUBLIC LICENSE", StringComparison.Ordinal), "the licence text");
            help.Close();

            // About (C08, H01): its own window, selectable text, closed with Esc, and a link to the licence.
            Window About()
            {
                MenuItem(window, automation, "menu.help", "menu.about").Invoke();
                return WaitFor(() => app.Application.GetAllTopLevelWindows(automation).FirstOrDefault(w => w.Title == "About TidyVNC"), "the About window");
            }
            var about = About();
            var version = ById(about, "about.version");
            var architecture = System.Runtime.InteropServices.RuntimeInformation.OSArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "ARM64" : "x64";
            StringAssert.Contains(version.Name, architecture);
            Assert.IsTrue(version.Patterns.Text.IsSupported, "the version is selectable text");
            StringAssert.Contains(ById(about, "about.copyright").Name, "Copyright");
            Assert.IsNotNull(ById(about, "about.credits"));
            ById(about, "about.licences").Patterns.Invoke.Pattern.Invoke();
            var licence = WaitFor(() => app.Application.GetAllTopLevelWindows(automation).FirstOrDefault(w => w.Title == "TidyVNC help"), "help at the licence");
            Until(() => ById(licence, "help.document").Name.Contains("GNU GENERAL PUBLIC LICENSE", StringComparison.Ordinal), "the licence from About");
            foreach (var each in app.Application.GetAllTopLevelWindows(automation)) each.Close();
            Exits(app);
        }
        catch
        {
            try { _ = Task.Run(() => Diagnose(app, automation)).Wait(TimeSpan.FromSeconds(30)); }
            catch (Exception) { }
            throw;
        }
    }

    /// <summary>
    /// T07: File > Saved server keys and Saved certificate decisions open one window per kind. Each
    /// loads (empty in a fresh state root). Ask again… for a typed destination, confirmed in its
    /// flyout, records that destination as forgotten, so it will ask again.
    /// </summary>
    [TestMethod]
    public void SavedTrustLibrariesForgetADestination()
    {
        using var app = Launch("");
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            foreach (var (item, title) in new[] { ("menu.savedServerKeys", "Saved Server Keys"), ("menu.savedCertificateDecisions", "Saved Certificate Decisions") })
            {
                window.Focus();
                MenuItem(window, automation, "menu.file", item).Invoke();
                var library = WaitFor(() => app.Application.GetAllTopLevelWindows(automation).FirstOrDefault(w =>
                    string.Equals(w.Title, title, StringComparison.OrdinalIgnoreCase)), title);
                Until(() => library.FindAllDescendants().Any(e => e.Properties.Name.ValueOrDefault == "No saved destination decisions."), "the loaded, empty list");
                ById(library, "trustLibrary.destination").AsTextBox().Text = "trust.example::5901";
                var ask = ById(library, "trustLibrary.askAgain").AsButton();
                Until(() => ask.IsEnabled, "Ask again enabled for a valid destination");
                ask.Invoke();
                WaitFor(() => app.Application.GetAllTopLevelWindows(automation).SelectMany(w => w.FindAllDescendants())
                    .FirstOrDefault(e => e.Properties.AutomationId.ValueOrDefault == "trustLibrary.askAgain.confirm"), "the confirmation").AsButton().Invoke();
                Until(() => ById(library, "trustLibrary.message").Name.StartsWith("Forgot the saved key", StringComparison.Ordinal), "forgotten");
                Until(() => library.FindAllDescendants().Any(e => e.Properties.Name.ValueOrDefault == "trust.example::5901"), "the destination listed");
                library.Close();
            }
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

    /// <summary>
    /// W6.11: entering and leaving full screen moves the desktop between the window and full-screen
    /// surfaces (a presenter and swap chain attached to a new panel each time). Fifteen round trips must
    /// not grow the app's handles or threads beyond a one-off step.
    /// </summary>
    [TestMethod]
    public async Task FullScreenCyclesDoNotLeak()
    {
        await using var server = new RfbTestServer();
        using var app = Launch(server.Endpoint, commandLine: true);
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            Until(() => server.AuthenticatedClients == 1, "the connection");
            var handle = window.Properties.NativeWindowHandle.Value;
            var desktop = ById(window, "desktop.view");
            RequireForeground(window);
            var bounds = desktop.BoundingRectangle;
            ClickAt(new System.Drawing.Point(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2));
            Until(() => server.Pointers.Any(p => p.Buttons == 1), "the desktop focused");
            (int Handles, int Threads) Usage()
            {
                // The Debug app collects garbage first (its test-only collect event), so only what is still
                // referenced counts.
                using (var collect = EventWaitHandle.OpenExisting($@"Local\TidyVNC-collect-{app.Process.Id}"))
                using (var collected = EventWaitHandle.OpenExisting($@"Local\TidyVNC-collected-{app.Process.Id}"))
                {
                    collect.Set();
                    Assert.IsTrue(collected.WaitOne(TimeSpan.FromSeconds(30)), "the app collected");
                }
                using var process = System.Diagnostics.Process.GetProcessById(app.Process.Id);
                return (process.HandleCount, process.Threads.Count);
            }
            void RoundTrip(int index)
            {
                Keyboard.TypeSimultaneously(VirtualKeyShort.CONTROL, VirtualKeyShort.ALT, VirtualKeyShort.RETURN);
                Until(() => NativeMethods.WindowRect(handle) == NativeMethods.MonitorRect(handle), $"full screen {index}");
                Thread.Sleep(300);
                Keyboard.TypeSimultaneously(VirtualKeyShort.CONTROL, VirtualKeyShort.ALT, VirtualKeyShort.RETURN);
                Until(() => NativeMethods.WindowRect(handle) != NativeMethods.MonitorRect(handle), $"restored {index}");
                Thread.Sleep(300);
            }
            for (var i = 0; i < 3; i++) RoundTrip(i); // Warm-up: first full screen creates its host once.
            var trips = int.TryParse(Environment.GetEnvironmentVariable("TIDYVNC_STRESS_CYCLES"), out var requested) && requested >= 15 ? requested : 15;
            var before = Usage();
            var samples = new List<string>();
            for (var i = 0; i < trips; i++)
            {
                RoundTrip(i + 3);
                if (i % 15 == 14) { Thread.Sleep(1000); var sample = Usage(); samples.Add($"{i + 1}: {sample.Handles}/{sample.Threads}"); }
            }
            var after = Usage();
            TestContext.WriteLine($"{trips} full-screen round trips: handles {before.Handles} -> {after.Handles}, threads {before.Threads} -> {after.Threads}; " +
                                  string.Join(", ", samples));
            Assert.IsTrue(after.Handles - before.Handles <= 40, $"handles grew {before.Handles} -> {after.Handles}: {string.Join(", ", samples)}");
            Assert.IsTrue(after.Threads - before.Threads <= 8, $"threads grew {before.Threads} -> {after.Threads}");
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

    /// <summary>
    /// W6.11: connection windows (each with its desktop view, timers and presenter) opened and closed
    /// repeatedly release what they held. Every closed window's objects must be collected, and the handles
    /// left behind are compared with About windows opened and closed in the same process with the same
    /// title bar: Windows App SDK 1.8 leaves composition resources behind for every closed window that
    /// extends its content into the title bar (about 50 handles, mostly Section and DxgkCompositionObject,
    /// reproduced with the About window alone), which the app cannot release.
    /// </summary>
    [TestMethod]
    public void ConnectionWindowsOpenAndCloseWithoutLeaks()
    {
        using var app = Launch("", environment: [("TIDYVNC_TEST_ABOUT_TITLE_BAR", "1")]);
        var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            var handle = window.Properties.NativeWindowHandle.Value;
            IntPtr Second() => NativeMethods.TopLevelWindows((uint)app.Process.Id).FirstOrDefault(w => w != handle && NativeMethods.Title(w) == "TidyVNC");
            IntPtr About() => NativeMethods.FindWindow(null, "About TidyVNC");
            void OpenAndClose(string menu, string item, Func<IntPtr> find, string what)
            {
                window.Focus();
                MenuItem(window, automation, menu, item).Invoke();
                // Found and closed through Win32, not UI Automation, so the test holds none of its elements.
                Until(() => find() != IntPtr.Zero, what);
                // Up long enough to lay out and render: a window closed at once never reached the state that leaked.
                Thread.Sleep(1000);
                NativeMethods.PostMessage(find(), 0x0010, 0, 0); // WM_CLOSE
                Until(() => find() == IntPtr.Zero, what + " closed");
            }
            Dictionary<string, int> Settled()
            {
                _ = LiveAfterReleasingAutomation(app, ref automation);
                // Released XAML and composition objects free their native resources on later dispatcher turns.
                _ = LiveAfterReleasingAutomation(app, ref automation);
                window = app.Application.GetMainWindow(automation, Patience)!;
                return NativeMethods.HandleCounts(app.Process.Id);
            }
            for (var i = 0; i < 3; i++) OpenAndClose("menu.file", "menu.newConnection", Second, $"window {i}");
            OpenAndClose("menu.help", "menu.about", About, "About");
            var start = Settled();
            const int Windows = 20;
            for (var i = 0; i < Windows; i++) OpenAndClose("menu.help", "menu.about", About, $"About {i}");
            var afterAbout = Settled();
            for (var i = 0; i < Windows; i++) OpenAndClose("menu.file", "menu.newConnection", Second, $"window {i}");
            var afterConnections = Settled();
            var live = LiveAfterReleasingAutomation(app, ref automation);
            static string Detail(Dictionary<string, int> from, Dictionary<string, int> to) =>
                string.Join(" ", to.Keys.Union(from.Keys).Select(key => (key, Delta: to.GetValueOrDefault(key) - from.GetValueOrDefault(key)))
                    .Where(e => e.Delta != 0).OrderByDescending(e => e.Delta).Select(e => $"{e.key}{e.Delta:+#;-#}"));
            var baseline = afterAbout.Values.Sum() - start.Values.Sum();
            var growth = afterConnections.Values.Sum() - afterAbout.Values.Sum();
            var report = $"{Windows} About windows: {baseline:+#;-#;0} ({Detail(start, afterAbout)}); " +
                         $"{Windows} connection windows: {growth:+#;-#;0} ({Detail(afterAbout, afterConnections)}); live {live}";
            TestContext.WriteLine(report);
            StringAssert.Contains(live, "ConnectionWindow: 1", $"closed windows are released: {live}");
            Assert.IsTrue(growth <= Math.Max(baseline, 0) + 40, $"connection windows left more handles than About windows: {report}");
            CloseThroughEvent(app);
        }
        catch
        {
            try { _ = Task.Run(() => Diagnose(app, automation)).Wait(TimeSpan.FromSeconds(30)); }
            catch (Exception) { }
            throw;
        }
        finally
        {
            automation.Dispose();
        }
    }

    /// <summary>W6.11: the About window opened and closed repeatedly is released each time.</summary>
    [TestMethod]
    public void AboutWindowsAreReleased()
    {
        using var app = Launch("");
        var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            for (var i = 0; i < 10; i++)
            {
                window.Focus();
                MenuItem(window, automation, "menu.help", "menu.about").Invoke();
                // Found and closed through Win32, not UI Automation: an automation client keeps the providers
                // of the elements it has touched (and so the window) alive in the app.
                Until(() => NativeMethods.FindWindow(null, "About TidyVNC") != IntPtr.Zero, $"About {i}");
                Thread.Sleep(1000); // Laid out and rendered before it closes.
                var about = NativeMethods.FindWindow(null, "About TidyVNC");
                NativeMethods.PostMessage(about, 0x0010, 0, 0); // WM_CLOSE
                Until(() => NativeMethods.FindWindow(null, "About TidyVNC") == IntPtr.Zero, $"About {i} closed");
            }
            var live = LiveAfterReleasingAutomation(app, ref automation);
            Assert.IsFalse(live.Contains("AboutWindow", StringComparison.Ordinal), $"closed About windows are released: {live}");
            CloseThroughEvent(app);
        }
        catch
        {
            try { _ = Task.Run(() => Diagnose(app, automation)).Wait(TimeSpan.FromSeconds(30)); }
            catch (Exception) { }
            throw;
        }
        finally
        {
            automation.Dispose();
        }
    }

    /// <summary>
    /// The Debug app's live objects after a collection. UI Automation clients hold references to the app's
    /// automation providers (and so to elements and windows) until they release them, so the test's own
    /// automation objects are released and collected first; a new automation object is returned.
    /// </summary>
    private static string LiveAfterReleasingAutomation(LaunchedApp app, ref UIA3Automation automation)
    {
        automation.Dispose();
        for (var i = 0; i < 3; i++) { GC.Collect(); GC.WaitForPendingFinalizers(); }
        Thread.Sleep(2000);
        using (var collect = EventWaitHandle.OpenExisting($@"Local\TidyVNC-collect-{app.Process.Id}"))
        using (var collected = EventWaitHandle.OpenExisting($@"Local\TidyVNC-collected-{app.Process.Id}"))
        {
            collect.Set();
            Assert.IsTrue(collected.WaitOne(TimeSpan.FromSeconds(30)), "the app collected");
        }
        automation = new UIA3Automation();
        return File.ReadAllText(Path.Combine(StateRoot, "live-objects.txt"));
    }

    /// <summary>Closes every window through the app's close event (the launcher's Ctrl+C route) and waits for exit.</summary>
    private static void CloseThroughEvent(LaunchedApp app)
    {
        using (var close = EventWaitHandle.OpenExisting($@"Local\TidyVNC-close-{app.Process.Id}")) close.Set();
        Exits(app);
    }

    /// <summary>C08: About closes from the keyboard (Esc), and opening it again brings back one window.</summary>
    [TestMethod]
    public void AboutClosesWithEscape()
    {
        using var app = Launch("");
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            MenuItem(window, automation, "menu.help", "menu.about").Invoke();
            var about = WaitFor(() => app.Application.GetAllTopLevelWindows(automation).FirstOrDefault(w => w.Title == "About TidyVNC"), "the About window");
            RequireForeground(about);
            Keyboard.Type(VirtualKeyShort.ESCAPE);
            Until(() => !app.Application.GetAllTopLevelWindows(automation).Any(w => w.Title == "About TidyVNC"), "Esc closes About");
            window.Focus();
            MenuItem(window, automation, "menu.help", "menu.about").Invoke();
            MenuItem(window, automation, "menu.help", "menu.about").Invoke();
            Until(() => app.Application.GetAllTopLevelWindows(automation).Count(w => w.Title == "About TidyVNC") == 1, "one About window");
            foreach (var each in app.Application.GetAllTopLevelWindows(automation)) each.Close();
            Exits(app);
        }
        catch
        {
            try { _ = Task.Run(() => Diagnose(app, automation)).Wait(TimeSpan.FromSeconds(30)); }
            catch (Exception) { }
            throw;
        }
    }

    /// <summary>
    /// W5.14 / F05-F08: File > Save connection file as reviews what the file
    /// cannot preserve, then the Windows save dialog writes a .tidyvnc file
    /// that holds the address and no secrets.
    /// </summary>
    [TestMethod]
    public void SaveConnectionFileAsReviewsLossesAndWrites()
    {
        var folder = Path.Combine(Path.GetTempPath(), "tidyvnc-ui-export-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var file = Path.Combine(folder, "saved.tidyvnc");
        using var app = Launch("");
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            var address = ById(window, "connection.endpoint");
            address.Patterns.Value.Pattern.SetValue("export.example::5907");
            Until(() => ById(window, "connection.endpoint").AsTextBox().Text == "export.example::5907", "the address");
            MenuItem(window, automation, "menu.file", "menu.saveConnectionFile").Invoke();
            StringAssert.Contains(ById(window, "document.export.server").Name, "export.example::5907");
            WaitFor(() => window.FindFirstDescendant(cf => cf.ByName(
                "Failure-alert settings are not supported by this connection-file format. The receiving viewer will use its own error-alert policy.")),
                "the omitted settings");
            var dialog = ById(window, "document.export.dialog");
            dialog.FindFirstDescendant(cf => cf.ByAutomationId("PrimaryButton"))!.AsButton().Invoke();
            var save = WaitFor(() => app.Application.GetAllTopLevelWindows(automation).Concat(window.FindAllChildren(cf => cf.ByControlType(FlaUI.Core.Definitions.ControlType.Window)))
                .FirstOrDefault(w => w.Name == "Save connection file"), "the save dialog");
            var name = WaitFor(() => save.FindFirstDescendant(cf => cf.ByAutomationId("1001").And(cf.ByControlType(FlaUI.Core.Definitions.ControlType.Edit))), "the file name box");
            name.Patterns.Value.Pattern.SetValue(file);
            save.FindFirstDescendant(cf => cf.ByAutomationId("1").And(cf.ByControlType(FlaUI.Core.Definitions.ControlType.Button)))!.AsButton().Invoke();
            Until(() => File.Exists(file), "the saved file");
            Until(() => window.FindFirstDescendant(cf => cf.ByName("Saved saved.tidyvnc")) is not null, "the saved status");
            var text = File.ReadAllText(file);
            StringAssert.Contains(text, "ServerName=export.example::5907");
            Assert.IsFalse(text.Contains("Password", StringComparison.OrdinalIgnoreCase), "no secrets");
            window.Close();
            Exits(app);
        }
        catch
        {
            try { _ = Task.Run(() => Diagnose(app, automation)).Wait(TimeSpan.FromSeconds(30)); }
            catch (Exception) { }
            throw;
        }
        finally
        {
            try { Directory.Delete(folder, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    /// <summary>
    /// W5.19 / V02, W18: the desktop view is an Image named Remote desktop
    /// whose pan is the Scroll pattern; Invoke focuses it. The desktop is
    /// larger than the window at 100% scale, so it scrolls both ways.
    /// </summary>
    [TestMethod]
    public async Task DesktopViewScrollsForAssistiveTechnology()
    {
        await using var server = new RfbTestServer(2000, 1500);
        using var app = Launch("-ScalingFactor=100 " + server.Endpoint, commandLine: true);
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            Until(() => server.AuthenticatedClients == 1, "the connection");
            var desktop = ById(window, "desktop.view");
            Assert.AreEqual(FlaUI.Core.Definitions.ControlType.Image, desktop.ControlType);
            Assert.AreEqual("Remote desktop", desktop.Name);
            StringAssert.Contains(desktop.HelpText, "Click to focus");
            var scroll = desktop.Patterns.Scroll.Pattern;
            Until(() => scroll.HorizontallyScrollable.Value && scroll.VerticallyScrollable.Value, "a desktop larger than the view");
            Assert.AreEqual(0, scroll.HorizontalScrollPercent.Value, 0.01);
            Assert.IsTrue(scroll.HorizontalViewSize.Value is > 0 and < 100, "part of the desktop is visible");
            scroll.SetScrollPercent(100, -1);
            Until(() => Math.Abs(scroll.HorizontalScrollPercent.Value - 100) < 0.01, "panned to the right edge");
            Assert.AreEqual(0, scroll.VerticalScrollPercent.Value, 0.01, "-1 keeps the vertical position");
            scroll.Scroll(FlaUI.Core.Definitions.ScrollAmount.LargeDecrement, FlaUI.Core.Definitions.ScrollAmount.LargeIncrement);
            Until(() => scroll.HorizontalScrollPercent.Value < 100 && scroll.VerticalScrollPercent.Value > 0, "a page left and down");
            desktop.Patterns.Invoke.Pattern.Invoke();
            Until(() => desktop.Properties.HasKeyboardFocus.ValueOrDefault, "the desktop focused");
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

    /// <summary>
    /// W5.19 / UX.md section 10: F6 moves from the address row to the toolbar
    /// and on to the desktop area; Shift+F6 goes back.
    /// </summary>
    [TestMethod]
    public void F6MovesBetweenTheWindowAreas()
    {
        using var app = Launch("");
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            RequireForeground(window);
            ById(window, "connection.endpoint").Focus();
            string Focused() => automation.FocusedElement()?.Properties.AutomationId.ValueOrDefault ?? "";
            Until(() => Focused() == "connection.endpoint", "the address focused");
            Keyboard.Type(VirtualKeyShort.F6);
            Until(() => Focused() == "connection.recent", "the toolbar focused");
            Keyboard.Type(VirtualKeyShort.F6);
            Until(() => Focused() == "desktop.view", "the desktop area focused");
            // The desktop keeps F6 for the remote computer, so go back with focus on the toolbar.
            ById(window, "connection.recent").Focus();
            Keyboard.TypeSimultaneously(VirtualKeyShort.SHIFT, VirtualKeyShort.F6);
            Until(() => Focused() == "connection.endpoint", "back to the address row");
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

    /// <summary>
    /// W5.21 / W15 (D6): below Windows 11 (build 22000) the app says so and
    /// exits before opening a window. The build is simulated.
    /// </summary>
    [TestMethod]
    public void OlderWindowsIsRefused()
    {
        using var app = Launch("", windowsBuild: "19045");
        using var automation = new UIA3Automation();
        var message = WaitFor(() => app.Application.GetAllTopLevelWindows(automation).FirstOrDefault(w => w.Title == "TidyVNC"), "the refusal");
        Assert.IsNotNull(message.FindFirstDescendant(cf => cf.ByName(
            "This version of TidyVNC requires Windows 11. On earlier versions of Windows, use the classic TidyVNC viewer (vncviewer) instead.")),
            "the message names the classic viewer");
        message.FindFirstDescendant(cf => cf.ByControlType(FlaUI.Core.Definitions.ControlType.Button))!.AsButton().Invoke();
        Until(() => app.HasExited, "the app to exit", TimeSpan.FromSeconds(30));
        Assert.AreEqual(1, app.Process.ExitCode, "exit code");
    }

    /// <summary>
    /// W5.18 / D20: in the qps-ploc (about 40% longer) and qps-plocm (mirrored)
    /// pseudo-locales, every top-level window opened from the menus loads the
    /// pseudo catalog, fits its minimum size without controls escaping the
    /// window, and mirrors in qps-plocm. Screenshots go to the test results
    /// for the visual review. Needs `python apps/windows/strings.py pseudo`
    /// and a Debug build.
    /// </summary>
    [TestMethod]
    [DataRow("qps-ploc")]
    [DataRow("qps-plocm")]
    public void PseudoLocaleWindowsFitTheirMinimumSize(string language)
    {
        var catalog = Path.Combine(Path.GetDirectoryName(AppPath)!, "TidyVNC.pri");
        // The PRI names its language qualifiers in UTF-16.
        if (!File.Exists(catalog) || !File.ReadAllText(catalog, System.Text.Encoding.Unicode).Contains(language, StringComparison.OrdinalIgnoreCase))
            Assert.Inconclusive("Run `python apps/windows/strings.py pseudo` and build Debug first");
        var mirrored = language == "qps-plocm";
        var directory = Path.Combine(TestContext.TestResultsDirectory ?? Path.GetTempPath(), "pseudo-" + language);
        Directory.CreateDirectory(directory);
        using var app = Launch("", language: language);
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            var file = ById(window, "menu.file");
            var help = ById(window, "menu.help");
            StringAssert.Contains(file.Name, mirrored ? "‮" : "[", "the pseudo catalog is loaded");
            if (mirrored) Assert.IsTrue(file.BoundingRectangle.Left > help.BoundingRectangle.Left, "the menu bar mirrors");
            else Assert.IsTrue(file.BoundingRectangle.Left < help.BoundingRectangle.Left, "the menu bar reads left to right");

            var problems = new List<string>();
            void Check(Window each, string name)
            {
                // Shrink to the minimum size the window allows.
                if (each.Patterns.Transform.IsSupported && each.Patterns.Transform.Pattern.CanResize.Value) each.Patterns.Transform.Pattern.Resize(100, 100);
                Thread.Sleep(500);
                var frame = each.BoundingRectangle;
                try { Capture.Element(each).ToFile(Path.Combine(directory, name + ".png")); } catch (Exception) { }
                foreach (var element in each.FindAllDescendants())
                {
                    try
                    {
                        if (element.Properties.IsOffscreen.ValueOrDefault) continue;
                        var type = element.Properties.ControlType.ValueOrDefault;
                        if (type is not (FlaUI.Core.Definitions.ControlType.Text or FlaUI.Core.Definitions.ControlType.Button or FlaUI.Core.Definitions.ControlType.Edit
                                or FlaUI.Core.Definitions.ControlType.CheckBox or FlaUI.Core.Definitions.ControlType.ComboBox or FlaUI.Core.Definitions.ControlType.MenuItem))
                            continue;
                        var box = element.BoundingRectangle;
                        if (box.IsEmpty) continue;
                        if (box.Left < frame.Left - 1 || box.Right > frame.Right + 1)
                            problems.Add($"{name}: {type} {element.Properties.AutomationId.ValueOrDefault} extends beyond the window ({box} in {frame})");
                    }
                    catch (Exception error) when (error is FlaUI.Core.Exceptions.FlaUIException or System.Runtime.InteropServices.COMException) { }
                }
            }
            Check(window, "connection");
            // A window can close between being listed and being asked for its handle (Windows App SDK 2.x lists a
            // short-lived one here); such a window is simply not a candidate.
            IntPtr HandleOf(Window w)
            {
                try { return w.Properties.NativeWindowHandle.ValueOrDefault; }
                catch (Exception error) when (error is FlaUI.Core.Exceptions.FlaUIException or System.Runtime.InteropServices.COMException) { return IntPtr.Zero; }
            }
            Window Open(string menu, string item)
            {
                var before = app.Application.GetAllTopLevelWindows(automation).Select(HandleOf).ToHashSet();
                // A menu opened in an inactive window closes at once; the last window closed may have left none active.
                try { window.Focus(); }
                catch (Exception error) when (error is FlaUI.Core.Exceptions.FlaUIException or System.Runtime.InteropServices.COMException) { }
                MenuItem(window, automation, menu, item).Invoke();
                return WaitFor(() => app.Application.GetAllTopLevelWindows(automation).FirstOrDefault(w => HandleOf(w) is var h && h != IntPtr.Zero && !before.Contains(h)),
                    item + " window");
            }
            foreach (var (menu, item) in new[] { ("menu.file", "menu.settings"), ("menu.file", "menu.savedProfiles"), ("menu.file", "menu.listen"),
                                                 ("menu.file", "menu.importDefaults"), ("menu.help", "menu.helpContents") })
            {
                var opened = Open(menu, item);
                Check(opened, item);
                opened.Close();
            }
            Assert.AreEqual(0, problems.Count, string.Join(Environment.NewLine, problems));
            TestContext.WriteLine($"Screenshots in {directory}");
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

    /// <summary>
    /// W5.13 / F09-F12: with TigerVNC settings in the (isolated) registry and
    /// no native defaults, the connection window offers an import; the review
    /// imports them into preferences.json marked as imported from the registry.
    /// </summary>
    [TestMethod]
    public void FirstUseOfferImportsTigerVncDefaults()
    {
        var root = Path.Combine(Path.GetTempPath(), "tidyvnc-ui-import-" + Guid.NewGuid().ToString("N"));
        // The app's isolated registry root for this state root (NativeStateRoot.RunId).
        var run = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(Path.GetFullPath(root).ToUpperInvariant())))[..12]
            .ToLowerInvariant();
        var key = $@"Software\TidyVNC-Test\{run}";
        using (var viewer = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(key + @"\Software\TigerVNC\vncviewer", writable: true))
            viewer.SetValue("Shared", 1, Microsoft.Win32.RegistryValueKind.DWord);
        using var app = Launch("", stateRoot: root);
        using var automation = new UIA3Automation();
        try
        {
            var window = app.Application.GetMainWindow(automation, Patience)!;
            Until(() => ById(window, "import.offer") is { IsOffscreen: false }, "the import offer");
            ById(window, "import.firstUse").AsButton().Invoke();
            var import = WaitFor(() => app.Application.GetAllTopLevelWindows(automation).FirstOrDefault(w => w.Title == "Import connection defaults"), "the import window");
            ById(import, "import.source.tigervnc").AsButton().Invoke();
            var approve = ById(import, "import.approve").AsButton();
            Until(() => approve.IsEnabled, "the review");
            approve.Invoke();
            var preferences = Path.Combine(root, "preferences.json");
            Until(() => File.Exists(preferences) && File.ReadAllText(preferences).Contains("\"importedFrom\": \"registry\"", StringComparison.Ordinal),
                "the imported defaults");
            StringAssert.Contains(File.ReadAllText(preferences), "\"Shared\": \"on\"");
            ById(import, "import.done").AsButton().Invoke();
            Until(() => window.FindFirstDescendant(cf => cf.ByAutomationId("import.offer")) is null or { IsOffscreen: true }, "the offer gone");
            window.Close();
            Exits(app);
        }
        catch
        {
            try { _ = Task.Run(() => Diagnose(app, automation)).Wait(TimeSpan.FromSeconds(30)); }
            catch (Exception) { }
            throw;
        }
        finally
        {
            Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(key, throwOnMissingSubKey: false);
            try { Directory.Delete(root, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
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
            MenuItem(first, automation, "menu.file", "menu.newConnection").Invoke();
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
    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static partial bool IsWindowVisible(IntPtr window);

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "GetWindowTextW")]
    private static unsafe partial int GetWindowText(IntPtr window, char* text, int length);

    /// <summary>Visible top-level windows of a process.</summary>
    internal static List<IntPtr> TopLevelWindows(uint process)
    {
        var found = new List<IntPtr>();
        EnumWindows((window, _) =>
        {
            if (IsWindowVisible(window) && GetWindowThreadProcessId(window, out var owner) != 0 && owner == process) found.Add(window);
            return true;
        }, IntPtr.Zero);
        return found;
    }

    internal static unsafe string Title(IntPtr window)
    {
        var text = stackalloc char[256];
        var length = GetWindowText(window, text, 256);
        return length > 0 ? new string(text, 0, length) : "";
    }

    [System.Runtime.InteropServices.LibraryImport("ntdll.dll")]
    private static unsafe partial int NtQuerySystemInformation(int informationClass, void* buffer, int length, out int needed);

    [System.Runtime.InteropServices.LibraryImport("ntdll.dll")]
    private static unsafe partial int NtQueryObject(IntPtr handle, int informationClass, void* buffer, int length, out int needed);

    /// <summary>A process's open handles counted by kernel object type (leak tests).</summary>
    internal static unsafe Dictionary<string, int> HandleCounts(int processId)
    {
        // ObjectTypesInformation (3): a count, then OBJECT_TYPE_INFORMATION records, each followed by its name.
        var names = new Dictionary<int, string>();
        for (var size = 1 << 16; ; size *= 2)
        {
            var types = new byte[size];
            fixed (byte* data = types)
            {
                if (NtQueryObject(IntPtr.Zero, 3, data, size, out _) != 0)
                {
                    if (size >= 1 << 24) throw new InvalidOperationException("object types");
                    continue;
                }
                var count = *(uint*)data;
                var offset = IntPtr.Size;
                for (var i = 0; i < count; i++)
                {
                    var length = *(ushort*)(data + offset);
                    var maximum = *(ushort*)(data + offset + 2);
                    var name = *(char**)(data + offset + 8);
                    names[data[offset + 0x5A]] = name is null ? "?" : new string(name, 0, length / 2);
                    offset += 0x68 + ((maximum + 7) & ~7);
                }
            }
            break;
        }
        // SystemExtendedHandleInformation (64): a count, then 40-byte entries (x64).
        for (var size = 1 << 22; ; size *= 2)
        {
            var handles = new byte[size];
            fixed (byte* data = handles)
            {
                var status = NtQuerySystemInformation(64, data, size, out var needed);
                if (status == unchecked((int)0xC0000004)) { size = Math.Max(size, needed); continue; } // STATUS_INFO_LENGTH_MISMATCH
                if (status != 0) throw new InvalidOperationException($"handles {status:x8}");
                var counts = new Dictionary<string, int>();
                var total = (long)*(nuint*)data;
                for (long i = 0; i < total; i++)
                {
                    var entry = data + 16 + i * 40;
                    if ((long)*(nuint*)(entry + 8) != processId) continue;
                    var type = names.GetValueOrDefault(*(ushort*)(entry + 30), "?");
                    counts[type] = counts.GetValueOrDefault(type) + 1;
                }
                return counts;
            }
        }
    }

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static unsafe partial bool GetCursorPos(int* point);

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    private static unsafe partial uint SendInput(uint count, void* inputs, int size);

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    private static partial int GetSystemMetrics(int index);

    /// <summary>
    /// Moves the pointer there in a few steps with absolute mouse input. FlaUI's Mouse.MoveTo places the
    /// cursor without mouse input, which WinUI's pointer events do not report, so hover never happens.
    /// </summary>
    internal static unsafe void MovePointer(System.Drawing.Point target)
    {
        var start = CursorPosition();
        int left = GetSystemMetrics(76), top = GetSystemMetrics(77), width = GetSystemMetrics(78), height = GetSystemMetrics(79);
        var input = stackalloc byte[40]; // INPUT (x64): type, then MOUSEINPUT at offset 8
        for (var step = 1; step <= 8; step++)
        {
            var x = start.X + (target.X - start.X) * step / 8;
            var y = start.Y + (target.Y - start.Y) * step / 8;
            new Span<byte>(input, 40).Clear();
            *(uint*)input = 0; // INPUT_MOUSE
            *(int*)(input + 8) = (int)(((long)(x - left) * 65535 + width / 2) / (width - 1));
            *(int*)(input + 12) = (int)(((long)(y - top) * 65535 + height / 2) / (height - 1));
            *(uint*)(input + 20) = 0x0001 | 0x8000 | 0x4000; // MOVE | ABSOLUTE | VIRTUALDESK
            _ = SendInput(1, input, 40);
            Thread.Sleep(15);
        }
    }

    internal static unsafe System.Drawing.Point CursorPosition()
    {
        var point = stackalloc int[2];
        return GetCursorPos(point) ? new System.Drawing.Point(point[0], point[1]) : default;
    }

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "FindWindowW", StringMarshalling = System.Runtime.InteropServices.StringMarshalling.Utf16)]
    internal static partial IntPtr FindWindow(string? className, string title);

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "PostMessageW")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    internal static partial bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

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
