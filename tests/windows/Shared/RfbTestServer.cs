// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace TidyVNC.Testing;

/// <summary>
/// A small RFB 3.8 server for app-level tests and manual runs (TODO W3.6): None
/// or VncAuth, a synthetic desktop with a known background and a moving
/// marker, Raw updates in the client's pixel format, and a log of every key,
/// pointer and clipboard message. Serves any number of clients at once.
/// </summary>
public sealed class RfbTestServer : IAsyncDisposable
{
    public readonly record struct KeyRecord(bool Down, uint KeySym);
    public readonly record struct PointerRecord(byte Buttons, ushort X, ushort Y);

    /// <summary>The background colour everywhere except the marker and input stripes.</summary>
    public static readonly (byte R, byte G, byte B) Background = (32, 96, 160);

    private readonly TcpListener listener;
    private readonly CancellationTokenSource stopping = new();
    private readonly Task accepting;
    private readonly string? password;
    private readonly ConcurrentBag<Task> clients = [];
    private readonly Lock gate = new();
    private readonly byte[] desktop; // RGB, row-major
    private int frame;
    private uint lastKeySym;

    public RfbTestServer(ushort width = 1024, ushort height = 768, string? password = null, int port = 0, string name = "TidyVNC test desktop")
    {
        Width = width; Height = height; this.password = password; Name = name;
        desktop = new byte[width * height * 3];
        Draw();
        listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        accepting = Task.Run(AcceptAsync);
    }

    public ushort Width { get; }
    public ushort Height { get; }
    public string Name { get; }
    public int Port { get; }
    public string Endpoint => $"127.0.0.1::{Port}";
    public ConcurrentQueue<KeyRecord> Keys { get; } = new();
    public ConcurrentQueue<PointerRecord> Pointers { get; } = new();
    public ConcurrentQueue<string> ClipboardTexts { get; } = new();
    public int ClientsSeen => clientsSeen;
    public int AuthenticatedClients => authenticated;
    public Action<string>? Log { get; set; }
    private int clientsSeen, authenticated;
    private event Action? Changed;

    /// <summary>Advances the animation (the marker moves), notifying clients.</summary>
    public void Tick()
    {
        lock (gate) { frame++; Draw(); }
        Changed?.Invoke();
    }

    private void Draw()
    {
        for (var i = 0; i < desktop.Length; i += 3) { desktop[i] = Background.R; desktop[i + 1] = Background.G; desktop[i + 2] = Background.B; }
        // A 64x64 marker moving along the top band.
        var x0 = frame * 16 % Math.Max(1, Width - 64);
        Fill(x0, 16, 64, 64, 240, 200, 40);
        // The last key's keysym as a coloured stripe along the bottom.
        if (lastKeySym != 0) Fill(0, Height - 24, Width, 24, (byte)(lastKeySym >> 16), (byte)(lastKeySym >> 8), (byte)lastKeySym);
    }

    private void Fill(int x, int y, int w, int h, byte r, byte g, byte b)
    {
        for (var row = Math.Max(0, y); row < Math.Min(Height, y + h); row++)
            for (var col = Math.Max(0, x); col < Math.Min(Width, x + w); col++)
            {
                var i = (row * Width + col) * 3;
                desktop[i] = r; desktop[i + 1] = g; desktop[i + 2] = b;
            }
    }

