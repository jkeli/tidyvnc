// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native.Desktop;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Per-connection input and scaling editors (plans/native-ui-winui TODO
/// W5.6/W5.7; macOS NativeInputTests and NativeScalingTests): the session
/// stays authoritative, stale editors are refused, sources follow edits and
/// surfaces veto sizes they cannot render.
/// </summary>
[TestClass]
public sealed class InputScalingTests
{
    private static async Task Until(Func<bool> condition, string label)
    {
        var clock = Stopwatch.StartNew();
        while (!condition())
        {
            if (clock.Elapsed > TimeSpan.FromSeconds(10)) Assert.Fail($"Timed out: {label}");
            await Task.Delay(2);
        }
    }

    [TestMethod]
    public async Task InputEditsReachTheSessionAndStaleEditorsAreRefused()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer();
        await using var replacement = new LoopbackPeer();
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration
            {
                SecurityTypes = [1],
                Input = new NativeInputSettings(CursorFallback: NativeCursorFallback.Hidden, ShortcutModifiers: NativeShortcutModifiers.Control),
                InputSources = { [NativeInputOption.ShortcutModifiers] = NativeOptionSource.Profile },
            });
            var state = new NativeInputState();
            state.Bind(session, NativeCursorFallback.System);
            Assert.AreEqual(NativeCursorFallback.System, state.InactiveCursor, "the file's dormant cursor shape is kept");
            Assert.AreEqual(NativeOptionSource.Profile, state.Sources[NativeInputOption.ShortcutModifiers]);

            var early = new NativeInputDraft(state);
            early.ViewOnly = true;
            Assert.IsFalse(early.CanApply, "only while connected");
            Assert.IsFalse(early.Apply());
            Assert.AreEqual(NativeInputIssue.Closed, early.Issue);

            await session.ConnectAsync(peer.Endpoint);
            var draft = new NativeInputDraft(state);
            draft.ViewOnly = true;
            draft.CursorFallback = NativeCursorFallback.Dot;
            Assert.AreEqual(NativeOptionSource.Session, draft.Source(NativeInputOption.ViewOnly));
            Assert.IsTrue(draft.Apply());
            Assert.IsTrue(session.IsViewOnly, "view-only reaches the session");
            Assert.AreEqual((NativeCursorFallback.Dot, NativeOptionSource.Session), (state.Value.CursorFallback, state.Sources[NativeInputOption.CursorFallback]));
            Assert.AreEqual(NativeCursorFallback.Dot, state.InactiveCursor);

            // Frames do not make an open editor stale; another change does.
            var open = new NativeInputDraft(state);
            await peer.FloodAsync(3);
            await Until(() => session.Frame is not null, "frames");
            open.EmulateMiddle = true;
            Assert.IsTrue(open.CanApply);
            session.SetViewOnly(false);
            Assert.AreEqual((false, NativeOptionSource.Session), (state.Value.ViewOnly, state.Sources[NativeInputOption.ViewOnly]), "the session stays authoritative");
            Assert.IsFalse(open.Apply());
            Assert.AreEqual(NativeInputIssue.Changed, open.Issue);
            Assert.IsFalse(session.EmulatesMiddleButton, "a stale editor changes nothing");

            // A new attempt makes an older editor stale.
            var old = new NativeInputDraft(state);
            old.EmulateMiddle = true;
            await session.DisconnectAsync();
            await session.ConnectAsync(replacement.Endpoint);
            Assert.IsFalse(old.Apply());
            Assert.AreEqual(NativeInputIssue.Changed, old.Issue);
            state.Stop();
            await session.CloseAsync();
            await runtime.ShutdownAsync();
            return 0;
        });
    }

    [TestMethod]
    public async Task ScalingValidatesModesSurfacesAndRevisions()
    {
        using var ui = new SingleThreadDispatcher();
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration
            {
                Scaling = NativeScaling.Parse("Auto", filter: NativeScalingFilter.Nearest),
                ScalingSources = { [NativeScalingOption.Scaling] = NativeOptionSource.AppDefaults },
            });
            var state = new NativeScalingState();
            state.Bind(session);
            Assert.AreEqual(("Auto", NativeScalingFilter.Nearest), (state.Value.Canonical, state.Value.Filter));

            var draft = new NativeScalingDraft(state);
            Assert.AreEqual(NativeScalingMode.Automatic, draft.Mode);
            Assert.IsFalse(draft.CanApply, "no change");
            draft.Mode = NativeScalingMode.Exact;
            Assert.AreEqual("1920x1080", draft.Text, "a custom mode starts from its example");
            draft.Text = "800x";
            Assert.IsNull(draft.Candidate);
            Assert.IsFalse(draft.CanApply);
            draft.Text = "800x600";
            Assert.AreEqual(NativeOptionSource.Session, draft.Source(NativeScalingOption.Scaling));
            Assert.AreEqual(NativeOptionSource.Compiled, draft.Source(NativeScalingOption.DevicePixels));

            // A surface that cannot hold the size vetoes it.
            var veto = state.Register(value => value.Canonical != "800x600");
            Assert.IsFalse(draft.Apply());
            Assert.AreEqual(NativeScalingIssue.Dimensions, draft.Issue);
            Assert.AreEqual("Auto", state.Value.Canonical);
            veto.Dispose();
            draft.Mode = NativeScalingMode.Percent;
            draft.Text = "100";
            Assert.AreEqual(NativeScalingMode.Unscaled, draft.Candidate!.Mode, "100% is accepted as no scaling");
            draft.Mode = NativeScalingMode.Exact;
            Assert.AreEqual("800x600", draft.Text, "each mode keeps its own text");
            draft.DevicePixels = true;
            Assert.IsTrue(draft.Apply());
            Assert.AreEqual(("800x600", true, NativeOptionSource.Session), (state.Value.Canonical, state.Value.DevicePixels, state.Sources[NativeScalingOption.Scaling]));

            var stale = new NativeScalingDraft(state);
            var other = new NativeScalingDraft(state);
            other.Filter = NativeScalingFilter.Area;
            Assert.IsTrue(other.Apply());
            stale.Mode = NativeScalingMode.FitWidth;
            Assert.IsFalse(stale.Apply());
            Assert.AreEqual(NativeScalingIssue.Changed, stale.Issue, "an editor opened before another apply is stale");
            state.Stop();
            var closed = new NativeScalingDraft(state);
            closed.Mode = NativeScalingMode.FitHeight;
            Assert.IsFalse(closed.CanApply);
            await session.CloseAsync();
            await runtime.ShutdownAsync();
            return 0;
        });
    }
}
