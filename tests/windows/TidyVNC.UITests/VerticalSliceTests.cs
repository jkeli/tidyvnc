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

    /// <summary>A menu bar item, opening its menu again until the item appears (menus can close while the app settles).</summary>
    private static FlaUI.Core.AutomationElements.MenuItem MenuItem(Window window, UIA3Automation automation, string menu, string item) =>
        WaitFor(() =>
        {
            if (window.FindFirstDescendant(cf => cf.ByAutomationId(item)) is { } found) return found;
            var bar = ById(window, menu);
            try
            {
                // Expanding an open menu can close it; only a collapsed one is opened.
                if (bar.Patterns.ExpandCollapse.Pattern.ExpandCollapseState.Value != FlaUI.Core.Definitions.ExpandCollapseState.Expanded)
                    bar.Patterns.ExpandCollapse.Pattern.Expand();
            }
            catch (Exception error) when (error is FlaUI.Core.Exceptions.FlaUIException or System.Runtime.InteropServices.COMException
                                              or System.ComponentModel.Win32Exception) { return null; }
            return window.FindFirstDescendant(cf => cf.ByAutomationId(item)) ?? automation.GetDesktop().FindFirstDescendant(cf => cf.ByAutomationId(item));
        }, item).AsMenuItem();

    /// <summary>Opens a menu; a window that has just appeared may refuse until its content is ready.</summary>
    private static void Expand(AutomationElement menu) => Until(() =>
    {
        try { menu.Patterns.ExpandCollapse.Pattern.Expand(); return true; }
        catch (Exception error) when (error is FlaUI.Core.Exceptions.FlaUIException or System.Runtime.InteropServices.COMException
                                          or System.ComponentModel.Win32Exception) { return false; }
    }, "the menu to open");

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
            Mouse.Click(new System.Drawing.Point(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2));
            Until(() => server.Pointers.Any(p => p.Buttons == 1), "the desktop focused");

            // Ctrl+N inside the desktop is remote input.
            Keyboard.TypeSimultaneously(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_N);
            Until(() => server.Keys.Contains(new RfbTestServer.KeyRecord(true, 0x6e)), "n reaches the server");
            Assert.AreEqual(1, app.Application.GetAllTopLevelWindows(automation).Length, "no new window from inside the desktop");

            // The chord + M opens the Connection menu; M stays local.
            Keyboard.TypeSimultaneously(VirtualKeyShort.CONTROL, VirtualKeyShort.ALT, VirtualKeyShort.KEY_M);
            var hold = WaitFor(() => automation.GetDesktop().FindFirstDescendant(cf => cf.ByAutomationId("desktop.holdControl")), "the context menu");
            Assert.IsFalse(server.Keys.Any(k => k.KeySym is 0x6d or 0x4d), "M stays local");
            hold.AsMenuItem().Invoke();
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
