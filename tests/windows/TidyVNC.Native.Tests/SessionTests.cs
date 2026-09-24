// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Windows.CO / Windows.AU: sessions, prompts, frames, cancellation, the
/// listener and UI-thread responsiveness through TidyVNC.Native against real
/// loopback peers (TODO W3.2, W3.3). Everything runs on a dedicated UI
/// thread, as it does in the app.
/// </summary>
[TestClass]
public sealed class SessionTests
{
    public TestContext TestContext { get; set; } = null!;

    private static async Task<T> OnUi<T>(SingleThreadDispatcher ui, Func<Task<T>> body) => await ui.InvokeAsync(body);

    private static async Task Until(Func<bool> condition, int seconds = 10)
    {
        var deadline = Stopwatch.StartNew();
        while (!condition())
        {
            if (deadline.Elapsed > TimeSpan.FromSeconds(seconds)) Assert.Fail("Condition not reached in time");
            await Task.Delay(5);
        }
    }

    private static void AnswerPrompts(NativeSession session, string password = "password")
    {
        session.PropertyChanged += (_, change) =>
        {
            if (change.PropertyName != nameof(NativeSession.Prompt) || session.Prompt is not { } prompt) return;
            if (prompt.Kind == NativePrompt.PromptKind.Credentials)
                session.ReplyCredentials(prompt, [], Encoding.UTF8.GetBytes(password));
        };
    }

