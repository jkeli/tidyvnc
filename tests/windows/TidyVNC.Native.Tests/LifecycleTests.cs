// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native.Platform;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Lifecycle services (plans/native-ui-winui TODO W4.11, SERVICES.md
/// sections 13-14): session lock, suspend and sign-out notifications, the
/// coalesced bell, the logging policy selection and the fixed help links.
/// </summary>
[TestClass]
public sealed class LifecycleTests
{
    private const uint QueryEndSession = 0x0011, EndSession = 0x0016, SessionChange = 0x02B1, PowerBroadcast = 0x0218;

    [TestMethod]
    public void LockSuspendAndResumeAreReported()
    {
        using var events = new NativeSessionEvents();
        var seen = new List<NativeSessionEvent>();
        events.Changed += change => { lock (seen) seen.Add(change); };
        events.Deliver(SessionChange, 7);      // WTS_SESSION_LOCK
        events.Deliver(SessionChange, 8);      // WTS_SESSION_UNLOCK
        events.Deliver(SessionChange, 5);      // WTS_SESSION_LOGON: not reported
        events.Deliver(PowerBroadcast, 4);     // PBT_APMSUSPEND
        events.Deliver(PowerBroadcast, 0x12);  // PBT_APMRESUMEAUTOMATIC
        events.Deliver(PowerBroadcast, 0x0A);  // PBT_APMPOWERSTATUSCHANGE: not reported
        CollectionAssert.AreEqual(new[] { NativeSessionEvent.Locked, NativeSessionEvent.Unlocked, NativeSessionEvent.Suspending, NativeSessionEvent.Resumed },
            seen.ToArray());
    }

    [TestMethod]
    public void SignOutNeverVetoesAndWaitsBoundedlyForTheDrain()
    {
        var drained = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var starts = 0;
        using var events = new NativeSessionEvents(() => { Interlocked.Increment(ref starts); return drained.Task; }, endSessionDeadline: TimeSpan.FromSeconds(2));
        Assert.AreEqual(1, events.Deliver(QueryEndSession), "sign-out is never vetoed");
        Assert.IsTrue(events.EndingSession);
        Assert.AreEqual(1, events.Deliver(QueryEndSession));
        // The shutdown starts on the thread pool, so a busy pool may run it a moment later.
        SpinWait.SpinUntil(() => Volatile.Read(ref starts) > 0, TimeSpan.FromSeconds(5));
        Assert.AreEqual(1, Volatile.Read(ref starts), "one shutdown per sign-out");

        // WM_ENDSESSION(TRUE) returns once the drain finishes...
        _ = Task.Delay(300).ContinueWith(_ => drained.SetResult(), TaskScheduler.Default);
        var clock = Stopwatch.StartNew();
        events.Deliver(EndSession, 1);
        Assert.IsTrue(clock.Elapsed >= TimeSpan.FromMilliseconds(250), "it waited for the drain");
        Assert.IsTrue(clock.Elapsed < TimeSpan.FromSeconds(2));
        Assert.IsFalse(events.EndingSession);

        // ...and never longer than the deadline.
        using var stuck = new NativeSessionEvents(() => new TaskCompletionSource().Task, endSessionDeadline: TimeSpan.FromMilliseconds(500));
        stuck.Deliver(QueryEndSession);
        clock.Restart();
        stuck.Deliver(EndSession, 1);
        Assert.IsTrue(clock.Elapsed < TimeSpan.FromSeconds(3), "bounded");
        // A vetoed sign-out (WM_ENDSESSION FALSE) returns at once.
        using var vetoed = new NativeSessionEvents(() => new TaskCompletionSource().Task);
        vetoed.Deliver(QueryEndSession);
        clock.Restart();
        vetoed.Deliver(EndSession, 0);
        Assert.IsTrue(clock.Elapsed < TimeSpan.FromSeconds(1));
    }

    [TestMethod]
    public async Task BellsCoalescePerDeliveryTurn()
    {
        using var ui = new SingleThreadDispatcher();
        var sounds = 0;
        var bell = new NativeBell(ui, () => sounds++);
        await ui.InvokeAsync(() =>
        {
            for (var i = 0; i < 5; i++) bell.Ring();
        });
        await ui.InvokeAsync(() => { });
        Assert.AreEqual(1, sounds, "five bells in one turn sound once");
        await ui.InvokeAsync(bell.Ring);
        await ui.InvokeAsync(() => { });
        Assert.AreEqual(2, sounds, "a later turn sounds again");
    }

    [TestMethod]
    public void LoggingPolicySelectionAndLinksAreFixed()
    {
        Assert.AreEqual(NativeProcessLogging.DefaultPolicy, NativeProcessLogging.Selection(NativeInvocation.Parse([])));
        Assert.AreEqual("*:file:100", NativeProcessLogging.Selection(NativeInvocation.Parse(["-Log", "*:stderr:10", "-Log", "*:file:100"])), "the last Log wins");
        var failure = Assert.ThrowsExactly<NativeInvocationFailure>(() => NativeProcessLogging.Selection(NativeInvocation.Parse(["-Log", "*:stderr:10", "-Log", "*:nowhere:10"])));
        Assert.IsTrue(failure.Argument is 3 or 4, "the second Log occurrence is named, not the first");
        Assert.ThrowsExactly<NativeError>(() => NativeProcessLogging.Validate("no colons"));
        StringAssert.EndsWith(NativeProcessLogging.DefaultFilePath, @"\vncviewer.log");
        Assert.IsTrue(Path.IsPathFullyQualified(NativeProcessLogging.DefaultFilePath));
        Assert.AreEqual("https://github.com/jkeli/tidyvnc", NativeHelpLinks.For(NativeHelpLink.Project).ToString());
        Assert.AreEqual("https://github.com/jkeli/tidyvnc/issues", NativeHelpLinks.For(NativeHelpLink.Issues).ToString());
    }
}
