// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Runtime.InteropServices;
using TidyVNC.Native.Platform;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Keyboard capture service (plans/native-ui-winui TODO W4.8, SERVICES.md
/// section 8): when capture starts, what releases it and what suppresses
/// automatic recapture, against a scripted capture; plus the real low-level
/// hook starting and stopping for a window.
/// </summary>
[TestClass]
public sealed partial class KeyboardCaptureTests
{
    private sealed class ScriptedCapture : INativeKeyboardCapturing
    {
        public bool IsActive { get; set; }
        public bool Fails { get; set; }
        public int Starts { get; private set; }

        public NativeKeyboardCaptureStart Start()
        {
            Starts++;
            if (Fails) return NativeKeyboardCaptureStart.Failed;
            IsActive = true;
            return NativeKeyboardCaptureStart.Active;
        }

        public void Stop() => IsActive = false;
    }

    private sealed class Harness
    {
        public ScriptedCapture Capture { get; } = new();
        public bool Eligible { get; set; } = true;
        public int Releases { get; private set; }
        public List<(bool Active, NativeKeyboardCaptureRelease? Reason, NativeKeyboardCaptureFailure? Failure)> Changes { get; } = [];
        public NativeKeyboardCaptureController Controller { get; }

        public Harness()
        {
            Controller = new NativeKeyboardCaptureController(Capture, () => Eligible, () => Releases++);
            Controller.Changed += (active, reason, failure) => Changes.Add((active, reason, failure));
        }
    }

    [TestMethod]
    public void FullscreenSystemKeysCaptureOncePerEntry()
    {
        var h = new Harness();
        h.Controller.SetFullscreenSystemKeys(true);
        Assert.IsFalse(h.Capture.IsActive, "windowed: no automatic capture");
        h.Controller.SetFullscreen(true);
        Assert.IsTrue(h.Controller.IsCapturing);
        Assert.AreEqual(1, h.Capture.Starts);
        h.Controller.Update();
        Assert.AreEqual(1, h.Capture.Starts, "no restart while active");
        h.Eligible = false; // A dialog opens over the desktop.
        h.Controller.Update();
        Assert.IsFalse(h.Capture.IsActive);
        h.Eligible = true;
        h.Controller.Update();
        Assert.AreEqual(1, h.Capture.Starts, "automatic capture happens once per fullscreen entry or focus interval");
        Assert.AreEqual(1, h.Releases, "losing eligibility releases the remote's pressed keys");
        h.Controller.Capture();

        h.Controller.ReleaseForCommand();
        Assert.IsFalse(h.Capture.IsActive);
        Assert.AreEqual(2, h.Releases, "so does an explicit release");
        h.Controller.Update();
        Assert.IsFalse(h.Capture.IsActive, "an explicit release suppresses automatic recapture");
        h.Controller.SetFullscreenSystemKeys(false);
        h.Controller.SetFullscreenSystemKeys(true);
        Assert.IsFalse(h.Capture.IsActive, "toggling the policy does not override the user's release");

        h.Controller.SetFullscreen(false);
        h.Controller.SetFullscreen(true);
        Assert.IsTrue(h.Capture.IsActive, "a new fullscreen entry captures again");
        h.Controller.SetFullscreenSystemKeys(false);
        Assert.IsFalse(h.Capture.IsActive, "turning the policy off releases");
        Assert.AreEqual(NativeKeyboardCaptureRelease.PolicyChanged, h.Changes[^1].Reason);
    }

    [TestMethod]
    public void EligibilityAndLifecycleEventsRelease()
    {
        foreach (var reason in new[] { NativeKeyboardCaptureRelease.Sleep, NativeKeyboardCaptureRelease.Lock, NativeKeyboardCaptureRelease.Disconnected })
        {
            var h = new Harness();
            h.Controller.Capture();
            Assert.IsTrue(h.Controller.IsCapturing);
            h.Controller.Release(reason);
            Assert.IsFalse(h.Capture.IsActive, reason.ToString());
            Assert.AreEqual(1, h.Releases);
            Assert.AreEqual((false, (NativeKeyboardCaptureRelease?)reason, (NativeKeyboardCaptureFailure?)null), h.Changes[^1]);
        }

        var focus = new Harness();
        focus.Controller.Capture();
        focus.Eligible = false;
        focus.Controller.FocusChanged(false);
        Assert.IsFalse(focus.Capture.IsActive);
        Assert.AreEqual(NativeKeyboardCaptureRelease.FocusLost, focus.Changes[^1].Reason);
        Assert.AreEqual(NativeKeyboardCaptureFailure.Unavailable,
            Assert.ThrowsExactly<NativeKeyboardCaptureException>(focus.Controller.Capture).Failure, "ineligible desktops cannot capture");

        var closing = new Harness();
        closing.Controller.Capture();
        closing.Controller.Close();
        Assert.IsFalse(closing.Capture.IsActive);
        Assert.AreEqual(NativeKeyboardCaptureRelease.Closed, closing.Changes[^1].Reason);
        Assert.ThrowsExactly<NativeKeyboardCaptureException>(closing.Controller.Capture);
        closing.Controller.Update();
        Assert.AreEqual(1, closing.Capture.Starts);

        var idle = new Harness();
        idle.Controller.Release(NativeKeyboardCaptureRelease.Sleep);
        Assert.AreEqual(0, idle.Releases, "nothing to release when not capturing");
        Assert.AreEqual(0, idle.Changes.Count);
    }

    [TestMethod]
    public void FailuresAndEndedCapturesAreTypedAndSuppressRetries()
    {
        var h = new Harness { Capture = { Fails = true } };
        h.Controller.SetFullscreenSystemKeys(true);
        h.Controller.SetFullscreen(true);
        Assert.AreEqual((false, (NativeKeyboardCaptureRelease?)null, (NativeKeyboardCaptureFailure?)NativeKeyboardCaptureFailure.Failed), h.Changes[^1]);
        h.Controller.Update();
        Assert.AreEqual(1, h.Capture.Starts, "a failed automatic capture is not retried in a loop");
        Assert.AreEqual(NativeKeyboardCaptureFailure.Failed,
            Assert.ThrowsExactly<NativeKeyboardCaptureException>(h.Controller.Capture).Failure, "the command reports the failure");

        var ended = new Harness();
        ended.Controller.SetFullscreenSystemKeys(true);
        ended.Controller.SetFullscreen(true);
        ended.Capture.IsActive = false; // The hook went away on its own.
        ended.Controller.Update();
        Assert.AreEqual(NativeKeyboardCaptureRelease.Ended, ended.Changes[^1].Reason);
        Assert.AreEqual(1, ended.Releases);
        Assert.AreEqual(1, ended.Capture.Starts, "no silent recapture after it ended");
        ended.Controller.FocusChanged(false);
        ended.Controller.FocusChanged(true);
        Assert.AreEqual(2, ended.Capture.Starts, "a new focus interval may capture again");
    }

    // ---- The real hook ----------------------------------------------------------------------

    [LibraryImport("user32.dll", EntryPoint = "CreateWindowExW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial nint CreateWindowEx(uint exStyle, string className, string? name, uint style, int x, int y, int width, int height,
                                               nint parent, nint menu, nint instance, nint parameter);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyWindow(nint window);

    [TestMethod]
    public void TheLowLevelHookStartsAndStopsForAWindow()
    {
        Exception? failure = null;
        var thread = new Thread(() => { try { RunHook(); } catch (Exception error) { failure = error; } });
        thread.Start();
        Assert.IsTrue(thread.Join(TimeSpan.FromSeconds(30)));
        if (failure is not null) throw failure;

        static void RunHook()
        {
            var window = CreateWindowEx(0, "STATIC", null, 0, 0, 0, 10, 10, 0, 0, 0, 0);
            Assert.AreNotEqual((nint)0, window);
            try
            {
                // Capture requires the UI thread's message hook, which repairs keyboard state.
                using var hook = new NativeMessageHook(_ => false);
                using var capture = new NativeWindowsKeyboardCapture(window);
                for (var i = 0; i < 3; i++)
                {
                    Assert.AreEqual(NativeKeyboardCaptureStart.Active, capture.Start());
                    Assert.AreEqual(NativeKeyboardCaptureStart.Active, capture.Start(), "starting twice keeps one hook");
                    Assert.IsTrue(capture.IsActive);
                    capture.Stop();
                    Assert.IsFalse(capture.IsActive);
                }
                var controller = new NativeKeyboardCaptureController(capture, () => true, () => { });
                controller.Capture();
                Assert.IsTrue(controller.IsCapturing);
                controller.Close();
                Assert.IsFalse(capture.IsActive);
            }
            finally { DestroyWindow(window); }
        }
    }
}
