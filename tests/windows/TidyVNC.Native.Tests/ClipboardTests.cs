// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using TidyVNC.Native.Clipboard;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Clipboard (plans/native-ui-winui TODO W4.6, SERVICES.md section 6, D21):
/// the coordinator's routing against real sessions and a scripted clipboard,
/// and the Windows clipboard adapter's markers on the real clipboard (gated:
/// it replaces the desktop's clipboard, restoring its text afterwards).
/// </summary>
[TestClass]
public sealed partial class ClipboardTests
{
    private static async Task Until(Func<bool> condition, int seconds = 10)
    {
        var deadline = Stopwatch.StartNew();
        while (!condition())
        {
            if (deadline.Elapsed > TimeSpan.FromSeconds(seconds)) Assert.Fail("Condition not reached in time");
            await Task.Delay(5);
        }
    }

    /// <summary>A deterministic clipboard: sequence numbers, one content, recorded remote writes.</summary>
    private sealed class ScriptedClipboard : INativeClipboardAccess
    {
        public uint Sequence { get; private set; } = 1;
        public NativeClipboardContent Content { get; private set; } = new(NativeClipboardContentKind.Unavailable);
        public List<(string Text, ulong Session, ulong Generation)> RemoteWrites { get; } = [];
        public NativeClipboardAccessError? ReadFailure { get; set; }
        public int Reads { get; private set; }
        public event Action? Changed;

        public void CopyLocally(string text)
        {
            Sequence++;
            Content = new(NativeClipboardContentKind.Text, text);
            Changed?.Invoke();
        }

        public Task<uint> CurrentChangeAsync() => Task.FromResult(Sequence);

        public Task<NativeClipboardContent> ReadAsync(uint expectedChange, int maximumBytes)
        {
            Reads++;
            if (expectedChange != Sequence) return Task.FromException<NativeClipboardContent>(new NativeClipboardAccessException(NativeClipboardAccessError.Changed));
            if (ReadFailure is { } failure) return Task.FromException<NativeClipboardContent>(new NativeClipboardAccessException(failure));
            return Task.FromResult(Content);
        }

        public Task<uint> WriteRemoteAsync(string text, ulong session, ulong generation, int maximumBytes)
        {
            RemoteWrites.Add((text, session, generation));
            Sequence++;
            Content = new(NativeClipboardContentKind.Remote);
            Changed?.Invoke();
            return Task.FromResult(Sequence);
        }

        public Task<uint> WriteLocalAsync(string text, int maximumBytes)
        {
            CopyLocally(text);
            return Task.FromResult(Sequence);
        }
    }

    /// <summary>RFB ClientCutText: type 6, three padding bytes, big-endian length, Latin-1 text.</summary>
    private static byte[] ClientCutText(string text)
    {
        var bytes = Encoding.Latin1.GetBytes(text);
        return [6, 0, 0, 0, (byte)(bytes.Length >> 24), (byte)(bytes.Length >> 16), (byte)(bytes.Length >> 8), (byte)bytes.Length, .. bytes];
    }

    private sealed record Scenario(SingleThreadDispatcher Ui, NativeRuntime Runtime, ScriptedClipboard Clipboard, NativeClipboardCoordinator Coordinator,
                                   List<(NativeSession Session, NativeClipboardNotice? Notice)> Notices);

