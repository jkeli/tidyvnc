// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using System.Reflection;
using Axe.Windows.Automation;
using Axe.Windows.Automation.Data;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.UIA3;

namespace TidyVNC.UITests;

/// <summary>
/// W5.19 automated accessibility (TESTING.md; PARITY W16): Axe.Windows scans
/// every window of the running app, the connection window, Settings, Saved
/// profiles, the listener and Help, and none may report an error. The same
/// gate as the other UI tests applies: TIDYVNC_UI_TESTS=1 and an idle desktop.
/// Scanning uses UI Automation only; nothing is typed or clicked.
/// </summary>
[TestClass]
[DoNotParallelize]
public sealed class AccessibilityTests
{
    public TestContext TestContext { get; set; } = null!;

    private static string AppPath =>
        typeof(AccessibilityTests).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().First(a => a.Key == "TidyVncApp").Value!;

    private static readonly string StateRoot = Path.Combine(Path.GetTempPath(), "tidyvnc-a11y-" + Guid.NewGuid().ToString("N"));

    [TestInitialize]
    public void RequireIdleDesktop()
    {
        if (Environment.GetEnvironmentVariable("TIDYVNC_UI_TESTS") != "1")
            Assert.Inconclusive("UI automation takes over the desktop; set TIDYVNC_UI_TESTS=1 to run it");
        if (NativeMethods.IdleTime() < TimeSpan.FromSeconds(60))
            Assert.Inconclusive($"The desktop is in use (idle {NativeMethods.IdleTime().TotalSeconds:F0} s); not taking it over");
    }

    [ClassCleanup]
    public static void RemoveStateRoot()
    {
        try { if (Directory.Exists(StateRoot)) Directory.Delete(StateRoot, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static T WaitFor<T>(Func<T?> probe, string what) where T : class
    {
        var clock = Stopwatch.StartNew();
        while (clock.Elapsed < TimeSpan.FromSeconds(20))
        {
            if (probe() is { } found) return found;
            Thread.Sleep(50);
        }
        Assert.Fail($"Timed out waiting for {what}");
        return null!;
    }

    private static void Open(Window window, UIA3Automation automation, string menu, string item)
    {
        WaitFor(() =>
        {
            if (window.FindFirstDescendant(cf => cf.ByAutomationId(item)) is { } found) return found;
            try
            {
                var pattern = window.FindFirstDescendant(cf => cf.ByAutomationId(menu))!.Patterns.ExpandCollapse.Pattern;
                if (pattern.ExpandCollapseState.Value == FlaUI.Core.Definitions.ExpandCollapseState.Expanded) pattern.Collapse();
                else pattern.Expand();
            }
            catch (Exception error) when (error is FlaUI.Core.Exceptions.FlaUIException or System.Runtime.InteropServices.COMException
                                              or System.ComponentModel.Win32Exception or NullReferenceException) { return null; }
            return window.FindFirstDescendant(cf => cf.ByAutomationId(item)) ?? automation.GetDesktop().FindFirstDescendant(cf => cf.ByAutomationId(item));
        }, item).AsMenuItem().Invoke();
    }

    [TestMethod]
    public void EveryWindowPassesAxeWindows()
    {
        if (!File.Exists(AppPath)) Assert.Inconclusive($"Build the app first: {AppPath}");
        var start = new ProcessStartInfo(AppPath) { WorkingDirectory = Path.GetDirectoryName(AppPath)!, UseShellExecute = false };
        start.Environment["TIDYVNC_STATE_ROOT"] = StateRoot;
        using var process = Process.Start(start)!;
        using var application = Application.Attach(process.Id);
        using var automation = new UIA3Automation();
        try
        {
            var window = application.GetMainWindow(automation, TimeSpan.FromSeconds(20))!;
            foreach (var (menu, item, title) in new[]
                     {
                         ("menu.file", "menu.settings", "Settings"), ("menu.file", "menu.savedProfiles", "Saved profiles"),
                         ("menu.file", "menu.listen", "Listen for connections"), ("menu.help", "menu.helpContents", "TidyVNC help"),
                     })
            {
                Open(window, automation, menu, item);
                WaitFor(() => application.GetAllTopLevelWindows(automation).FirstOrDefault(w => w.Title == title), title);
            }
            Thread.Sleep(1000); // Let the windows finish loading their content.

            var output = Path.Combine(TestContext.TestResultsDirectory ?? Path.GetTempPath(), "axe");
            var config = Config.Builder.ForProcessId(process.Id).WithOutputFileFormat(OutputFileFormat.A11yTest).WithOutputDirectory(output).Build();
            var results = ScannerFactory.CreateScanner(config).Scan(new ScanOptions(scanId: "tidyvnc"));
            var problems = new List<string>();
            foreach (var scan in results.WindowScanOutputs)
                foreach (var error in scan.Errors)
                {
                    error.Element.Properties.TryGetValue("AutomationId", out var id);
                    error.Element.Properties.TryGetValue("Name", out var name);
                    error.Element.Properties.TryGetValue("ControlType", out var type);
                    problems.Add($"{error.Rule.ID}: {error.Rule.Description} [{type} id={id} name={name}]");
                }
            foreach (var problem in problems) TestContext.WriteLine(problem);
            TestContext.WriteLine($"Axe.Windows scanned {results.WindowScanOutputs.Count} window(s); results in {output}");
            Assert.AreEqual(0, problems.Count, string.Join(Environment.NewLine, problems.Distinct()));
        }
        finally
        {
            try { if (!process.HasExited) process.Kill(); }
            catch (InvalidOperationException) { }
        }
    }
}
