// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using TidyVNC.Native.Desktop;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Hold Ctrl, Hold Alt and Send Ctrl+Alt+Del (plans/native-ui-winui TODO
/// W5.11, PARITY M05-M07; macOS NativeDesktopCommandsTests): the keys reach
/// the server in order, held modifiers are pressed again after focus
/// returns, and view-only refuses them.
/// </summary>
[TestClass]
public sealed class DesktopCommandTests
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

    /// <summary>An RFB KeyEvent as it appears on the wire.</summary>
    private static byte[] KeyEvent(bool down, uint keysym) =>
        [4, (byte)(down ? 1 : 0), 0, 0, (byte)(keysym >> 24), (byte)(keysym >> 16), (byte)(keysym >> 8), (byte)keysym];

    private sealed class Host(NativeSession session) : INativeDesktopCommandHost
    {
        public int Cleared { get; private set; }
        public bool FocusForCommand()
        {
            if (!session.IsFocused) session.SetFocused(true);
            return true;
        }
        public void ClearCommandInput() => Cleared++;
    }

    [TestMethod]
    public async Task HeldModifiersAndTheSecureAttentionChordReachTheServer()
    {
        using var ui = new SingleThreadDispatcher();
        await using var peer = new LoopbackPeer();
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var session = runtime.CreateSession(new NativeSessionConfiguration { SecurityTypes = [1] });
            var commands = new NativeDesktopCommands();
            try
            {
                commands.Bind(session);
                var host = new Host(session);
                Assert.IsFalse(commands.CanSendKeys, "not before a host and a connection");
                await session.ConnectAsync(peer.Endpoint);
                commands.Attach(host);
                Assert.IsTrue(commands.CanSendKeys);

                commands.ToggleControl();
                Assert.IsTrue(commands.ControlSelected);
                await Until(() => peer.Received(KeyEvent(true, 0xffe3)), "Ctrl held");
                Assert.IsTrue(host.Cleared > 0, "the command starts from a clean local state");

                commands.SendControlAltDelete();
                await Until(() => peer.Received(KeyEvent(false, 0xffff)), "Delete released");
                Assert.IsTrue(peer.Received([.. KeyEvent(true, 0xffe9), .. KeyEvent(true, 0xffff), .. KeyEvent(false, 0xffff), .. KeyEvent(false, 0xffe9)]),
                    "Alt, Delete, Delete up, Alt up");
                Assert.IsTrue(commands.ControlSelected, "a held Ctrl stays held after the chord");

                // Focus loss releases everything; focus back presses Ctrl again.
                var before = peer.Occurrences(KeyEvent(true, 0xffe3));
                session.SetFocused(false);
                await Until(() => peer.Occurrences(KeyEvent(false, 0xffe3)) >= 1, "Ctrl released with focus");
                session.SetFocused(true);
                await Until(() => peer.Occurrences(KeyEvent(true, 0xffe3)) > before, "Ctrl pressed again");

                commands.ToggleControl();
                Assert.IsFalse(commands.ControlSelected);
                commands.ToggleAlt();
                await Until(() => peer.Occurrences(KeyEvent(true, 0xffe9)) >= 2, "Alt held");

                session.SetViewOnly(true);
                Assert.IsFalse(commands.CanSendKeys);
                Assert.ThrowsExactly<NativeError>(() => commands.ToggleAlt(), "view-only refuses key commands");
                Assert.IsTrue(commands.AltSelected, "a refused command changes nothing");
            }
            finally
            {
                commands.Stop();
                await session.CloseAsync();
                await runtime.ShutdownAsync();
            }
            return 0;
        });
    }
}