    private static async Task<NativeSession> Connect(Scenario s, LoopbackPeer peer, bool viewOnly = false)
    {
        var session = s.Runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1], Input = new NativeInputSettings(ViewOnly: viewOnly) });
        s.Coordinator.Register(session, notice => s.Notices.Add((session, notice)));
        await session.ConnectAsync(peer.Endpoint);
        await Until(() => peer.Established && session.Snapshot.State == NativeSessionState.Connected);
        return session;
    }

    private static async Task Run(Func<Scenario, Task> body)
    {
        using var ui = new SingleThreadDispatcher();
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var clipboard = new ScriptedClipboard();
            var coordinator = new NativeClipboardCoordinator(ui, clipboard);
            try { await body(new Scenario(ui, runtime, clipboard, coordinator, [])); }
            finally
            {
                await coordinator.CloseAsync();
                await runtime.ShutdownAsync();
            }
        });
    }

    [TestMethod]
    public Task LocalCopiesReachOnlyTheFocusedDesktop() => Run(async s =>
    {
        await using var peerA = new LoopbackPeer();
        await using var peerB = new LoopbackPeer();
        var a = await Connect(s, peerA);
        var b = await Connect(s, peerB);
        a.SetFocused(true);
        s.Clipboard.CopyLocally("first");
        await Until(() => peerA.Received(ClientCutText("first")));
        await Task.Delay(100);
        Assert.IsFalse(peerB.Received(ClientCutText("first")), "only the focused desktop");
        var reads = s.Clipboard.Reads;
        for (var i = 0; i < 3; i++) { s.Coordinator.Poll(); await Task.Delay(20); }
        Assert.AreEqual(reads, s.Clipboard.Reads, "an unchanged clipboard is read once");
        Assert.AreEqual(1, peerA.Occurrences(ClientCutText("first")));

        // Copied while no desktop has focus: sent when focus returns.
        a.SetFocused(false);
        s.Clipboard.CopyLocally("while away");
        await Task.Delay(100);
        Assert.IsFalse(peerA.Received(ClientCutText("while away")) || peerB.Received(ClientCutText("while away")));
        b.SetFocused(true);
        await Until(() => peerB.Received(ClientCutText("while away")));
        Assert.IsFalse(peerA.Received(ClientCutText("while away")));

        // Ambiguous focus routes nothing.
        a.SetFocused(true);
        s.Clipboard.CopyLocally("ambiguous");
        await Task.Delay(150);
        Assert.IsFalse(peerA.Received(ClientCutText("ambiguous")) || peerB.Received(ClientCutText("ambiguous")));
        b.SetFocused(false);
        await Until(() => peerA.Received(ClientCutText("ambiguous")));

        // An inactive app routes nothing.
        s.Coordinator.SetApplicationActive(false);
        Assert.IsFalse(a.IsFocused, "deactivation unfocuses desktops");
        s.Clipboard.CopyLocally("inactive");
        await Task.Delay(100);
        Assert.IsFalse(peerA.Received(ClientCutText("inactive")));
    });

    [TestMethod]
    public Task PolicyAndViewOnlyBlockSending() => Run(async s =>
    {
        await using var peerA = new LoopbackPeer();
        await using var peerB = new LoopbackPeer();
        var viewOnly = await Connect(s, peerA, viewOnly: true);
        viewOnly.SetFocused(true);
        var reads = s.Clipboard.Reads;
        s.Clipboard.CopyLocally("view only");
        await Task.Delay(150);
        Assert.IsFalse(peerA.Received(ClientCutText("view only")));
        Assert.AreEqual(reads, s.Clipboard.Reads, "a view-only desktop never reads the local clipboard");
        viewOnly.SetFocused(false);

        var session = await Connect(s, peerB);
        session.SetClipboardPolicy(send: false, receive: true);
        session.SetFocused(true);
        reads = s.Clipboard.Reads;
        s.Clipboard.CopyLocally("not allowed");
        await Task.Delay(150);
        Assert.IsFalse(peerB.Received(ClientCutText("not allowed")));
        Assert.AreEqual(reads, s.Clipboard.Reads, "sending disabled: the local clipboard is not read");
        session.SetClipboardPolicy(send: true, receive: true);
        await Until(() => peerB.Received(ClientCutText("not allowed")));
    });

    [TestMethod]
    public Task RemoteTextIsWrittenWithProvenanceAndNeverEchoed() => Run(async s =>
    {
        await using var peer = new LoopbackPeer();
        var session = await Connect(s, peer);
        session.SetFocused(true);
        await peer.ClipboardAsync("from the server");
        await Until(() => s.Clipboard.RemoteWrites.Count == 1);
        Assert.AreEqual("from the server", s.Clipboard.RemoteWrites[0].Text);
        Assert.AreEqual(session.Generation, s.Clipboard.RemoteWrites[0].Generation);
        await Task.Delay(150);
        Assert.IsFalse(peer.Received(ClientCutText("from the server")), "remote text is not sent back");
        s.Clipboard.CopyLocally("local again");
        await Until(() => peer.Received(ClientCutText("local again")));

        // Remote text arriving while frames stream is still written (frames are not routing changes).
        var flood = peer.FloodAsync(300);
        await peer.ClipboardAsync("during frames");
        await flood;
        await Until(() => s.Clipboard.RemoteWrites.Any(w => w.Text == "during frames"));

        // Unfocused desktops never write the local clipboard.
        session.SetFocused(false);
        await peer.ClipboardAsync("while unfocused");
        await Task.Delay(150);
        Assert.IsFalse(s.Clipboard.RemoteWrites.Any(w => w.Text == "while unfocused"));
    });

    [TestMethod]
    public Task UnreadableLocalTextIsReportedOnTheFocusedConnection() => Run(async s =>
    {
        await using var peer = new LoopbackPeer();
        var session = await Connect(s, peer);
        session.SetFocused(true);
        s.Clipboard.ReadFailure = NativeClipboardAccessError.TooLarge;
        s.Clipboard.CopyLocally(new string('x', 10));
        await Until(() => s.Notices.Any(n => n.Notice == NativeClipboardNotice.LocalNotSent));
        Assert.IsTrue(ReferenceEquals(session, s.Notices.Last(n => n.Notice is not null).Session));
        s.Clipboard.ReadFailure = null;
        s.Clipboard.CopyLocally("fine");
        await Until(() => peer.Received(ClientCutText("fine")));
        await Until(() => s.Notices[^1].Notice is null, 5);
    });

    // ---- The real clipboard (gated) ------------------------------------------------------------

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool OpenClipboard(nint window);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseClipboard();

    [LibraryImport("user32.dll", EntryPoint = "RegisterClipboardFormatW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial uint RegisterClipboardFormat(string name);

    [LibraryImport("user32.dll")]
    private static partial nint GetClipboardData(uint format);

    [LibraryImport("kernel32.dll")]
    private static partial nint GlobalLock(nint memory);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GlobalUnlock(nint memory);

    [StructLayout(LayoutKind.Sequential)]
    private struct LastInput { public uint Size; public uint Time; }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetLastInputInfo(ref LastInput input);

    private static byte[]? Format(string name, int length)
    {
        Assert.IsTrue(OpenClipboard(0));
        try
        {
            var data = GetClipboardData(RegisterClipboardFormat(name));
            if (data == 0) return null;
            var bytes = new byte[length];
            Marshal.Copy(GlobalLock(data), bytes, 0, length);
            GlobalUnlock(data);
            return bytes;
        }
        finally { CloseClipboard(); }
    }

    [TestMethod]
    public async Task RemoteWritesCarryTheNoCloudAndProvenanceMarkers()
    {
        if (Environment.GetEnvironmentVariable("TIDYVNC_UI_TESTS") != "1")
            Assert.Inconclusive("Replaces the desktop clipboard; set TIDYVNC_UI_TESTS=1 to run it");
        var input = new LastInput { Size = 8 };
        GetLastInputInfo(ref input);
        if (Environment.GetEnvironmentVariable("TIDYVNC_UI_TESTS_FORCE") != "1" && (uint)Environment.TickCount - input.Time < 60_000)
            Assert.Inconclusive("The desktop is in use; not touching its clipboard");

        using var clipboard = new NativeWindowsClipboard();
        var changes = 0;
        clipboard.Changed += () => Interlocked.Increment(ref changes);
        var original = await clipboard.ReadAsync(await clipboard.CurrentChangeAsync(), 16 * 1024 * 1024);
        try
        {
            var written = await clipboard.WriteRemoteAsync("remote text", 7, 9, NativeClipboardCoordinator.MaximumBytes);
            Assert.AreEqual(written, await clipboard.CurrentChangeAsync());
            var cloud = Format(NativeWindowsClipboard.CloudUploadFormat, 4);
            CollectionAssert.AreEqual(new byte[4], cloud, "CanUploadToCloudClipboard = 0 on every remote write");
            var origin = Format(NativeWindowsClipboard.RemoteOriginFormat, 24)!;
            Assert.AreEqual((ulong)Environment.ProcessId, BitConverter.ToUInt64(origin, 0));
            Assert.AreEqual(7ul, BitConverter.ToUInt64(origin, 8));
            Assert.AreEqual(9ul, BitConverter.ToUInt64(origin, 16));
            Assert.AreEqual(NativeClipboardContentKind.Remote, (await clipboard.ReadAsync(written, NativeClipboardCoordinator.MaximumBytes)).Kind,
                "this process's own remote text is never offered back");

            var local = await clipboard.WriteLocalAsync("local text", NativeClipboardCoordinator.MaximumBytes);
            Assert.IsNull(Format(NativeWindowsClipboard.CloudUploadFormat, 4), "local text is not marked");
            Assert.IsNull(Format(NativeWindowsClipboard.RemoteOriginFormat, 24));
            Assert.AreEqual(new NativeClipboardContent(NativeClipboardContentKind.Text, "local text"),
                await clipboard.ReadAsync(local, NativeClipboardCoordinator.MaximumBytes));
            await Until(() => Volatile.Read(ref changes) >= 2, 5);

            Assert.AreEqual(NativeClipboardAccessError.TooLarge,
                (await Assert.ThrowsExactlyAsync<NativeClipboardAccessException>(() => clipboard.ReadAsync(local, 4))).Error);
            Assert.AreEqual(NativeClipboardAccessError.Changed,
                (await Assert.ThrowsExactlyAsync<NativeClipboardAccessException>(() => clipboard.ReadAsync(local - 1, 100))).Error);
            Assert.AreEqual(NativeClipboardAccessError.InvalidText,
                (await Assert.ThrowsExactlyAsync<NativeClipboardAccessException>(() => clipboard.WriteRemoteAsync("a\0b", 1, 1, 100))).Error);
        }
        finally
        {
            if (original is { Kind: NativeClipboardContentKind.Text, Text: { } text }) await clipboard.WriteLocalAsync(text, 16 * 1024 * 1024);
        }
    }
}