    private async Task AcceptAsync()
    {
        while (!stopping.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(stopping.Token); }
            catch (Exception) { return; }
            Interlocked.Increment(ref clientsSeen);
            clients.Add(Task.Run(() => ServeAsync(client)));
        }
    }

    /// <summary>A reverse connection: dials a listening viewer and serves it like an accepted client.</summary>
    public async Task ConnectReverseAsync(int port)
    {
        var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, port, stopping.Token);
        Interlocked.Increment(ref clientsSeen);
        clients.Add(Task.Run(() => ServeAsync(client)));
    }

    private sealed class PixelFormat
    {
        public int BitsPerPixel = 32;
        public bool BigEndian;
        public int RedMax = 255, GreenMax = 255, BlueMax = 255, RedShift = 16, GreenShift = 8, BlueShift;
    }

    private async Task ServeAsync(TcpClient client)
    {
        using var connection = client;
        client.NoDelay = true;
        var stream = client.GetStream();
        var token = stopping.Token;
        var writing = new SemaphoreSlim(1, 1);
        var format = new PixelFormat();
        var pendingIncremental = 0; // 1 while an incremental request waits for a change
        (int X, int Y, int W, int H) pendingArea = (0, 0, Width, Height);
        Action notify = () => { };
        try
        {
            await stream.WriteAsync("RFB 003.008\n"u8.ToArray(), token);
            await ReadExactly(stream, 12, token);
            if (password is null)
            {
                await stream.WriteAsync(new byte[] { 1, 1 }, token);
                await ReadExactly(stream, 1, token);
                await stream.WriteAsync(new byte[4], token);
            }
            else
            {
                await stream.WriteAsync(new byte[] { 1, 2 }, token);
                await ReadExactly(stream, 1, token);
                var challenge = RandomNumberGenerator.GetBytes(16);
                await stream.WriteAsync(challenge, token);
                var response = await ReadExactly(stream, 16, token);
                if (!response.AsSpan().SequenceEqual(VncAuthResponse(password, challenge)))
                {
                    var reason = "Authentication failed"u8.ToArray();
                    var failure = new byte[8 + reason.Length];
                    failure[3] = 1;
                    BinaryPrimitives.WriteUInt32BigEndian(failure.AsSpan(4), (uint)reason.Length);
                    reason.CopyTo(failure, 8);
                    await stream.WriteAsync(failure, token);
                    Log?.Invoke("client rejected: wrong password");
                    return;
                }
                await stream.WriteAsync(new byte[4], token);
            }
            Interlocked.Increment(ref authenticated);
            await ReadExactly(stream, 1, token); // ClientInit
            var name = Encoding.UTF8.GetBytes(Name);
            var init = new byte[24 + name.Length];
            BinaryPrimitives.WriteUInt16BigEndian(init, Width);
            BinaryPrimitives.WriteUInt16BigEndian(init.AsSpan(2), Height);
            byte[] serverFormat = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0];
            serverFormat.CopyTo(init, 4);
            BinaryPrimitives.WriteUInt32BigEndian(init.AsSpan(20), (uint)name.Length);
            name.CopyTo(init, 24);
            await stream.WriteAsync(init, token);
            Log?.Invoke("client connected");

            async Task SendUpdate(int x, int y, int w, int h)
            {
                byte[] message;
                lock (gate) message = RawUpdate(format, x, y, w, h);
                await writing.WaitAsync(token);
                try { await stream.WriteAsync(message, token); }
                finally { writing.Release(); }
            }
            notify = () =>
            {
                if (Interlocked.Exchange(ref pendingIncremental, 0) == 1)
                {
                    var area = pendingArea;
                    _ = SendUpdate(area.X, area.Y, area.W, area.H).ContinueWith(_ => { }, TaskScheduler.Default);
                }
            };
            Changed += notify;

            while (!token.IsCancellationRequested)
            {
                var type = (await ReadExactly(stream, 1, token))[0];
                switch (type)
                {
                    case 0: // SetPixelFormat
                    {
                        var body = await ReadExactly(stream, 19, token);
                        var f = new PixelFormat
                        {
                            BitsPerPixel = body[3], BigEndian = body[5] != 0,
                            RedMax = BinaryPrimitives.ReadUInt16BigEndian(body.AsSpan(7)), GreenMax = BinaryPrimitives.ReadUInt16BigEndian(body.AsSpan(9)),
                            BlueMax = BinaryPrimitives.ReadUInt16BigEndian(body.AsSpan(11)), RedShift = body[13], GreenShift = body[14], BlueShift = body[15],
                        };
                        if (body[6] == 0) throw new InvalidDataException("Colour-map formats are not supported by the test server");
                        format = f;
                        break;
                    }
                    case 2: // SetEncodings
                    {
                        var header = await ReadExactly(stream, 3, token);
                        var count = BinaryPrimitives.ReadUInt16BigEndian(header.AsSpan(1));
                        await ReadExactly(stream, count * 4, token);
                        break;
                    }
                    case 3: // FramebufferUpdateRequest
                    {
                        var body = await ReadExactly(stream, 9, token);
                        int x = BinaryPrimitives.ReadUInt16BigEndian(body.AsSpan(1)), y = BinaryPrimitives.ReadUInt16BigEndian(body.AsSpan(3));
                        int w = BinaryPrimitives.ReadUInt16BigEndian(body.AsSpan(5)), h = BinaryPrimitives.ReadUInt16BigEndian(body.AsSpan(7));
                        w = Math.Min(w, Width - x); h = Math.Min(h, Height - y);
                        if (body[0] == 0) await SendUpdate(x, y, w, h);
                        else { pendingArea = (x, y, w, h); Volatile.Write(ref pendingIncremental, 1); }
                        break;
                    }
                    case 4: // KeyEvent
                    {
                        var body = await ReadExactly(stream, 7, token);
                        var record = new KeyRecord(body[0] != 0, BinaryPrimitives.ReadUInt32BigEndian(body.AsSpan(3)));
                        Keys.Enqueue(record);
                        Log?.Invoke($"key {(record.Down ? "down" : "up")} 0x{record.KeySym:x}");
                        if (record.Down) { lock (gate) { lastKeySym = record.KeySym; Draw(); } Changed?.Invoke(); }
                        break;
                    }
                    case 5: // PointerEvent
                    {
                        var body = await ReadExactly(stream, 5, token);
                        var record = new PointerRecord(body[0], BinaryPrimitives.ReadUInt16BigEndian(body.AsSpan(1)), BinaryPrimitives.ReadUInt16BigEndian(body.AsSpan(3)));
                        Pointers.Enqueue(record);
                        if (record.Buttons != 0) Log?.Invoke($"pointer {record.Buttons} at {record.X},{record.Y}");
                        break;
                    }
                    case 6: // ClientCutText
                    {
                        var header = await ReadExactly(stream, 7, token);
                        var length = (int)BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(3));
                        var text = await ReadExactly(stream, Math.Min(length, 1 << 20), token);
                        ClipboardTexts.Enqueue(Encoding.Latin1.GetString(text));
                        break;
                    }
                    default:
                        throw new InvalidDataException($"Unsupported client message {type}");
                }
            }
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or EndOfStreamException or SocketException or ObjectDisposedException)
        {
        }
        catch (InvalidDataException error)
        {
            Log?.Invoke("client error: " + error.Message);
        }
        finally
        {
            Changed -= notify;
            Log?.Invoke("client disconnected");
        }
    }

    private byte[] RawUpdate(PixelFormat format, int x, int y, int w, int h)
    {
        var bytesPerPixel = format.BitsPerPixel / 8;
        var message = new byte[16 + w * h * bytesPerPixel];
        message[0] = 0; message[3] = 1;
        BinaryPrimitives.WriteUInt16BigEndian(message.AsSpan(4), (ushort)x);
        BinaryPrimitives.WriteUInt16BigEndian(message.AsSpan(6), (ushort)y);
        BinaryPrimitives.WriteUInt16BigEndian(message.AsSpan(8), (ushort)w);
        BinaryPrimitives.WriteUInt16BigEndian(message.AsSpan(10), (ushort)h);
        var offset = 16;
        for (var row = y; row < y + h; row++)
        {
            for (var col = x; col < x + w; col++)
            {
                var i = (row * Width + col) * 3;
                var value = (uint)(desktop[i] * format.RedMax / 255) << format.RedShift |
                            (uint)(desktop[i + 1] * format.GreenMax / 255) << format.GreenShift |
                            (uint)(desktop[i + 2] * format.BlueMax / 255) << format.BlueShift;
                for (var b = 0; b < bytesPerPixel; b++)
                {
                    var shift = format.BigEndian ? (bytesPerPixel - 1 - b) * 8 : b * 8;
                    message[offset++] = (byte)(value >> shift);
                }
            }
        }
        return message;
    }

    /// <summary>The VncAuth response: DES-ECB with the bit-reversed password bytes as the key.</summary>
    public static byte[] VncAuthResponse(string password, byte[] challenge)
    {
        var key = new byte[8];
        var bytes = Encoding.Latin1.GetBytes(password);
        for (var i = 0; i < 8 && i < bytes.Length; i++)
        {
            byte b = bytes[i], reversed = 0;
            for (var bit = 0; bit < 8; bit++) if ((b & (1 << bit)) != 0) reversed |= (byte)(0x80 >> bit);
            key[i] = reversed;
        }
#pragma warning disable CA5351 // VncAuth is DES by definition; this is a test peer.
        using var des = DES.Create();
#pragma warning restore CA5351
        des.Key = key;
        return des.EncryptEcb(challenge, PaddingMode.None);
    }

    private static async Task<byte[]> ReadExactly(NetworkStream stream, int length, CancellationToken token)
    {
        var buffer = new byte[length];
        await stream.ReadExactlyAsync(buffer, token);
        return buffer;
    }

    public async ValueTask DisposeAsync()
    {
        await stopping.CancelAsync();
        listener.Stop();
        try { await accepting; } catch (OperationCanceledException) { }
        try { await Task.WhenAll(clients); } catch (Exception) { }
        stopping.Dispose();
    }
}
