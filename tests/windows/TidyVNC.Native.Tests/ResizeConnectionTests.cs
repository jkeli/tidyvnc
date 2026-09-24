// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native.Platform;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Remote resize, the resize policy and connection options (plans/native-ui-winui
/// TODO W5.8; macOS NativeRemoteResizeTests, NativeDisplayLayoutTests and
/// NativeConnectionDraftTests): layouts are mapped by the core algorithm,
/// requests are held against the layout they were read at, the server's reply
/// completes them and stale editors change nothing.
/// </summary>
[TestClass]
public sealed class ResizeConnectionTests
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

    private static NativeDisplayInfo Display(string id, double x, double y, double width, double height, double scale = 1) =>
        new(id, "Display " + id, new NativeDisplayRectangle(x, y, width, height), new NativeDisplayRectangle(x, y, width, height - 48), scale,
            x == 0 && y == 0, false, 0);

    [TestMethod]
    public void DisplayLayoutsMapThroughTheCoreAndReuseRemoteIdentities()
    {
        var left = Display("A", 0, 0, 1920, 1080);
        var right = Display("B", 1920, 0, 2560, 1440);
        var layout = new NativeDisplayLayout([right, left], devicePixels: false);
        Assert.AreEqual((4480u, 1440u, false), (layout.Width, layout.Height, layout.Normalized));
        Assert.AreEqual(2, layout.Regions.Count);
        var a = layout.Regions.Single(r => r.Display.Id == "A");
        var b = layout.Regions.Single(r => r.Display.Id == "B");
        Assert.AreEqual((0u, 0u, 1920u, 1080u), (a.X, a.Y, a.Width, a.Height));
        Assert.AreEqual((1920u, 0u, 2560u, 1440u), (b.X, b.Y, b.Width, b.Height));

        // Exact geometry keeps its ID and flags; the rest take remaining IDs in order, then the lowest unused.
        var baseline = new NativeRemoteLayout(4480, 1440, [new NativeRemoteScreen(9, 100, 0, 800, 600), new NativeRemoteScreen(7, 0, 0, 1920, 1080, 3)]);
        var remote = layout.RemoteLayout(baseline);
        Assert.AreEqual(new NativeRemoteScreen(7, 0, 0, 1920, 1080, 3), remote.Screens.Single(s => s.X == 0));
        Assert.AreEqual(9u, remote.Screens.Single(s => s.X == 1920).Id);
        var single = new NativeRemoteLayout(800, 600, [new NativeRemoteScreen(0, 0, 0, 800, 600)]);
        Assert.AreEqual(1u, layout.RemoteLayout(single).Screens.Single(s => s.X == 1920).Id, "a new screen takes the lowest unused ID");

        // Effective pixels divide by the scale; device units keep the physical size.
        var dense = Display("C", 0, 0, 3840, 2160, 2);
        Assert.AreEqual((1920u, 1080u), (new NativeDisplayLayout([dense], false).Width, new NativeDisplayLayout([dense], false).Height));
        Assert.AreEqual((3840u, 2160u), (new NativeDisplayLayout([dense], true).Width, new NativeDisplayLayout([dense], true).Height));

        Assert.ThrowsExactly<NativeError>(() => new NativeDisplayLayout([], false));
        Assert.ThrowsExactly<NativeError>(() => new NativeDisplayLayout([left, Display("M", 0, 0, 1920, 1080)], false), "mirrored displays cannot be mapped");
        Assert.ThrowsExactly<NativeError>(() => new NativeDisplayLayout([left, left], false));
    }

    [TestMethod]
    public async Task RemoteResizeWaitsForTheServerAndReportsItsAnswer()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer();
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1] });
            await session.ConnectAsync(peer.Endpoint);
            using var early = new NativeRemoteResizeDraft(session);
            early.Reload();
            early.Width = "4";
            Assert.IsFalse(early.CanApply, "the server has not offered resizing");

            var initial = LoopbackPeer.Screen(7, 0, 0, 2, 2, 9);
            await peer.LayoutAsync(0, 0, 2, 2, initial);
            await Until(() => session.Snapshot.SupportsResize, "resize support");
            using var draft = new NativeRemoteResizeDraft(session);
            draft.Reload();
            Assert.AreEqual(("2", "2", NativeRemoteResizeSource.Custom), (draft.Width, draft.Height, draft.Source));
            Assert.IsFalse(draft.CanApply, "no change");
            draft.Width = "4x";
            Assert.IsFalse(draft.CanApply);
            draft.Width = "65536";
            Assert.IsFalse(draft.CanApply);
            draft.Width = "4"; draft.Height = "3";
            Assert.IsTrue(draft.CanApply);

            // A change the draft did not read refuses the request.
            var stale = new NativeRemoteResizeDraft(session);
            stale.Reload();
            stale.Width = "5";
            await peer.LayoutAsync(0, 0, 2, 2, initial, LoopbackPeer.Screen(8, 0, 0, 1, 1));
            await Until(() => session.DesktopLayout().Layout.Screens.Count == 2, "server layout");
            stale.Apply();
            Assert.AreEqual((NativeRemoteResizeMessage.LayoutChanged, true, false), (stale.Message, stale.NeedsReload, stale.IsBusy));
            stale.Dispose();
            await peer.LayoutAsync(0, 0, 2, 2, initial);
            await Until(() => session.DesktopLayout().Layout.Screens.Count == 1, "server layout restored");

            // The custom size keeps the first screen's identity; close waits for the reply.
            draft.Apply();
            Assert.IsTrue(draft.IsBusy);
            Assert.IsFalse(draft.CanApply, "one request at a time");
            var request = LoopbackPeer.SetDesktopSize(4, 3, LoopbackPeer.Screen(7, 0, 0, 4, 3, 9));
            await Until(() => peer.Received(request), "SetDesktopSize");
            await peer.LayoutAsync(1, 0, 4, 3, LoopbackPeer.Screen(7, 0, 0, 4, 3, 9));
            await Until(() => !draft.IsBusy, "applied");
            Assert.AreEqual((NativeRemoteResizeMessage.Applied, true, 4u, 3u),
                (draft.Message, draft.DidApply, draft.Baseline!.Layout.Width, draft.Baseline.Layout.Height));

            // A rejection reports the server's result and keeps the current size.
            draft.Width = "8";
            draft.Apply();
            await Until(() => peer.Received(LoopbackPeer.SetDesktopSize(8, 3, LoopbackPeer.Screen(7, 0, 0, 8, 3, 9))), "second request");
            var closing = draft.CloseAsync();
            await Task.Delay(50);
            Assert.IsFalse(closing.IsCompleted, "a request already sent cannot be abandoned");
            await peer.LayoutAsync(1, 1, 4, 3, LoopbackPeer.Screen(7, 0, 0, 4, 3, 9));
            await closing;
            Assert.AreEqual((4u, 3u), (session.DesktopLayout().Layout.Width, session.DesktopLayout().Layout.Height));

            var rejected = new NativeRemoteResizeDraft(session);
            rejected.Reload();
            rejected.Width = "6";
            rejected.Apply();
            await Until(() => peer.Received(LoopbackPeer.SetDesktopSize(6, 3, LoopbackPeer.Screen(7, 0, 0, 6, 3, 9))), "third request");
            await peer.LayoutAsync(1, 2, 4, 3, LoopbackPeer.Screen(7, 0, 0, 4, 3, 9));
            await Until(() => !rejected.IsBusy, "rejected");
            Assert.AreEqual((NativeRemoteResizeMessage.Rejected, 2u, false), (rejected.Message, rejected.RejectionResult, rejected.DidApply));
            rejected.Dispose();

            // View-only mode prevents requests.
            var viewOnly = new NativeRemoteResizeDraft(session);
            viewOnly.Reload();
            viewOnly.Width = "5";
            session.SetViewOnly(true);
            Assert.IsFalse(viewOnly.CanApply);
            viewOnly.Dispose();
            await session.CloseAsync();
            await runtime.ShutdownAsync();
            return 0;
        });
    }

    [TestMethod]
    public async Task ResizePolicyAndConnectionOptionsEditTheNextConnection()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer();
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration
            {
                SecurityTypes = [1],
                Shared = true,
                ResizePolicy = new NativeRemoteResizePolicy(true, "1280x720"),
                ResizeSources = { [NativeResizeOption.InitialSize] = NativeOptionSource.Profile },
            });

            // Resize policy: sources follow edits; a policy changed elsewhere makes an open editor stale.
            var policy = new NativeRemoteResizePolicyDraft(session);
            Assert.AreEqual(NativeOptionSource.Profile, policy.Source(NativeResizeOption.InitialSize));
            Assert.IsFalse(policy.CanApply, "no change");
            policy.InitialSize = "12x";
            Assert.IsFalse(policy.IsValid);
            Assert.AreEqual(NativeOptionSource.Session, policy.Source(NativeResizeOption.InitialSize));
            policy.InitialSize = "";
            policy.Enabled = false;
            Assert.IsTrue(policy.CanApply);
            var other = new NativeRemoteResizePolicyDraft(session);
            other.Enabled = false;
            Assert.IsTrue(policy.Apply());
            Assert.AreEqual(new NativeRemoteResizePolicy(false, ""), session.ResizePolicy);
            Assert.IsTrue(other.Changed);
            Assert.IsFalse(other.Apply(), "an editor opened before another apply is stale");
            var restore = new NativeRemoteResizePolicyDraft(session);
            restore.RestoreInitial();
            Assert.AreEqual((true, "1280x720"), (restore.Enabled, restore.InitialSize));
            Assert.IsTrue(restore.Apply());

            // Connection options: null inherits the window's initial setting; edits need a disconnected session.
            var draft = new NativeConnectionDraft(session);
            draft.Reload();
            Assert.AreEqual((true, (bool?)null, (bool?)null, false), (draft.InitialShared, draft.Shared, draft.ReconnectOnError, draft.HasChanges));
            draft.Shared = false;
            Assert.IsTrue(draft.CanApply);
            draft.Apply();
            Assert.IsTrue(draft.DidApply);
            Assert.AreEqual((false, NativeOptionSource.Session), (session.ConnectionOptions().Shared, session.ConnectionOptions().SharedSource));
            Assert.IsFalse(draft.HasChanges);

            var open = new NativeConnectionDraft(session);
            open.Reload();
            open.ReconnectOnError = false;
            await session.ConnectAsync(peer.Endpoint);
            Assert.AreEqual((NativeConnectionDraftError.ConnectionChanged, true, false), (open.Error, open.NeedsReload, open.CanApply));
            open.Stop();
            draft.Stop();
            await session.CloseAsync();
            await runtime.ShutdownAsync();
            return 0;
        });
    }
}
