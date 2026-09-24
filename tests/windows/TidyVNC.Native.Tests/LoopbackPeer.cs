// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Net;
using System.Net.Sockets;

namespace TidyVNC.Native.Tests;

/// <summary>
/// An independent RFB 3.8 server for tests (the C# counterpart of the peers in
/// tests/unit/viewerabi.cxx). It offers None or VncAuth, sends a desktop
/// (default 2x2) with one Raw update of colour (10,20,30), records client
/// bytes, and can send bells, clipboard text and full-frame update floods.
/// In reverse mode it connects to a viewer's listener instead of accepting.
/// </summary>
public sealed class LoopbackPeer : IAsyncDisposable
{
    // The DES response for "password" to the fixed challenge 0..15 (d3des.cxx).
    private static readonly byte[] Challenge = [.. Enumerable.Range(0, 16).Select(i => (byte)i)];
    private static readonly byte[] Expected = [0xb8, 0x66, 0x92, 0x41, 0x25, 0xc8, 0xee, 0xbb, 0x9d, 0xeb, 0xc1, 0xdb, 0x61, 0xc5, 0x38, 0xe2];

    private readonly TcpListener? listener;
    private readonly bool authentication;
    private readonly ushort width, height;
    private readonly bool pattern;
    private readonly CancellationTokenSource stopping = new();
    private readonly Task<string?> run;
    private readonly List<byte> received = [];
    private readonly TaskCompletionSource released = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly SemaphoreSlim writing = new(1, 1);
    private NetworkStream? stream;

    /// <param name="pattern">The first frame is a deterministic colour pattern instead of one colour (scaling checks).</param>
    public LoopbackPeer(bool authentication = false, bool delayServerInit = false, ushort width = 2, ushort height = 2, int? reversePort = null,
                        bool pattern = false)
    {
        this.authentication = authentication; this.pattern = pattern;
        this.width = width; this.height = height;
        DelayServerInit = delayServerInit;
        if (reversePort is null)
        {
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        }
        else Port = reversePort.Value;
        run = Task.Run(RunAsync);
    }

    public int Port { get; }
    public string Endpoint => $"127.0.0.1::{Port}";
    public bool Verified { get; private set; }
    public bool Established { get; private set; }
    public bool DelayServerInit { get; }

    /// <summary>Lets a delayed handshake send ServerInit.</summary>
    public void Release() => released.TrySetResult();

    public bool Received(ReadOnlySpan<byte> bytes)
    {
        lock (received) return received.ToArray().AsSpan().IndexOf(bytes) >= 0;
    }

    public int Occurrences(ReadOnlySpan<byte> bytes)
    {
        byte[] all;
        lock (received) all = received.ToArray();
        var count = 0;
        for (var span = all.AsSpan(); span.IndexOf(bytes) is var at && at >= 0; span = span[(at + bytes.Length)..]) count++;
        return count;
    }

    public async Task SendAsync(byte[] bytes)
    {
        if (stream is null) throw new InvalidOperationException("No client");
        await writing.WaitAsync(stopping.Token);
        try { await stream.WriteAsync(bytes, stopping.Token); }
        finally { writing.Release(); }
    }

    public Task BellAsync() => SendAsync([2]);

    public Task ClipboardAsync(string latin1)
    {
        var text = System.Text.Encoding.Latin1.GetBytes(latin1);
        var message = new byte[8 + text.Length];
        message[0] = 3;
        message[4] = (byte)(text.Length >> 24); message[5] = (byte)(text.Length >> 16);
        message[6] = (byte)(text.Length >> 8); message[7] = (byte)text.Length;
        text.CopyTo(message, 8);
        return SendAsync(message);
    }

    /// <summary>One ExtendedDesktopSize screen: ID, position, size and flags (16 bytes).</summary>
    public static byte[] Screen(uint id, ushort x, ushort y, ushort width, ushort height, uint flags = 0) =>
    [
        (byte)(id >> 24), (byte)(id >> 16), (byte)(id >> 8), (byte)id,
        (byte)(x >> 8), (byte)x, (byte)(y >> 8), (byte)y, (byte)(width >> 8), (byte)width, (byte)(height >> 8), (byte)height,
        (byte)(flags >> 24), (byte)(flags >> 16), (byte)(flags >> 8), (byte)flags,
    ];

    /// <summary>
    /// An ExtendedDesktopSize update (tests/macos/support/resize-peer.cxx):
    /// reason 0 announces the server layout, reason 1 answers the client's
    /// SetDesktopSize with a status (0 accepts).
    /// </summary>
    public Task LayoutAsync(ushort reason, ushort status, ushort width, ushort height, params byte[][] screens)
    {
        var message = new List<byte> { 0, 0, 0, 1, (byte)(reason >> 8), (byte)reason, (byte)(status >> 8), (byte)status,
                                        (byte)(width >> 8), (byte)width, (byte)(height >> 8), (byte)height, 0xFF, 0xFF, 0xFE, 0xCC,
                                        (byte)screens.Length, 0, 0, 0 };
        foreach (var screen in screens) message.AddRange(screen);
        return SendAsync([.. message]);
    }

