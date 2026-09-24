// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using TidyVNC.Native.Tunnel;

namespace TidyVNC.Native.Tests;

/// <summary>
/// The askpass endpoint's own rules (plans/native-ui-winui TODO W4.9), driven
/// through its pipe protocol directly: tokens, client admission, host key
/// review matching and the exact answers it returns.
/// </summary>
[TestClass]
public sealed class AskpassServerTests
{
    private sealed class Recorder(Func<NativeSshPrompt, byte[]?> answer) : INativeSshInteraction
    {
        public List<NativeSshPrompt> Seen { get; } = [];

        public Task<byte[]?> AnswerAsync(NativeSshPrompt prompt, CancellationToken cancellation)
        {
            lock (Seen) Seen.Add(prompt);
            return Task.FromResult(answer(prompt));
        }
    }

    private static readonly byte[] EcdsaKey = MakeEcdsaKey();

    private static byte[] MakeEcdsaKey()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var q = key.ExportParameters(false).Q;
        static byte[] Field(byte[] value) => [(byte)(value.Length >> 24), (byte)(value.Length >> 16), (byte)(value.Length >> 8), (byte)value.Length, .. value];
        return [.. Field("ecdsa-sha2-nistp256"u8.ToArray()), .. Field("nistp256"u8.ToArray()), .. Field([4, .. q.X!, .. q.Y!])];
    }

    private static byte[]? Ask(NativeSshAskpassServer server, NativeSshAskpassProtocol.Kind kind, params string[] fields)
        => Ask(server, Convert.FromHexString(server.Environment[NativeSshAskpassProtocol.TokenVariable]), kind, fields);

    private static byte[]? Ask(NativeSshAskpassServer server, byte[] token, NativeSshAskpassProtocol.Kind kind, params string[] fields)
    {
        using var pipe = new NamedPipeClientStream(".", server.Name, PipeDirection.InOut);
        pipe.Connect(5000);
        pipe.Write(NativeSshAskpassProtocol.EncodeRequest(kind, token, fields));
        return NativeSshAskpassProtocol.DecodeResponse(pipe);
    }

    private static string HostKeyQuestion(string host, string family, string fingerprint)
        => $"The authenticity of host '{host} ({host})' can't be established.\n{family} key fingerprint is {fingerprint}.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ";

    [TestMethod]
    public async Task ApprovedHostKeysAnswerWithTheComputedFingerprintOnly()
    {
        var recorder = new Recorder(prompt => prompt.Kind == NativeSshPromptKind.Secret ? "p4ss"u8.ToArray() : [1]);
        await using var server = new NativeSshAskpassServer(recorder, pid => pid == Environment.ProcessId);
        var key = NativeSshHostKey.Parse("gateway.example", "ecdsa-sha2-nistp256", Convert.ToBase64String(EcdsaKey))!;
        await Task.Run(() => Ask(server, NativeSshAskpassProtocol.Kind.HostKey, "ORDER", "gateway.example", "", ""));
        Assert.IsNull(server.ObservedHostKey, "only HOSTNAME lookups are observations");
        CollectionAssert.AreEqual(Array.Empty<byte>(), await Task.Run(() => Ask(server, NativeSshAskpassProtocol.Kind.HostKey, "HOSTNAME", "gateway.example", key.Algorithm, Convert.ToBase64String(key.Blob))));
        Assert.AreEqual(key.Fingerprint, server.ObservedHostKey!.Fingerprint);
        var other = NativeSshHostKey.Parse("gateway.example", "ecdsa-sha2-nistp256", Convert.ToBase64String(MakeEcdsaKey()))!;
        foreach (var reason in new[] { "ADDRESS", "ORDER" })
            await Task.Run(() => Ask(server, NativeSshAskpassProtocol.Kind.HostKey, reason, "gateway.example", other.Algorithm, Convert.ToBase64String(other.Blob)));
        Assert.AreEqual(key.Fingerprint, server.ObservedHostKey!.Fingerprint, "address and order lookups never replace the host name observation");

        var answer = await Task.Run(() => Ask(server, NativeSshAskpassProtocol.Kind.Prompt, HostKeyQuestion("gateway.example", "ECDSA", key.Fingerprint), ""));
        Assert.AreEqual(key.Fingerprint, Encoding.ASCII.GetString(answer!), "approval returns the fingerprint, never a bare yes");
        Assert.AreEqual(NativeSshPromptKind.HostKey, recorder.Seen.Single().Kind);

        var secret = await Task.Run(() => Ask(server, NativeSshAskpassProtocol.Kind.Prompt, "tester@gateway.example's password: ", ""));
        Assert.AreEqual("p4ss", Encoding.UTF8.GetString(secret!));
        Assert.AreEqual(NativeSshPromptKind.Secret, recorder.Seen[^1].Kind);
        var question = await Task.Run(() => Ask(server, NativeSshAskpassProtocol.Kind.Prompt, "Allow use of key?", "confirm"));
        Assert.AreEqual(NativeSshPromptKind.Question, recorder.Seen[^1].Kind);
    }

    [TestMethod]
    public async Task MismatchedHostKeyQuestionsAreRefusedWithoutAsking()
    {
        var recorder = new Recorder(_ => [1]);
        await using var server = new NativeSshAskpassServer(recorder, pid => pid == Environment.ProcessId);
        var key = NativeSshHostKey.Parse("gateway.example", "ecdsa-sha2-nistp256", Convert.ToBase64String(EcdsaKey))!;
        var other = NativeSshHostKey.Parse("gateway.example", "ecdsa-sha2-nistp256", Convert.ToBase64String(MakeEcdsaKey()))!;
        Assert.IsNull(await Task.Run(() => Ask(server, NativeSshAskpassProtocol.Kind.Prompt, HostKeyQuestion("gateway.example", "ECDSA", key.Fingerprint), "")),
            "no observation: refused");
        await Task.Run(() => Ask(server, NativeSshAskpassProtocol.Kind.HostKey, "HOSTNAME", "gateway.example", key.Algorithm, Convert.ToBase64String(key.Blob)));
        foreach (var mismatched in new[]
                 {
                     HostKeyQuestion("gateway.example", "ECDSA", other.Fingerprint),
                     HostKeyQuestion("gateway.example", "ED25519", key.Fingerprint),
                     HostKeyQuestion("elsewhere.example", "ECDSA", key.Fingerprint),
                 })
            Assert.IsNull(await Task.Run(() => Ask(server, NativeSshAskpassProtocol.Kind.Prompt, mismatched, "")), mismatched);
        Assert.AreEqual(0, recorder.Seen.Count, "mismatched questions never reach the user");
    }

    [TestMethod]
    public async Task WrongTokensAndForeignClientsAreIgnored()
    {
        var recorder = new Recorder(_ => "secret"u8.ToArray());
        await using var server = new NativeSshAskpassServer(recorder, pid => pid == Environment.ProcessId);
        var wrong = RandomNumberGenerator.GetBytes(NativeSshAskpassProtocol.TokenBytes);
        Assert.Throws<IOException>(() => Ask(server, wrong, NativeSshAskpassProtocol.Kind.Prompt, "password: ", ""));
        Assert.AreEqual(0, recorder.Seen.Count);

        await using var closed = new NativeSshAskpassServer(recorder, _ => false);
        Assert.Throws<IOException>(() => Ask(closed, NativeSshAskpassProtocol.Kind.Prompt, "password: ", ""));
        Assert.AreEqual(0, recorder.Seen.Count, "clients outside the attempt's job are not answered");

        Assert.AreEqual("secret", Encoding.UTF8.GetString(Ask(server, NativeSshAskpassProtocol.Kind.Prompt, "password: ", "")!));
        Assert.ThrowsExactly<ArgumentException>(() => NativeSshAskpassProtocol.EncodeResponse(NativeSshAskpassProtocol.Status.Answer, "a\nb"u8));
    }

    [TestMethod]
    public void HostKeysAreParsedStructurally()
    {
        var key = NativeSshHostKey.Parse("h", "ecdsa-sha2-nistp256", Convert.ToBase64String(EcdsaKey))!;
        Assert.AreEqual("SHA256:" + Convert.ToBase64String(SHA256.HashData(EcdsaKey)).TrimEnd('='), key.Fingerprint);
        Assert.IsNull(NativeSshHostKey.Parse("h", "ssh-ed25519", Convert.ToBase64String(EcdsaKey)), "type must match the blob");
        Assert.IsNull(NativeSshHostKey.Parse("h", "ecdsa-sha2-nistp256", Convert.ToBase64String([.. EcdsaKey, 0])), "no trailing bytes");
        Assert.IsNull(NativeSshHostKey.Parse("h", "ssh-dss", Convert.ToBase64String(EcdsaKey)), "unsupported types fail closed");
        Assert.IsNull(NativeSshHostKey.Parse("h", "ecdsa-sha2-nistp256", "not base64"));
        Assert.IsNull(NativeSshHostKey.Parse("", "ecdsa-sha2-nistp256", Convert.ToBase64String(EcdsaKey)));
    }
}
