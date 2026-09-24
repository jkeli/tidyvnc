// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Reflection;
using System.Text;
using System.Text.Json;

namespace TidyVNC.Native.Tests;

/// <summary>
/// The shared conformance corpus (tests/conformance, TODO W2.1) through the
/// .NET wrappers, so the Windows app computes exactly what the core runner in
/// tests/unit and the macOS Swift implementations compute.
/// </summary>
[TestClass]
public sealed class ConformanceTests
{
    private static string Corpus(string name) => Path.Combine(
        typeof(ConformanceTests).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().First(a => a.Key == "TidyVncConformance").Value!, name);

    private static string Text(JsonElement entry, string name, string fallback = "")
    {
        if (!entry.TryGetProperty(name, out var value)) return fallback;
        if (value.ValueKind == JsonValueKind.Object)
        {
            var unit = value.GetProperty("repeat").GetString()!;
            return new StringBuilder().Insert(0, unit, value.GetProperty("count").GetInt32()).ToString();
        }
        return value.GetString()!;
    }

    [TestMethod]
    public void IdentityDigestCorpus()
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(Corpus("identity-digest.json")));
        Assert.AreEqual("IdentityDigest", document.RootElement.GetProperty("module").GetString());
        var results = new Dictionary<string, string>();
        int expected = 0, relations = 0, errors = 0;
        foreach (var entry in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            var name = entry.GetProperty("name").GetString()!;
            var kind = entry.GetProperty("kind").GetString()!;
            var securityType = entry.TryGetProperty("securityType", out var type) ? type.GetUInt32() : 0u;
            var shape = Text(entry, "shape") == "usernamePassword" ? NativeCredentialShape.UsernamePassword : NativeCredentialShape.PasswordOnly;
            var allowUnix = !entry.TryGetProperty("allowUnixSockets", out var unix) || unix.GetBoolean();
            var port = entry.TryGetProperty("port", out var number) ? number.GetUInt32() : 22u;
            Func<string> compute = kind switch
            {
                "credential" => () => NativeIdentity.CredentialAccount(Text(entry, "endpoint"), Text(entry, "route"), securityType, shape,
                                                                       Text(entry, "username"), allowUnix),
                "trustCertificate" => () => NativeIdentity.TrustScope(Text(entry, "endpoint"), Text(entry, "route"), NativeTrustKind.Certificate),
                "trustHostKey" => () => NativeIdentity.TrustScope(Text(entry, "endpoint"), Text(entry, "route"), NativeTrustKind.HostKey),
                "sshRoute" => () => NativeIdentity.SshRoute(Text(entry, "gateway")),
                "sshIntent" => () => NativeIdentity.SshIntent(Text(entry, "gateway")),
                "sshResolved" => () => NativeIdentity.SshResolved(Text(entry, "host"), Text(entry, "username"), port, Text(entry, "alias")),
                _ => throw new AssertFailedException($"{name}: unknown kind {kind}"),
            };
            if (entry.TryGetProperty("error", out var error))
            {
                var failure = Assert.ThrowsExactly<NativeIdentityFailure>(() => compute(), name);
                Assert.AreEqual(error.GetString(), JsonNamingPolicy.CamelCase.ConvertName(failure.Reason.ToString()), name);
                errors++;
                continue;
            }
            var value = compute();
            results.Add(name, value);
            if (entry.TryGetProperty("expect", out var want)) { Assert.AreEqual(want.GetString(), value, name); expected++; }
            if (entry.TryGetProperty("sameAs", out var same)) { Assert.AreEqual(results[same.GetString()!], value, name); relations++; }
            if (entry.TryGetProperty("differsFrom", out var other)) { Assert.AreNotEqual(results[other.GetString()!], value, name); relations++; }
        }
        Assert.IsGreaterThanOrEqualTo(15, expected);
        Assert.IsGreaterThanOrEqualTo(20, relations);
        Assert.IsGreaterThanOrEqualTo(15, errors);
    }

    /// <summary>
    /// A certificate made by .NET: the core's SPKI equals .NET's export, and
    /// legacy g0 and SHA-256 c0 records match (TODO W2.5, W4.3).
    /// </summary>
    [TestMethod]
    public void LegacyKnownHostsThroughTheBridge()
    {
        using var rsa = System.Security.Cryptography.RSA.Create(2048);
        var request = new System.Security.Cryptography.X509Certificates.CertificateRequest(
            "CN=fixture.invalid", rsa, System.Security.Cryptography.HashAlgorithmName.SHA256, System.Security.Cryptography.RSASignaturePadding.Pkcs1);
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        using var key = new NativeCertificateKey(certificate.RawData);
        CollectionAssert.AreEqual(certificate.PublicKey.ExportSubjectPublicKeyInfo(), key.Spki);

        var spki = Convert.ToBase64String(key.Spki);
        var digest = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(key.Spki));
        var fingerprint = string.Join(':', System.Security.Cryptography.SHA256.HashData(key.Spki).Select(b => b.ToString("X2", System.Globalization.CultureInfo.InvariantCulture)));
        var now = DateTimeOffset.FromUnixTimeSeconds(100);

        var stored = NativeKnownHosts.Lookup(Encoding.UTF8.GetBytes($"|g0|fixture.invalid|*|0|{spki}\n"), "fixture.invalid", key, now);
        Assert.AreEqual(NativeKnownHostsState.Match, stored.State);
        Assert.AreEqual(fingerprint, stored.ReceivedFingerprint);
        Assert.AreEqual(new NativeKnownHostsIdentity(false, 0, fingerprint), stored.Expected[0]);

        var committed = NativeKnownHosts.Lookup(Encoding.UTF8.GetBytes($"|c0|*suffix|*|0|6|{digest}\n"), "elsewhere.invalid", key, now);
        Assert.AreEqual(NativeKnownHostsState.Match, committed.State);
        Assert.IsTrue(committed.IncludesWildcardHost);
        Assert.AreEqual(new NativeKnownHostsIdentity(true, 6, digest), committed.Expected[0]);

        Assert.AreEqual(NativeKnownHostsState.Missing, NativeKnownHosts.Lookup([], "fixture.invalid", key, now).State);
        Assert.AreEqual(NativeKnownHostsState.Changed,
            NativeKnownHosts.Lookup(Encoding.UTF8.GetBytes("|g0|fixture.invalid|*|0|AQID\n"), "fixture.invalid", key, now).State);
        var failure = Assert.ThrowsExactly<NativeKnownHostsFailure>(() =>
            NativeKnownHosts.Lookup(Encoding.UTF8.GetBytes("# ok\n|g9|x|*|0|AQID\n"), "fixture.invalid", key, now));
        Assert.AreEqual(NativeKnownHostsFailure.Problem.UnsupportedFormat, failure.Reason);
        Assert.AreEqual(2u, failure.Line);
    }
}