    /// <summary>The client's SetDesktopSize for a size and screens, as it appears on the wire.</summary>
    public static byte[] SetDesktopSize(ushort width, ushort height, params byte[][] screens) =>
        [251, 0, (byte)(width >> 8), (byte)width, (byte)(height >> 8), (byte)height, (byte)screens.Length, 0, .. screens.SelectMany(s => s)];

    /// <summary>Full-frame Raw updates, each a new colour.</summary>
    public async Task FloodAsync(int updates)
    {
        for (var n = 0; n < updates; n++) await SendAsync(RawUpdate((byte)(n * 7), (byte)(n * 11), (byte)(n * 13)));
    }

    private byte[] RawUpdate(byte red, byte green, byte blue)
    {
        var pixels = width * height;
        var message = new byte[4 + 12 + pixels * 4];
        message[3] = 1;
        message[8] = (byte)(width >> 8); message[9] = (byte)width;
        message[10] = (byte)(height >> 8); message[11] = (byte)height;
        for (var i = 0; i < pixels; i++)
        {
            var offset = 16 + i * 4;
            message[offset] = blue; message[offset + 1] = green; message[offset + 2] = red;
        }
        return message;
    }

    /// <summary>A full-frame Raw update whose every pixel differs from its neighbours (checks filters and placement).</summary>
    private byte[] PatternUpdate()
    {
        var message = RawUpdate(0, 0, 0);
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var offset = 16 + (y * width + x) * 4;
                message[offset] = (byte)(x * 37 + y * 11);       // blue
                message[offset + 1] = (byte)(x * 5 + y * 53);    // green
                message[offset + 2] = (byte)((x ^ y) * 29);      // red
            }
        return message;
    }

    /// <summary>Closes the client connection from the server side.</summary>
    public void Drop() => stream?.Socket.Close();

    private async Task<string?> RunAsync()
    {
        try
        {
            var token = stopping.Token;
            using var client = listener is not null ? await listener.AcceptTcpClientAsync(token) : new TcpClient();
            if (listener is null) await client.ConnectAsync(IPAddress.Loopback, Port, token);
            client.NoDelay = true;
            stream = client.GetStream();
            await stream.WriteAsync("RFB 003.008\n"u8.ToArray(), token);
            await ReadAsync(12, token);
            await stream.WriteAsync(new byte[] { 1, (byte)(authentication ? 2 : 1) }, token);
            await ReadAsync(1, token);
            if (authentication)
            {
                await stream.WriteAsync(Challenge, token);
                var response = await ReadAsync(16, token);
                Verified = response.AsSpan().SequenceEqual(Expected);
                await stream.WriteAsync(new byte[] { 0, 0, 0, (byte)(Verified ? 0 : 1) }, token);
                if (!Verified)
                {
                    await stream.WriteAsync(new byte[] { 0, 0, 0, 5, (byte)'w', (byte)'r', (byte)'o', (byte)'n', (byte)'g' }, token);
                    return null;
                }
            }
            else await stream.WriteAsync(new byte[4], token);
            await ReadAsync(1, token); // ClientInit
            if (DelayServerInit) await released.Task.WaitAsync(token);
            var init = new List<byte> { (byte)(width >> 8), (byte)width, (byte)(height >> 8), (byte)height,
                                        32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0, 0, 0, 0, 4 };
            init.AddRange("peer"u8.ToArray());
            init.AddRange(pattern ? PatternUpdate() : RawUpdate(10, 20, 30));
            await SendAsync(init.ToArray());
            Established = true;
            var buffer = new byte[4096];
            while (!token.IsCancellationRequested)
            {
                var count = await stream.ReadAsync(buffer, token);
                if (count == 0) break;
                lock (received) received.AddRange(buffer.AsSpan(0, count).ToArray());
            }
            return null;
        }
        catch (OperationCanceledException) { return null; }
        catch (IOException) { return null; }
        catch (SocketException) { return null; }
        catch (ObjectDisposedException) { return null; }
        catch (Exception error) { return error.Message; }
    }

    private async Task<byte[]> ReadAsync(int length, CancellationToken token)
    {
        var buffer = new byte[length];
        await stream!.ReadExactlyAsync(buffer, token);
        return buffer;
    }

    public async ValueTask DisposeAsync()
    {
        released.TrySetResult();
        await stopping.CancelAsync();
        listener?.Stop();
        var failure = await run;
        stopping.Dispose();
        writing.Dispose();
        if (failure is not null) throw new InvalidOperationException("Peer failed: " + failure);
    }
}
