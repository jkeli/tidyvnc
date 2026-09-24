// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using TidyVNC.Native.Documents;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Listen for connections (plans/native-ui-winui TODO W5.12, PARITY L07,
/// L08, W12; macOS ListenerModelTests): the port and families are checked
/// before binding, incoming peers are reserved while a window opens them or
/// released when it cannot, a busy port is a bind failure, and with
/// AlertOnFatalError off a failure closes the listener silently.
/// </summary>
[TestClass]
public sealed class ListenerModelTests
{
    private static async Task Until(Func<bool> condition, string label)
    {
        var clock = Stopwatch.StartNew();
        while (!condition())
        {
            if (clock.Elapsed > TimeSpan.FromSeconds(10)) Assert.Fail($"Timed out: {label}");
            await Task.Delay(5);
        }
    }

    [TestMethod]
    public void PortsAreDecimalFromZeroTo65535()
    {
        Assert.AreEqual(5500u, NativeListenerModel.ParsePort(" 5500 "));
        Assert.AreEqual(0u, NativeListenerModel.ParsePort("0"));
        Assert.IsNull(NativeListenerModel.ParsePort("65536"));
        Assert.IsNull(NativeListenerModel.ParsePort("0x10"));
        Assert.IsNull(NativeListenerModel.ParsePort(""));
    }

