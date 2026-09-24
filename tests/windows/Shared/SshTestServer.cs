// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace TidyVNC.Testing;

/// <summary>
/// A minimal SSH-2 server for tests of the Windows OpenSSH client (plans/
/// native-ui-winui D17, W0.11, W4.9). It speaks exactly one algorithm set
/// that OpenSSH offers by default (ecdh-sha2-nistp256, ecdsa-sha2-nistp256,
/// aes128-ctr, hmac-sha2-256, no compression), authenticates with "none" or
/// a password, and serves direct-tcpip channels (what <c>ssh -W</c> and
/// <c>ssh -L</c> open) by connecting to the requested loopback target. It
/// is not a general SSH server and never runs outside tests.
/// </summary>
public sealed class SshTestServer : IAsyncDisposable
{
    private const string KexName = "ecdh-sha2-nistp256", HostKeyName = "ecdsa-sha2-nistp256", CipherName = "aes128-ctr", MacName = "hmac-sha2-256";
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource stopping = new();
    private readonly ECDsa hostKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    private readonly Task accepting;
    private readonly ConcurrentBag<Task> clients = [];

    public SshTestServer(string? password = null)
    {
        Password = password;
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        accepting = Task.Run(AcceptAsync);
    }

    public int Port { get; }
    /// <summary>Null accepts the "none" method; otherwise only this password.</summary>
    public string? Password { get; }
    public int Authenticated => Volatile.Read(ref authenticated);
    public int ForwardedChannels => Volatile.Read(ref forwarded);
    public int FailedPasswords => Volatile.Read(ref failedPasswords);
    /// <summary>The requested direct-tcpip targets ("host:port").</summary>
    public ConcurrentQueue<string> Targets { get; } = new();
    private int authenticated, forwarded, failedPasswords;

    /// <summary>The host key as an OpenSSH known_hosts key ("ecdsa-sha2-nistp256 AAAA…").</summary>
    public string KnownHostsKey => $"{HostKeyName} {Convert.ToBase64String(HostKeyBlob())}";

    private byte[] HostKeyBlob()
    {
        var p = hostKey.ExportParameters(false).Q;
        var w = new Wire();
        w.String(HostKeyName); w.String("nistp256"); w.String([0x04, .. p.X!, .. p.Y!]);
        return w.ToArray();
    }

    private async Task AcceptAsync()
    {
        try
        {
            while (!stopping.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(stopping.Token);
                clients.Add(Task.Run(() => ServeAsync(client)));
            }
        }
        catch (OperationCanceledException) { }
        catch (SocketException) { }
    }

    private async Task ServeAsync(TcpClient client)
    {
        using (client)
        {
            try { await new Connection(this, client.GetStream(), stopping.Token).RunAsync(); }
            catch (Exception error) when (error is IOException or OperationCanceledException or EndOfStreamException or InvalidDataException or SocketException or ObjectDisposedException) { }
        }
    }

    public async ValueTask DisposeAsync()
    {
        await stopping.CancelAsync();
        listener.Stop();
        await accepting;
        await Task.WhenAll(clients);
        hostKey.Dispose();
        stopping.Dispose();
    }

    /// <summary>SSH wire encoding (RFC 4251).</summary>
    private sealed class Wire
    {
        private readonly MemoryStream buffer = new();
        public Wire Byte(byte value) { buffer.WriteByte(value); return this; }
        public Wire UInt32(uint value) { Span<byte> b = stackalloc byte[4]; BinaryPrimitives.WriteUInt32BigEndian(b, value); buffer.Write(b); return this; }
        public Wire Bool(bool value) => Byte(value ? (byte)1 : (byte)0);
        public Wire String(ReadOnlySpan<byte> value) { UInt32((uint)value.Length); buffer.Write(value); return this; }
        public Wire String(string value) => String(Encoding.UTF8.GetBytes(value));
        public Wire Raw(ReadOnlySpan<byte> value) { buffer.Write(value); return this; }
        public Wire MPInt(ReadOnlySpan<byte> unsignedBigEndian)
        {
            var value = unsignedBigEndian.TrimStart((byte)0);
            if (value.Length > 0 && (value[0] & 0x80) != 0) { UInt32((uint)value.Length + 1); buffer.WriteByte(0); buffer.Write(value); }
            else String(value);
            return this;
        }
        public byte[] ToArray() => buffer.ToArray();
    }

