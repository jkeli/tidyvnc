// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Desktop;
using TidyVNC.Native.Platform;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Full-screen policy, intent and display settings (plans/native-ui-winui TODO
/// W5.8, PARITY D02-D05; macOS NativeFullscreenStateTests and
/// NativeFullscreenDraftTests): automatic entry happens once per connection
/// while full screen is wanted, a user's exit sticks across reconnects, and
/// the settings editor applies only reviewed, mappable arrangements to the
/// connection it was opened for.
/// </summary>
[TestClass]
public sealed class FullscreenTests
{
    private sealed class Source : INativeDisplaySource
    {
        public IReadOnlyList<NativeDisplayInfo> Displays { get; set; } = [];
        public IReadOnlyList<NativeDisplayInfo> Read() => Displays;
    }

    private static NativeDisplayInfo Display(string id, double x, bool primary = false, double scale = 1) =>
        new(id, "Monitor " + id, new(x, 0, 1920, 1080), new(x, 0, 1920, 1040), scale, primary, false, 1);

    [TestMethod]
    public async Task AutomaticEntryFollowsTheIntentAcrossReconnects()
    {
        using var ui = new SingleThreadDispatcher();
        await using var first = new LoopbackPeer();
        await using var second = new LoopbackPeer();
        await using var third = new LoopbackPeer();
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration
            {
                SecurityTypes = [1],
                FullscreenPolicy = new NativeFullscreenPolicy(true, NativeFullscreenMode.All, []),
                FullscreenSources = { [NativeFullscreenOption.StartsFullscreen] = NativeOptionSource.CommandLine },
            });
            var state = new NativeFullscreenState();
            var due = 0;
            state.AutomaticEntryDue += () => due++;
            state.Bind(session);
            Assert.AreEqual((NativeFullscreenMode.All, NativeOptionSource.CommandLine),
                (state.Policy.Mode, state.Sources[NativeFullscreenOption.StartsFullscreen]));
            Assert.IsFalse(state.TakeAutomaticEntry(), "not before the connection");

            await session.ConnectAsync(first.Endpoint);
            Assert.AreEqual(1, due);
            Assert.IsTrue(state.AutomaticEntryPending);
            Assert.IsTrue(state.TakeAutomaticEntry());
            Assert.IsFalse(state.TakeAutomaticEntry(), "one attempt per connection");
            state.SetPhase(NativeFullscreenPhase.Entering);
            state.SetPhase(NativeFullscreenPhase.Active);

            // A dropped connection keeps the intent; the next connection returns to full screen.
            await session.DisconnectAsync();
            state.Ended(disconnected: true);
            await session.ConnectAsync(second.Endpoint);
            Assert.AreEqual(2, due);
            Assert.IsTrue(state.TakeAutomaticEntry());
            state.SetPhase(NativeFullscreenPhase.Entering);
            state.SetPhase(NativeFullscreenPhase.Active);

            // The user's exit sticks.
            state.SetPhase(NativeFullscreenPhase.Exiting);
            state.Ended(disconnected: false);
            await session.DisconnectAsync();
            await session.ConnectAsync(third.Endpoint);
            Assert.AreEqual(2, due);
            Assert.IsFalse(state.TakeAutomaticEntry());
            state.Stop();
            await session.CloseAsync();
            await runtime.ShutdownAsync();
            return 0;
        });
    }

    [TestMethod]
    public async Task DisplaySettingsApplyReviewedArrangementsToTheirConnection()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer();
        await using var replacement = new LoopbackPeer();
        await ui.InvokeAsync(async () =>
        {
            var source = new Source { Displays = [Display("a", 0, primary: true), Display("b", 1920, scale: 1.5)] };
            using var displays = new NativeDisplayService(ui, source);
            displays.Refresh();
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration
            {
                SecurityTypes = [1],
                FullscreenPolicy = new NativeFullscreenPolicy(false, NativeFullscreenMode.Selected, ["b"]),
                FullscreenSources = { [NativeFullscreenOption.SelectedDisplays] = NativeOptionSource.Profile },
            });
            var state = new NativeFullscreenState();
            state.Bind(session);
            NativeFullscreenDraft Open() => new(state, displays, () => "a", () => false);
            try
            {
                var closed = Open();
                Assert.AreEqual(new NativeText("settings.fullscreen.the.connection.changed.close.and.reopen.this.sheet"), closed.Validation, "only while connected");
                closed.Cancel();
                await session.ConnectAsync(peer.Endpoint);

                var draft = Open();
                Assert.AreEqual(NativeOptionSource.Profile, draft.Source(NativeFullscreenOption.SelectedDisplays));
                Assert.IsFalse(draft.CanApply, "no change");
                draft.SelectedDisplays = new HashSet<string>();
                Assert.AreEqual(new NativeText("settings.fullscreen.select.at.least.one.display"), draft.Validation);
                draft.SelectedDisplays = new HashSet<string> { "a", "b", "gone" };
                CollectionAssert.AreEqual(new[] { "gone" }, draft.Missing.ToArray());
                CollectionAssert.AreEqual(new[] { "a", "b" }, draft.ChosenDisplays.Select(d => d.Id).ToArray(), "missing displays are skipped");
                Assert.AreEqual(NativeOptionSource.Session, draft.Source(NativeFullscreenOption.SelectedDisplays));

                // A topology change needs a review first.
                source.Displays = [Display("a", 0, primary: true), Display("b", 1920, scale: 1.5), Display("c", 3840)];
                displays.Refresh();
                Assert.IsTrue(draft.NeedsReview);
                Assert.AreEqual(new NativeText("settings.fullscreen.displays.changed.review.the.new.arrangement.before.applying"), draft.Validation);
                draft.ReviewDisplays();
                Assert.IsNull(draft.Validation);

                // Mirrored displays cannot be mapped.
                draft.Mode = NativeFullscreenMode.All;
                source.Displays = [Display("a", 0, primary: true), Display("m", 0)];
                draft.ReviewDisplays();
                Assert.AreEqual(new NativeText("settings.fullscreen.this.display.arrangement.cannot.be.mapped.overlapping.or.mirrored.displays.are.not"), draft.Validation);
                source.Displays = [Display("a", 0, primary: true), Display("b", 1920, scale: 1.5)];
                draft.ReviewDisplays();

                var stale = Open();
                draft.StartsFullscreen = true;
                Assert.IsTrue(draft.Apply());
                Assert.AreEqual((true, NativeFullscreenMode.All), (state.Policy.StartsFullscreen, state.Policy.Mode));
                Assert.AreEqual(NativeOptionSource.Session, state.Sources[NativeFullscreenOption.Mode]);
                stale.Mode = NativeFullscreenMode.Current;
                Assert.IsFalse(stale.Apply(), "an editor opened before another apply is stale");
                Assert.AreEqual(NativeFullscreenMode.All, state.Policy.Mode);

                // Starting full screen applies from the next connection.
                var due = 0;
                state.AutomaticEntryDue += () => due++;
                await session.DisconnectAsync();
                await session.ConnectAsync(replacement.Endpoint);
                Assert.AreEqual(1, due);

                var restore = Open();
                restore.RestoreInitial();
                Assert.AreEqual((false, NativeFullscreenMode.Selected), (restore.StartsFullscreen, restore.Mode));
                CollectionAssert.AreEqual(new[] { "b" }, restore.SelectedDisplays.ToArray());
                restore.Cancel();
            }
            finally
            {
                // A failed assertion must not leave the connection open.
                state.Stop();
                await session.CloseAsync();
                await runtime.ShutdownAsync();
            }
            return 0;
        });
    }

    [TestMethod]
    public void CanvasRegionsPlaceEachDisplaysPartOfTheDesktop()
    {
        var layout = new NativeDisplayLayout([Display("a", 0, primary: true), Display("b", 1920)], false);
        var left = layout.Viewport("a");
        var right = layout.Viewport("b");
        Assert.AreEqual((3840u, 1080u, 0u, 1920u), (left.Width, left.Height, left.X, right.X));
        Assert.ThrowsExactly<NativeError>(() => layout.Viewport("c"));

        // A 3840x1080 desktop unscaled across both: each surface shows its half.
        var a = new NativeGeometry(3840, 1080, 1920, 1080, 1, "Auto", canvas: left);
        var b = new NativeGeometry(3840, 1080, 1920, 1080, 1, "Auto", canvas: right);
        Assert.AreEqual((3840u, 0.0, -1920.0), (a.BackingWidth, a.X, b.X));
        Assert.AreEqual((100, 10), a.RemotePoint(100, 10));
        Assert.AreEqual((2020, 10), b.RemotePoint(100, 10), "pointer mapping includes the region's offset");
        Assert.ThrowsExactly<NativeError>(() => new NativeCanvasViewport(100, 100, 90, 0, 20, 100, false), "a region must lie within the canvas");

        // Mixed scales: effective sizes keep their physical neighbours without gaps or overlaps.
        var mixed = new NativeDisplayLayout([Display("left", -1920), Display("dense", 0, primary: true, scale: 2) with { Bounds = new(0, 0, 3840, 2160) }], false);
        var dense = mixed.Regions.Single(r => r.Display.Id == "dense");
        var leftmost = mixed.Regions.Single(r => r.Display.Id == "left");
        Assert.AreEqual((0u, 1920u, 1920u, 1080u), (leftmost.X, dense.X, dense.Width, dense.Height));
        Assert.AreEqual((3840u, 1080u), (mixed.Width, mixed.Height));
        var devices = new NativeDisplayLayout([Display("left", -1920), Display("dense", 0, primary: true, scale: 2) with { Bounds = new(0, 0, 3840, 2160) }], true);
        Assert.AreEqual((5760u, 2160u), (devices.Width, devices.Height), "device units use the physical sizes");
    }
}