    [TestMethod]
    public async Task IncomingPeersAreReservedAcceptedOrRejected()
    {
        using var ui = new SingleThreadDispatcher();
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var opened = new List<NativeReverseRequest>();
            var allowOpen = false;
            var model = new NativeListenerModel(runtime, request => { if (!allowOpen) return false; opened.Add(request); return true; });
            using var first = new TcpClient();
            using var second = new TcpClient();
            try
            {
                model.Port = "70000";
                model.Start();
                Assert.AreEqual(NativeListenerIssue.InvalidPort, model.Issue);
                model.Port = "0"; model.Ipv4 = false; model.Ipv6 = false;
                model.Start();
                Assert.AreEqual(NativeListenerIssue.NoFamily, model.Issue);
                model.Ipv4 = true;
                model.Start();
                await Until(() => model.Phase == NativeListenerPhase.Listening, "listening");
                Assert.IsNull(model.Issue);
                var port = (int)model.Addresses.First().Port;

                await first.ConnectAsync(IPAddress.Loopback, port);
                await Until(() => model.Incoming.Length == 1, "the first peer");
                var peer = model.Incoming[0];
                model.Accept(peer);
                Assert.AreEqual(NativeListenerIssue.OpenFailed, model.Issue, "a window that cannot open releases the peer");
                Assert.IsFalse(model.Reserved.Contains(peer.Id));
                allowOpen = true;
                model.Accept(peer);
                Assert.IsTrue(model.Reserved.Contains(peer.Id));
                Assert.IsFalse(model.CanAccept(peer), "one window per peer");
                Assert.AreEqual(peer, opened.Single().Peer);

                await second.ConnectAsync(IPAddress.Loopback, port);
                await Until(() => model.Incoming.Length == 2, "the second peer");
                var other = model.Incoming.Single(p => p.Id != peer.Id);
                model.Reject(other);
                await Until(() => model.Incoming.Length == 1, "the rejected peer removed");

                model.Stop();
                await Until(() => model.Phase == NativeListenerPhase.Stopped, "stopped");
                Assert.AreEqual(0, model.Incoming.Length);
                Assert.IsTrue(model.CanStart, "a stopped listener can start again");
            }
            finally
            {
                await model.CloseAsync();
                await runtime.ShutdownAsync();
            }
            return 0;
        });
    }

    [TestMethod]
    public async Task ABusyPortFailsAndCanCloseSilently()
    {
        using var ui = new SingleThreadDispatcher();
        var busy = new TcpListener(IPAddress.Any, 0);
        busy.Start();
        try
        {
            var port = ((IPEndPoint)busy.LocalEndpoint).Port.ToString(CultureInfo.InvariantCulture);
            await ui.InvokeAsync(async () =>
            {
                var runtime = new NativeRuntime(ui);
                var model = new NativeListenerModel(runtime, _ => false, new NativeListenOptions { Port = uint.Parse(port, CultureInfo.InvariantCulture), Ipv6 = false });
                var silent = new NativeListenerModel(runtime, _ => false, new NativeListenOptions { Port = uint.Parse(port, CultureInfo.InvariantCulture), Ipv6 = false },
                    alertOnFatalError: false);
                try
                {
                    Assert.AreEqual((port, false), (model.Port, model.Ipv6), "a -listen launch fills the fields");
                    model.StartLaunchIfNeeded();
                    await Until(() => model.Phase == NativeListenerPhase.Failed, "bind failure");
                    Assert.AreEqual(NativeListenerIssue.Bind, model.Issue);
                    Assert.IsFalse(model.ClosesAfterFailure);

                    silent.StartLaunchIfNeeded();
                    await Until(() => silent.ClosesAfterFailure, "closed silently");
                    Assert.IsTrue(silent.IsClosing);
                }
                finally
                {
                    await model.CloseAsync();
                    await silent.CloseAsync();
                    await runtime.ShutdownAsync();
                }
                return 0;
            });
        }
        finally
        {
            busy.Stop();
        }
    }

    private sealed class FileReader(string text) : INativeDocumentReader
    {
        public Task<byte[]> ReadAsync(string path, CancellationToken cancellation) =>
            Task.FromResult(Encoding.UTF8.GetBytes("TidyVNC Configuration file Version 1.0\n" + text));
    }

    /// <summary>
    /// vncviewer -listen &lt;file&gt; (macOS ListenerModel preparation): the file is reviewed before
    /// anything binds, its ServerName is the listen port, and its settings reach every accepted
    /// connection. Cancelling the review leaves the window unable to listen.
    /// </summary>
    [TestMethod]
    public async Task AListenerFileIsReviewedAndItsSettingsReachAcceptedConnections()
    {
        var root = Path.Combine(Path.GetTempPath(), "tidyvnc-listen-file-" + Guid.NewGuid().ToString("N"));
        using var ui = new SingleThreadDispatcher();
        try
        {
            await ui.InvokeAsync(async () =>
            {
                var runtime = new NativeRuntime(ui);
                using var store = new NativePreferencesStore(Path.Combine(root, "state"));
                NativeSessionDefaults Prepare() => new(runtime, store,
                    document: new NativeDocumentOpenRequest(Guid.NewGuid(), Path.Combine(root, "listen.tidyvnc"), root),
                    documentReader: new FileReader("ServerName=0\nShared=off\nFuture=1"), purpose: NativeSessionDefaultsPurpose.Listener);
                var opened = new List<NativeReverseRequest>();
                var preparation = Prepare();
                var model = new NativeListenerModel(runtime, request => { opened.Add(request); return true; },
                    new NativeListenOptions { Port = 5500, Ipv4 = true, Ipv6 = false }, preparation: preparation);
                using var client = new TcpClient();
                try
                {
                    Assert.IsFalse(model.CanStart, "nothing binds before the review");
                    model.StartLaunchIfNeeded();
                    await Until(() => preparation.DocumentReview is not null, "the review");
                    Assert.AreEqual(NativeListenerPhase.Idle, model.Phase);
                    Assert.AreEqual(1, preparation.DocumentReview!.Setup.Notices.Count, "the unknown field is listed");
                    model.AcceptDocument(preparation.DocumentReview.Id);
                    Assert.AreEqual("0", model.Port, "the file's ServerName is the port");
                    await Until(() => model.Phase == NativeListenerPhase.Listening, "listening");
                    await client.ConnectAsync(IPAddress.Loopback, (int)model.Addresses.First().Port);
                    await Until(() => model.Incoming.Length == 1, "the peer");
                    model.Accept(model.Incoming[0]);
                    Assert.IsNotNull(opened.Single().Prepared, "the reviewed settings go with the connection");
                    Assert.IsFalse(opened.Single().Prepared!.Configuration.Shared);
                }
                finally { await model.CloseAsync(); }

                var cancelled = Prepare();
                var other = new NativeListenerModel(runtime, _ => true, new NativeListenOptions { Port = 5500 }, preparation: cancelled);
                try
                {
                    other.StartLaunchIfNeeded();
                    await Until(() => cancelled.DocumentReview is not null, "the second review");
                    other.CancelDocument(cancelled.DocumentReview!.Id);
                    Assert.IsTrue(other.PreparationCancelled);
                    Assert.IsFalse(other.CanStart);
                    other.Start();
                    Assert.AreEqual(NativeListenerPhase.Idle, other.Phase, "a cancelled file never listens");
                }
                finally { await other.CloseAsync(); }
                await store.CloseAsync();
                await runtime.ShutdownAsync();
                return true;
            });
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}
