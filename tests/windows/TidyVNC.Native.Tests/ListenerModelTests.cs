// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;

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
}