    private sealed class Reader(byte[] data, int offset = 0)
    {
        private int position = offset;
        public byte Byte() => position < data.Length ? data[position++] : throw new InvalidDataException("short");
        public uint UInt32() { var v = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(position, 4)); position += 4; return v; }
        public bool Bool() => Byte() != 0;
        public byte[] Bytes() { var n = (int)UInt32(); if (n < 0 || position + n > data.Length) throw new InvalidDataException("length"); var v = data.AsSpan(position, n).ToArray(); position += n; return v; }
        public string Text() => Encoding.UTF8.GetString(Bytes());
    }

    private sealed class Connection(SshTestServer server, NetworkStream stream, CancellationToken token)
    {
        private readonly SemaphoreSlim sending = new(1, 1);
        private uint sendSequence, receiveSequence;
        private Aes? sendCipher, receiveCipher;
        private byte[] sendCounter = [], receiveCounter = [], sendMacKey = [], receiveMacKey = [];
        private byte[]? sessionId;
        private readonly Dictionary<uint, Channel> channels = [];
        private uint nextChannel;

        private sealed class Channel
        {
            public uint Remote;
            public long RemoteWindow;
            public uint MaximumPacket;
            public TcpClient? Target;
            public NetworkStream? Stream;
            public readonly SemaphoreSlim Window = new(0);
        }

        public async Task RunAsync()
        {
            var serverVersion = "SSH-2.0-TidyVNCTest_1.0";
            await stream.WriteAsync(Encoding.ASCII.GetBytes(serverVersion + "\r\n"), token);
            var clientVersion = await ReadLineAsync();
            if (!clientVersion.StartsWith("SSH-2.0-", StringComparison.Ordinal)) throw new InvalidDataException("version");

            var serverKexInit = KexInit();
            await SendAsync(serverKexInit);
            var clientKexInit = await ReceiveAsync();
            if (clientKexInit[0] != 20) throw new InvalidDataException("kexinit");
            var init = await ReceiveAsync();
            if (init[0] != 30) throw new InvalidDataException("ecdh init");
            var clientPublic = new Reader(init, 1).Bytes();
            using var ephemeral = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
            var q = ephemeral.ExportParameters(false).Q;
            byte[] serverPublic = [0x04, .. q.X!, .. q.Y!];
            using var peer = ECDiffieHellman.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = clientPublic.AsSpan(1, 32).ToArray(), Y = clientPublic.AsSpan(33, 32).ToArray() },
            });
            var shared = ephemeral.DeriveRawSecretAgreement(peer.PublicKey);
            var hostBlob = server.HostKeyBlob();
            var exchange = new Wire().String(clientVersion).String(serverVersion).String(clientKexInit).String(serverKexInit)
                .String(hostBlob).String(clientPublic).String(serverPublic).MPInt(shared).ToArray();
            var hash = SHA256.HashData(exchange);
            sessionId ??= hash;
            var signature = server.hostKey.SignData(hash, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
            var signatureBlob = new Wire().String(HostKeyName)
                .String(new Wire().MPInt(signature.AsSpan(0, 32)).MPInt(signature.AsSpan(32, 32)).ToArray()).ToArray();
            await SendAsync(new Wire().Byte(31).String(hostBlob).String(serverPublic).String(signatureBlob).ToArray());
            await SendAsync([21]);
            var newKeys = await ReceiveAsync();
            if (newKeys[0] != 21) throw new InvalidDataException("newkeys");

            byte[] Derive(char letter, int length)
            {
                var k = new Wire().MPInt(shared).ToArray();
                var result = SHA256.HashData([.. k, .. hash, (byte)letter, .. sessionId!]);
                while (result.Length < length) result = [.. result, .. SHA256.HashData([.. k, .. hash, .. result])];
                return result[..length];
            }
            receiveCounter = Derive('A', 16); sendCounter = Derive('B', 16);
            receiveCipher = Aes.Create(); receiveCipher.Key = Derive('C', 16);
            sendCipher = Aes.Create(); sendCipher.Key = Derive('D', 16);
            receiveMacKey = Derive('E', 32); sendMacKey = Derive('F', 32);

            await ServiceLoopAsync();
        }

        private static byte[] KexInit()
        {
            var w = new Wire().Byte(20).Raw(RandomNumberGenerator.GetBytes(16));
            foreach (var list in new[] { KexName, HostKeyName, CipherName, CipherName, MacName, MacName, "none", "none", "", "" }) w.String(list);
            return w.Bool(false).UInt32(0).ToArray();
        }

        private async Task<string> ReadLineAsync()
        {
            var line = new List<byte>();
            var one = new byte[1];
            while (line.Count < 255)
            {
                await stream.ReadExactlyAsync(one, token);
                if (one[0] == '\n') return Encoding.ASCII.GetString(line.ToArray()).TrimEnd('\r');
                line.Add(one[0]);
            }
            throw new InvalidDataException("version line");
        }

        private static void Ctr(Aes aes, byte[] counter, Span<byte> data)
        {
            Span<byte> block = stackalloc byte[16];
            for (var offset = 0; offset < data.Length; offset += 16)
            {
                aes.EncryptEcb(counter, block, PaddingMode.None);
                for (var i = 0; i < 16 && offset + i < data.Length; i++) data[offset + i] ^= block[i];
                for (var i = 15; i >= 0 && ++counter[i] == 0; i--) { }
            }
        }

        private async Task SendAsync(byte[] payload)
        {
            await sending.WaitAsync(token);
            try
            {
                var blockSize = sendCipher is null ? 8 : 16;
                var padding = blockSize - (payload.Length + 5) % blockSize;
                if (padding < 4) padding += blockSize;
                var packet = new byte[5 + payload.Length + padding];
                BinaryPrimitives.WriteUInt32BigEndian(packet, (uint)(packet.Length - 4));
                packet[4] = (byte)padding;
                payload.CopyTo(packet, 5);
                RandomNumberGenerator.Fill(packet.AsSpan(5 + payload.Length));
                byte[] mac = [];
                if (sendCipher is not null)
                {
                    var sequence = new byte[4];
                    BinaryPrimitives.WriteUInt32BigEndian(sequence, sendSequence);
                    mac = HMACSHA256.HashData(sendMacKey, (byte[])[.. sequence, .. packet]);
                    Ctr(sendCipher, sendCounter, packet);
                }
                sendSequence++;
                await stream.WriteAsync(packet, token);
                if (mac.Length > 0) await stream.WriteAsync(mac, token);
            }
            finally { sending.Release(); }
        }

        private async Task<byte[]> ReceiveAsync()
        {
            while (true)
            {
                var blockSize = receiveCipher is null ? 8 : 16;
                var first = new byte[blockSize];
                await stream.ReadExactlyAsync(first, token);
                if (receiveCipher is not null) Ctr(receiveCipher, receiveCounter, first);
                var length = BinaryPrimitives.ReadUInt32BigEndian(first);
                if (length is < 12 or > 256 * 1024) throw new InvalidDataException("packet length");
                var rest = new byte[length + 4 - blockSize];
                await stream.ReadExactlyAsync(rest, token);
                if (receiveCipher is not null) Ctr(receiveCipher, receiveCounter, rest);
                byte[] packet = [.. first, .. rest];
                if (receiveCipher is not null)
                {
                    var mac = new byte[32];
                    await stream.ReadExactlyAsync(mac, token);
                    var sequence = new byte[4];
                    BinaryPrimitives.WriteUInt32BigEndian(sequence, receiveSequence);
                    if (!CryptographicOperations.FixedTimeEquals(mac, HMACSHA256.HashData(receiveMacKey, (byte[])[.. sequence, .. packet])))
                        throw new InvalidDataException("mac");
                }
                receiveSequence++;
                var payload = packet.AsSpan(5, (int)length - 1 - packet[4]).ToArray();
                if (payload[0] is 2 or 4) continue; // IGNORE, DEBUG
                if (payload[0] == 1) throw new EndOfStreamException("disconnect");
                return payload;
            }
        }

        private async Task ServiceLoopAsync()
        {
            while (true)
            {
                var message = await ReceiveAsync();
                var r = new Reader(message, 1);
                switch (message[0])
                {
                    case 5: // SERVICE_REQUEST
                        await SendAsync(new Wire().Byte(6).String(r.Text()).ToArray());
                        break;
                    case 50: // USERAUTH_REQUEST
                    {
                        r.Text(); r.Text();
                        var method = r.Text();
                        var accepted = method switch
                        {
                            "none" => server.Password is null,
                            "password" => !r.Bool() && r.Text() == server.Password && server.Password is not null,
                            _ => false,
                        };
                        if (method == "password" && !accepted) Interlocked.Increment(ref server.failedPasswords);
                        if (accepted) { Interlocked.Increment(ref server.authenticated); await SendAsync([52]); }
                        else await SendAsync(new Wire().Byte(51).String(server.Password is null ? "none" : "password").Bool(false).ToArray());
                        break;
                    }
                    case 80: // GLOBAL_REQUEST
                        r.Text();
                        if (r.Bool()) await SendAsync([82]);
                        break;
                    case 90: // CHANNEL_OPEN
                        await OpenAsync(r);
                        break;
                    case 93: // WINDOW_ADJUST
                    {
                        var channel = channels[r.UInt32()];
                        Interlocked.Add(ref channel.RemoteWindow, r.UInt32());
                        channel.Window.Release();
                        break;
                    }
                    case 94: // CHANNEL_DATA
                    {
                        var id = r.UInt32();
                        var data = r.Bytes();
                        if (channels.TryGetValue(id, out var channel) && channel.Stream is { } target)
                        {
                            await target.WriteAsync(data, token);
                            await SendAsync(new Wire().Byte(93).UInt32(channel.Remote).UInt32((uint)data.Length).ToArray());
                        }
                        break;
                    }
                    case 96: // CHANNEL_EOF
                        if (channels.TryGetValue(r.UInt32(), out var ended)) ended.Target?.Client.Shutdown(SocketShutdown.Send);
                        break;
                    case 97: // CHANNEL_CLOSE
                    {
                        var id = r.UInt32();
                        if (channels.Remove(id, out var closed))
                        {
                            closed.Target?.Dispose();
                            await SendAsync(new Wire().Byte(97).UInt32(closed.Remote).ToArray());
                        }
                        break;
                    }
                    case 98: // CHANNEL_REQUEST
                    {
                        var id = r.UInt32();
                        r.Text();
                        if (r.Bool() && channels.TryGetValue(id, out var channel)) await SendAsync(new Wire().Byte(100).UInt32(channel.Remote).ToArray());
                        break;
                    }
                    default:
                        await SendAsync(new Wire().Byte(3).UInt32(receiveSequence - 1).ToArray()); // UNIMPLEMENTED
                        break;
                }
            }
        }

        private async Task OpenAsync(Reader r)
        {
            var type = r.Text();
            var remote = r.UInt32();
            var window = r.UInt32();
            var maximum = r.UInt32();
            if (type != "direct-tcpip")
            {
                await SendAsync(new Wire().Byte(92).UInt32(remote).UInt32(1).String("only direct-tcpip").String("").ToArray());
                return;
            }
            var host = r.Text();
            var port = (int)r.UInt32();
            server.Targets.Enqueue($"{host}:{port}");
            var target = new TcpClient();
            try { await target.ConnectAsync(host == "localhost" ? "127.0.0.1" : host, port, token); }
            catch (SocketException)
            {
                target.Dispose();
                await SendAsync(new Wire().Byte(92).UInt32(remote).UInt32(2).String("connect failed").String("").ToArray());
                return;
            }
            var id = nextChannel++;
            var channel = new Channel { Remote = remote, RemoteWindow = window, MaximumPacket = Math.Min(maximum, 32768), Target = target, Stream = target.GetStream() };
            channels[id] = channel;
            Interlocked.Increment(ref server.forwarded);
            await SendAsync(new Wire().Byte(91).UInt32(remote).UInt32(id).UInt32(2 * 1024 * 1024).UInt32(32768).ToArray());
            _ = Task.Run(() => PumpAsync(channel));
        }

        /// <summary>Target → client, respecting the client's window.</summary>
        private async Task PumpAsync(Channel channel)
        {
            var buffer = new byte[channel.MaximumPacket];
            try
            {
                while (true)
                {
                    var count = await channel.Stream!.ReadAsync(buffer, token);
                    if (count == 0) break;
                    var offset = 0;
                    while (offset < count)
                    {
                        while (Interlocked.Read(ref channel.RemoteWindow) <= 0) await channel.Window.WaitAsync(token);
                        var chunk = (int)Math.Min(count - offset, Interlocked.Read(ref channel.RemoteWindow));
                        Interlocked.Add(ref channel.RemoteWindow, -chunk);
                        await SendAsync(new Wire().Byte(94).UInt32(channel.Remote).String(buffer.AsSpan(offset, chunk)).ToArray());
                        offset += chunk;
                    }
                }
                await SendAsync(new Wire().Byte(96).UInt32(channel.Remote).ToArray());
                await SendAsync(new Wire().Byte(97).UInt32(channel.Remote).ToArray());
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException or SocketException) { }
        }
    }
}
