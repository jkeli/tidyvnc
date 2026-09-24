// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native.Desktop;
using TidyVNC.Native.Platform;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Automatic remote resize (plans/native-ui-winui TODO W5.8, PARITY D06-D07;
/// macOS NativeRemoteResizeCoordinatorTests): the initial size is requested
/// once, an unscaled window follows its view, scaled views and view-only
/// sessions request nothing, a manual size holds until the geometry changes,
/// and full screen across displays owns the geometry while it lasts.
/// </summary>
[TestClass]
public sealed class AutomaticResizeTests
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

    private static readonly byte[] First = LoopbackPeer.Screen(7, 0, 0, 2, 2, 9);

    private static NativeDisplayInfo Display(string id, double x) =>
        new(id, "Monitor " + id, new(x, 0, 1920, 1080), new(x, 0, 1920, 1040), 1, x == 0, false, 1);

    /// <summary>Answers each client SetDesktopSize by accepting it with the same screens.</summary>
    private static async Task Accept(NativeSession session, LoopbackPeer peer, ushort width, ushort height, params byte[][] screens)
    {
        await Until(() => peer.Received(LoopbackPeer.SetDesktopSize(width, height, screens)), $"SetDesktopSize {width}x{height}");
        await peer.LayoutAsync(1, 0, width, height, screens);
        await Until(() => !session.Snapshot.ResizePending && session.DesktopLayout().Layout.Width == width, $"{width}x{height} applied");
    }

    [TestMethod]
    public async Task TheWindowAndTheInitialSizeDriveRequests()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer();
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration
            {
                SecurityTypes = [1],
                ResizePolicy = new NativeRemoteResizePolicy(true, "4x3"),
            });
            using var coordinator = new NativeRemoteResizeCoordinator { Settle = TimeSpan.FromMilliseconds(5) };
            coordinator.Bind(session);
            var view = Guid.NewGuid();
            try
            {
                // A scaled view: only the initial size is requested.
                coordinator.Update(view, new NativeResizeViewport(800, 600, 1.5, Unscaled: false, DevicePixels: false, Available: true));
                await session.ConnectAsync(peer.Endpoint);
                await peer.LayoutAsync(0, 0, 2, 2, First);
                await Accept(session, peer, 4, 3, LoopbackPeer.Screen(7, 0, 0, 4, 3, 9));
                await Until(() => session.DesktopLayout().Layout.Width == 4, "the initial size");
                await Task.Delay(50);
                Assert.IsFalse(peer.Received(LoopbackPeer.SetDesktopSize(800, 600, LoopbackPeer.Screen(7, 0, 0, 800, 600, 9))), "nothing more while scaled");

                // Unscaled: the view's size, in effective pixels unless device units are chosen.
                coordinator.Update(view, new NativeResizeViewport(800, 600, 1.5, Unscaled: true, DevicePixels: false, Available: true));
                await Accept(session, peer, 800, 600, LoopbackPeer.Screen(7, 0, 0, 800, 600, 9));
                coordinator.Update(view, new NativeResizeViewport(800, 600, 1.5, Unscaled: true, DevicePixels: true, Available: true));
                await Accept(session, peer, 1200, 900, LoopbackPeer.Screen(7, 0, 0, 1200, 900, 9));

                // Settling: only the last of several quick changes is requested.
                coordinator.Update(view, new NativeResizeViewport(700, 500, 1, true, false, true));
                coordinator.Update(view, new NativeResizeViewport(710, 510, 1, true, false, true));
                await Accept(session, peer, 710, 510, LoopbackPeer.Screen(7, 0, 0, 710, 510, 9));
                Assert.IsFalse(peer.Received(LoopbackPeer.SetDesktopSize(700, 500, LoopbackPeer.Screen(7, 0, 0, 700, 500, 9))));

                // A manual size holds until the geometry changes.
                var manual = new NativeRemoteLayout(640, 480, [new NativeRemoteScreen(7, 0, 0, 640, 480, 9)]);
                var request = session.RequestDesktopLayoutAsync(manual, session.Generation);
                await Accept(session, peer, 640, 480, LoopbackPeer.Screen(7, 0, 0, 640, 480, 9));
                await request;
                await Task.Delay(50);
                Assert.AreEqual(1, peer.Occurrences(LoopbackPeer.SetDesktopSize(710, 510, LoopbackPeer.Screen(7, 0, 0, 710, 510, 9))),
                    "the manual size is kept");
                coordinator.Update(view, new NativeResizeViewport(720, 520, 1, true, false, true));
                await Accept(session, peer, 720, 520, LoopbackPeer.Screen(7, 0, 0, 720, 520, 9));

                // View-only, an unavailable view or resizing turned off request nothing.
                session.SetViewOnly(true);
                coordinator.Update(view, new NativeResizeViewport(730, 530, 1, true, false, true));
                await Task.Delay(50);
                Assert.IsFalse(peer.Received(LoopbackPeer.SetDesktopSize(730, 530, LoopbackPeer.Screen(7, 0, 0, 730, 530, 9))));
                session.SetViewOnly(false);
                await Accept(session, peer, 730, 530, LoopbackPeer.Screen(7, 0, 0, 730, 530, 9));
                session.SetResizePolicy(new NativeRemoteResizePolicy(false, ""), session.ResizePolicyRevision);
                coordinator.Update(view, new NativeResizeViewport(740, 540, 1, true, false, true));
                await Task.Delay(50);
                Assert.IsFalse(peer.Received(LoopbackPeer.SetDesktopSize(740, 540, LoopbackPeer.Screen(7, 0, 0, 740, 540, 9))));
                Assert.IsNull(coordinator.Message);
            }
            finally
            {
                await coordinator.CloseAsync();
                await session.CloseAsync();
                await runtime.ShutdownAsync();
            }
            return 0;
        });
    }

    [TestMethod]
    public async Task FullScreenAcrossDisplaysOwnsTheGeometry()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer();
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1] });
            using var coordinator = new NativeRemoteResizeCoordinator { Settle = TimeSpan.FromMilliseconds(5) };
            coordinator.Bind(session);
            var view = Guid.NewGuid();
            var canvas = Guid.NewGuid();
            try
            {
                await session.ConnectAsync(peer.Endpoint);
                await peer.LayoutAsync(0, 0, 2, 2, First);
                await Until(() => session.Snapshot.SupportsResize, "resize support");
                coordinator.BeginCanvas(canvas);
                coordinator.Update(view, new NativeResizeViewport(800, 600, 1, true, false, true));
                await Task.Delay(50);
                Assert.IsFalse(peer.Received(LoopbackPeer.SetDesktopSize(800, 600, LoopbackPeer.Screen(7, 0, 0, 800, 600, 9))),
                    "the window is not the source during full screen");

                var layout = new NativeDisplayLayout([Display("a", 0), Display("b", 1920)], false);
                coordinator.UpdateCanvas(canvas, layout, unscaled: true, available: true);
                await Accept(session, peer, 3840, 1080, LoopbackPeer.Screen(7, 0, 0, 1920, 1080, 9), LoopbackPeer.Screen(0, 1920, 0, 1920, 1080));

                // Leaving full screen returns the geometry to the window.
                coordinator.EndCanvas(canvas);
                coordinator.Update(view, new NativeResizeViewport(810, 610, 1, true, false, true));
                await Accept(session, peer, 810, 610, LoopbackPeer.Screen(7, 0, 0, 810, 610, 9));
            }
            finally
            {
                await coordinator.CloseAsync();
                await session.CloseAsync();
                await runtime.ShutdownAsync();
            }
            return 0;
        });
    }
}