    [TestMethod]
    public async Task ConnectAuthenticateReceiveFrameDisconnectAndDrain()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer(authentication: true);
        var pixels = await OnUi(ui, async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [2] });
            AnswerPrompts(session);
            var connected = await session.ConnectAsync(peer.Endpoint);
            Assert.AreEqual(session.Generation, connected.Operation.Generation);
            await Until(() => session.HasFrame);
            Assert.AreEqual(NativeSessionState.Connected, session.Snapshot.State);
            Assert.AreEqual(2u, session.Snapshot.Width);
            Assert.IsNotNull(session.Information);
            Assert.AreEqual("VncAuth", session.Information!.SecurityName);
            Assert.IsFalse(session.Information.RedactedDiagnostics.Contains("peer", StringComparison.Ordinal));
            var frame = session.Frame!;
            var copy = frame.CopyPixels();
            await session.DisconnectAsync();
            await Until(() => session.Snapshot.State == NativeSessionState.Closed);
            Assert.IsNull(session.Frame);
            await session.CloseAsync();
            await runtime.ShutdownAsync();
            return (copy, frame.Format);
        });
        Assert.IsTrue(peer.Verified);
        var (bytes, format) = pixels;
        var red = format == NativeImage.PixelFormat.Bgra8 ? bytes[2] : bytes[0];
        Assert.AreEqual((byte)10, red);
        Assert.AreEqual((byte)20, bytes[1]);
    }

    [TestMethod]
    public async Task WrongPasswordEndsTheAttemptWithAuthenticationRejected()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer(authentication: true);
        var reason = await OnUi(ui, async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [2] });
            AnswerPrompts(session, "not-it");
            try { await session.ConnectAsync(peer.Endpoint); } catch (NativeCommandFailure) { }
            await Until(() => session.Snapshot.State is NativeSessionState.Closed or NativeSessionState.Failed);
            var end = session.Snapshot.EndReason;
            await runtime.ShutdownAsync();
            return end;
        });
        Assert.AreEqual(NativeEndReason.AuthenticationRejected, reason);
    }

    [TestMethod]
    public async Task CancellingAPendingConnectIsTypedAndLeavesNoLateDialog()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer(authentication: true);
        await OnUi(ui, async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [2] });
            using var cancel = new CancellationTokenSource();
            var connect = session.ConnectAsync(peer.Endpoint, cancel.Token);
            await Until(() => session.Prompt is not null);
            await cancel.CancelAsync();
            await Assert.ThrowsExactlyAsync<TaskCanceledException>(() => connect);
            await Until(() => session.Snapshot.State is NativeSessionState.Closed or NativeSessionState.Failed);
            Assert.IsNull(session.Prompt);
            await runtime.ShutdownAsync();
            return true;
        });
    }

    [TestMethod]
    public async Task CloseDuringAuthenticationDrainsWithoutAnswer()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer(authentication: true);
        await OnUi(ui, async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [2] });
            var connect = session.ConnectAsync(peer.Endpoint);
            await Until(() => session.Prompt is not null);
            await session.CloseAsync();
            Assert.IsTrue(session.IsClosing);
            Assert.IsNull(session.Prompt);
            var failure = await Assert.ThrowsExactlyAsync<NativeError>(() => connect);
            Assert.AreEqual(NativeStatus.Closing, failure.Status);
            await runtime.ShutdownAsync();
            return true;
        });
    }

    [TestMethod]
    public async Task TwoSessionsConnectIndependently()
    {
        using var ui = new SingleThreadDispatcher();
        await using var first = new LoopbackPeer();
        await using var second = new LoopbackPeer(authentication: true);
        await OnUi(ui, async () =>
        {
            var runtime = new NativeRuntime(ui);
            var a = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1] });
            var b = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [2] });
            AnswerPrompts(b);
            await Task.WhenAll(a.ConnectAsync(first.Endpoint), b.ConnectAsync(second.Endpoint));
            await Until(() => a.HasFrame && b.HasFrame);
            Assert.AreNotEqual(0UL, a.Snapshot.Generation);
            await runtime.ShutdownAsync();
            Assert.IsTrue(a.IsClosing && b.IsClosing);
            return true;
        });
    }

    [TestMethod]
    public async Task BellsAndRemoteClipboardReachTheUiThread()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer();
        var bells = 0;
        var text = await OnUi(ui, async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1] });
            session.BellHandler = () => { Assert.IsTrue(ui.HasThreadAccess); bells++; };
            await session.ConnectAsync(peer.Endpoint);
            await Until(() => peer.Established && session.Snapshot.State == NativeSessionState.Connected);
            session.SetFocused(true);
            await peer.BellAsync();
            await peer.ClipboardAsync("café\r\n");
            await Until(() => bells > 0 && session.Clipboard?.Text is not null);
            var value = session.Clipboard!.Text!;
            Assert.IsTrue(value.FromRemote);
            var result = value.Text;
            await runtime.ShutdownAsync();
            return result;
        });
        Assert.AreEqual("café\n", text);
        Assert.AreEqual(1, bells);
    }

    [TestMethod]
    public async Task ListenerAcceptsAReverseConnectionIntoASession()
    {
        using var ui = new SingleThreadDispatcher();
        var runtimeAndListener = await OnUi(ui, () =>
        {
            var runtime = new NativeRuntime(ui);
            var listener = runtime.CreateListener(new NativeListenOptions { Address = "127.0.0.1", Port = 0, Ipv6 = false });
            return Task.FromResult((runtime, listener));
        });
        var (runtime, listener) = runtimeAndListener;
        await Until(() => listener.Snapshot.State == NativeListenerState.Listening);
        var port = (int)listener.Snapshot.Addresses[0].Port;
        Assert.IsTrue(listener.Snapshot.Addresses[0].IsLoopback);
        await using var peer = new LoopbackPeer(reversePort: port);
        await Until(() => listener.Incoming.Count == 1);
        await OnUi(ui, async () =>
        {
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1] });
            await listener.AcceptAsync(listener.Incoming[0], session);
            await Until(() => session.HasFrame);
            Assert.AreEqual(0, listener.Incoming.Count);
            await runtime.ShutdownAsync();
            Assert.IsTrue(listener.IsClosing);
            return true;
        });
    }

    /// <summary>
    /// D7 (TODO W3.2): the UI thread's worst tick gap during a pending connect,
    /// a raw decode flood and shutdown under load. A 5 ms ticker runs on the UI
    /// thread; the largest interval between ticks is reported and bounded.
    /// </summary>
    [TestMethod]
    public async Task UiThreadStaysResponsiveDuringConnectFloodAndShutdown()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer(delayServerInit: true, width: 1920, height: 1080);
        var ticks = new List<long>();
        var clock = Stopwatch.StartNew();
        using var stop = new CancellationTokenSource();
        var ticker = OnUi(ui, async () =>
        {
            while (!stop.IsCancellationRequested) { lock (ticks) ticks.Add(clock.ElapsedTicks); await Task.Delay(5); }
            return true;
        });
        long Worst(int from)
        {
            long worst = 0;
            lock (ticks) for (var i = Math.Max(from, 1); i < ticks.Count; i++) worst = Math.Max(worst, ticks[i] - ticks[i - 1]);
            return worst * 1000 / Stopwatch.Frequency;
        }
        var (runtime, session) = await OnUi(ui, () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1] });
            _ = session.ConnectAsync(peer.Endpoint);
            return Task.FromResult((runtime, session));
        });
        var mark = ticks.Count;
        await Task.Delay(500); // Connect pending on ServerInit.
        var connectGap = Worst(mark);
        peer.Release();
        await Until(() => session.HasFrame);
        mark = ticks.Count;
        await peer.FloodAsync(60); // 60 full 1080p Raw updates (~500 MB decoded).
        await Task.Delay(200);
        var floodGap = Worst(mark);
        mark = ticks.Count;
        _ = peer.FloodAsync(60);
        await OnUi(ui, async () => { await runtime.ShutdownAsync(); return true; });
        var shutdownGap = Worst(mark);
        await stop.CancelAsync();
        await ticker;
        TestContext.WriteLine($"Worst UI tick gap: pending connect {connectGap} ms, raw flood {floodGap} ms, shutdown under load {shutdownGap} ms");
        Assert.IsTrue(connectGap < 250 && floodGap < 250 && shutdownGap < 250,
            $"UI thread stalled: {connectGap}/{floodGap}/{shutdownGap} ms");
    }
}
