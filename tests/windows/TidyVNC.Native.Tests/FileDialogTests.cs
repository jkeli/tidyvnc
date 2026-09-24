// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Runtime.InteropServices;
using TidyVNC.Native.Documents;

namespace TidyVNC.Native.Tests;

/// <summary>
/// The Common Item Dialog closes as cancelled while it is open (exit and
/// session end during a file dialog, SERVICES.md section 4). It shows real
/// windows, so like the UI suite it runs only with TIDYVNC_UI_TESTS=1 on a
/// desktop idle for a minute.
/// </summary>
[TestClass]
public sealed unsafe partial class FileDialogTests
{
    [LibraryImport("user32.dll")]
    private static partial nuint SetTimer(nint window, nuint id, uint milliseconds, delegate* unmanaged<nint, uint, nuint, uint, void> callback);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool KillTimer(nint window, nuint id);

    [StructLayout(LayoutKind.Sequential)]
    private struct LastInput { public uint Size; public uint Time; }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetLastInputInfo(ref LastInput input);

    private static bool timerFired, secondRefused;

    [UnmanagedCallersOnly]
    private static void CloseFromTheModalLoop(nint window, uint message, nuint id, uint time)
    {
        timerFired = true;
        try { NativeFileDialogs.Show(0, NativeFileDialogKind.OpenConnection, new()); }
        catch (InvalidOperationException) { secondRefused = true; }
        NativeFileDialogs.CancelActive();
    }

    private static void RequireIdleDesktop()
    {
        if (Environment.GetEnvironmentVariable("TIDYVNC_UI_TESTS") != "1")
            Assert.Inconclusive("Shows a file dialog on the desktop; set TIDYVNC_UI_TESTS=1 to run it");
        var input = new LastInput { Size = (uint)sizeof(LastInput) };
        GetLastInputInfo(ref input);
        if (Environment.GetEnvironmentVariable("TIDYVNC_UI_TESTS_FORCE") != "1" && (uint)Environment.TickCount - input.Time < 60_000)
            Assert.Inconclusive("The desktop is in use; not showing dialogs");
    }

    [TestMethod]
    public void AnOpenDialogClosesAsCancelled()
    {
        RequireIdleDesktop();
        foreach (var kind in new[] { NativeFileDialogKind.OpenConnection, NativeFileDialogKind.SaveConnection })
        {
            string? result = "unset";
            Exception? failure = null;
            timerFired = secondRefused = false;
            var thread = new Thread(() =>
            {
                try
                {
                    var timer = SetTimer(0, 0, 500, &CloseFromTheModalLoop);
                    try
                    {
                        result = NativeFileDialogs.Show(0, kind, new(Title: "TidyVNC test", OkLabel: "Review"),
                            Path.GetTempPath(), kind == NativeFileDialogKind.SaveConnection ? "test.tidyvnc" : null);
                    }
                    finally { KillTimer(0, timer); }
                }
                catch (Exception error) { failure = error; }
            });
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
            Assert.IsTrue(thread.Join(TimeSpan.FromSeconds(30)), $"{kind} did not close (timer fired: {timerFired}, second refused: {secondRefused})");
            Assert.IsNull(failure, failure?.ToString());
            Assert.IsTrue(timerFired, "the timer ran inside the dialog's modal loop");
            Assert.IsTrue(secondRefused, "a second dialog is refused while one is open");
            Assert.IsNull(result, $"{kind} reports cancellation");
            Assert.IsFalse(NativeFileDialogs.IsOpen);
        }
    }
}
