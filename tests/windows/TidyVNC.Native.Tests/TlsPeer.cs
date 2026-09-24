// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace TidyVNC.Native.Tests;

/// <summary>
/// An RFB 3.8 peer offering only VeNCrypt X509None (security type 19,
/// subtype 260) with a self-signed certificate, so the core's GnuTLS
/// verification fails and asks for a trust decision. Accepts any number of
/// connections; each gets a 2x2 desktop after TLS.
/// </summary>
public sealed class TlsPeer : IAsyncDisposable
{
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource stopping = new();
    private readonly Task accepting;
    private readonly X509Certificate2 certificate;
    private int established;

    public TlsPeer(string subject = "CN=tidyvnc-test")
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest(subject, key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var created = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(30));
        // SChannel needs a persisted-style key: round-trip through PKCS#12.
        certificate = X509CertificateLoader.LoadPkcs12(created.Export(X509ContentType.Pkcs12), null);
        Der = certificate.RawData;
        using var publicKey = certificate.GetRSAPublicKey()!;
        Spki = publicKey.ExportSubjectPublicKeyInfo();
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        accepting = Task.Run(AcceptAsync);
    }

    public int Port { get; }
    public string Endpoint => $"127.0.0.1::{Port}";
    public byte[] Der { get; }
    public byte[] Spki { get; }
    public int Established => Volatile.Read(ref established);

    private async Task AcceptAsync()
    {
        var clients = new List<Task>();
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
        await Task.WhenAll(clients);
    }

    private static async Task<byte[]> Read(Stream stream, int length, CancellationToken token)
    {
        var buffer = new byte[length];
        await stream.ReadExactlyAsync(buffer, token);
        return buffer;
    }

    private async Task ServeAsync(TcpClient client)
    {
        var token = stopping.Token;
        try
        {
            using (client)
            {
                client.NoDelay = true;
                var plain = client.GetStream();
                await plain.WriteAsync("RFB 003.008\n"u8.ToArray(), token);
                await Read(plain, 12, token);
                await plain.WriteAsync(new byte[] { 1, 19 }, token);
                if ((await Read(plain, 1, token))[0] != 19) return;
                await plain.WriteAsync(new byte[] { 0, 2 }, token);
                await Read(plain, 2, token);
                await plain.WriteAsync(new byte[] { 0, 1, 0, 0, 1, 4 }, token); // OK; one subtype: 260 X509None
                var chosen = await Read(plain, 4, token);
                if (chosen[2] != 1 || chosen[3] != 4) return;
                await plain.WriteAsync(new byte[] { 1 }, token);
                await using var tls = new SslStream(plain, leaveInnerStreamOpen: false);
                await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
                {
                    ServerCertificate = certificate,
                    EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                    ClientCertificateRequired = false,
                }, token);
                await tls.WriteAsync(new byte[4], token); // SecurityResult OK
                await Read(tls, 1, token); // ClientInit
                var init = new List<byte> { 0, 2, 0, 2, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0, 0, 0, 0, 3 };
                init.AddRange("tls"u8.ToArray());
                await tls.WriteAsync(init.ToArray(), token);
                Interlocked.Increment(ref established);
                var buffer = new byte[4096];
                while (await tls.ReadAsync(buffer, token) > 0) { }
            }
        }
        catch (OperationCanceledException) { }
        catch (IOException) { }
        catch (AuthenticationException) { }
        catch (ObjectDisposedException) { }
    }

    public async ValueTask DisposeAsync()
    {
        await stopping.CancelAsync();
        listener.Stop();
        await accepting;
        certificate.Dispose();
        stopping.Dispose();
    }
}
