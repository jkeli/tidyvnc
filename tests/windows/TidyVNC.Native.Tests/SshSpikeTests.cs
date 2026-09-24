// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using System.Reflection;
using System.Text;
using TidyVNC.Testing;

namespace TidyVNC.Native.Tests;

/// <summary>
/// The D17 spike (plans/native-ui-winui TODO W0.11): what Windows OpenSSH
/// on this machine does with -W, -L, SSH_ASKPASS, host-key prompts and -G,
/// against the in-process SshTestServer. Skipped when ssh.exe is absent.
/// </summary>
[TestClass]
public sealed class SshSpikeTests
{
    public TestContext TestContext { get; set; } = null!;

    private static string Ssh => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "OpenSSH", "ssh.exe");

    private string root = "";

    [TestInitialize]
    public void Setup()
    {
        if (!File.Exists(Ssh)) Assert.Inconclusive("Windows OpenSSH client is not installed");
        root = Path.Combine(Path.GetTempPath(), "tidyvnc-ssh-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
    }

    [TestCleanup]
    public void Teardown() { try { Directory.Delete(root, true); } catch (IOException) { } }

    private ProcessStartInfo Start(SshTestServer server, string knownHosts, params string[] extra)
    {
        var config = Path.Combine(root, "config");
        File.WriteAllText(config, "");
        var info = new ProcessStartInfo(Ssh)
        {
            UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true,
        };
        foreach (var argument in new[]
                 {
                     "-F", config, "-p", server.Port.ToString(System.Globalization.CultureInfo.InvariantCulture),
                     "-o", "UserKnownHostsFile=" + knownHosts, "-o", "GlobalKnownHostsFile=NUL", "-o", "IdentitiesOnly=yes",
                     "-o", "IdentityFile=NUL", "-o", "IdentityAgent=none", "-o", "ConnectTimeout=10",
                 }.Concat(extra))
            info.ArgumentList.Add(argument);
        return info;
    }

    private static async Task<byte[]> ReadExactly(Stream stream, int length)
    {
        var buffer = new byte[length];
        await stream.ReadExactlyAsync(buffer).AsTask().WaitAsync(TimeSpan.FromSeconds(20));
        return buffer;
    }

    [TestMethod]
    public async Task StdioForwardingCarriesTheRfbStream()
    {
        await using var server = new SshTestServer();
        await using var peer = new LoopbackPeer();
        var knownHosts = Path.Combine(root, "known_hosts");
        File.WriteAllText(knownHosts, $"[127.0.0.1]:{server.Port} {server.KnownHostsKey}\n");
        var info = Start(server, knownHosts, "-v", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-W", $"127.0.0.1:{peer.Port}", "tester@127.0.0.1");
        using var ssh = Process.Start(info)!;
        var stderr = ssh.StandardError.ReadToEndAsync();
        var output = ssh.StandardOutput.BaseStream;
        var input = ssh.StandardInput.BaseStream;
        string version;
        try { version = Encoding.ASCII.GetString(await ReadExactly(output, 12)); }
        catch (EndOfStreamException) { Assert.Fail("ssh ended: " + await stderr); throw; }
        Assert.AreEqual("RFB 003.008\n", version);
        await input.WriteAsync("RFB 003.008\n"u8.ToArray());
        await input.FlushAsync();
        var security = await ReadExactly(output, 2);
        CollectionAssert.AreEqual(new byte[] { 1, 1 }, security, "the peer offers None");
        Assert.AreEqual(1, server.ForwardedChannels);
        Assert.AreEqual($"127.0.0.1:{peer.Port}", server.Targets.Single());
        ssh.StandardInput.Close();
        Assert.IsTrue(ssh.WaitForExit(10_000));
        TestContext.WriteLine($"exit {ssh.ExitCode}; stderr: {await stderr}");
    }

    private static string Askpass => typeof(SshSpikeTests).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
        .First(a => a.Key == "TidyVncAskpass").Value!;

    private sealed class ScriptedInteraction(string password, bool approveHostKey) : TidyVNC.Native.Tunnel.INativeSshInteraction
    {
        public List<TidyVNC.Native.Tunnel.NativeSshPrompt> Seen { get; } = [];

        public Task<byte[]?> AnswerAsync(TidyVNC.Native.Tunnel.NativeSshPrompt prompt, CancellationToken cancellation)
        {
            lock (Seen) Seen.Add(prompt);
            return Task.FromResult<byte[]?>(prompt.Kind switch
            {
                TidyVNC.Native.Tunnel.NativeSshPromptKind.HostKey => approveHostKey ? [1] : null,
                TidyVNC.Native.Tunnel.NativeSshPromptKind.Secret => Encoding.UTF8.GetBytes(password),
                _ => null,
            });
        }
    }

    [TestMethod]
    public async Task AskpassAnswersPasswordsAndReviewsNewHostKeysInsideTheJob()
    {
        Assert.IsTrue(File.Exists(Askpass), "build apps/windows/TidyVNC.SshAskpass first");
        await using var server = new SshTestServer(password: "gateway secret");
        await using var peer = new LoopbackPeer();
        var knownHosts = Path.Combine(root, "known_hosts");
        var interaction = new ScriptedInteraction("gateway secret", approveHostKey: true);
        TidyVNC.Native.Tunnel.NativeOwnedProcess? ssh = null;
        await using var askpass = new TidyVNC.Native.Tunnel.NativeSshAskpassServer(interaction, pid => ssh?.Contains(pid) == true);
        var config = Path.Combine(root, "config");
        File.WriteAllText(config, "");
        var environment = new Dictionary<string, string>(askpass.Environment)
        {
            ["SystemRoot"] = Environment.GetEnvironmentVariable("SystemRoot")!,
            ["USERPROFILE"] = Environment.GetEnvironmentVariable("USERPROFILE")!,
            // ssh.exe exits 255 without %ProgramData% (its global ssh_config lives there).
            ["ProgramData"] = Environment.GetEnvironmentVariable("ProgramData")!,
            ["SSH_ASKPASS"] = Askpass,
            ["SSH_ASKPASS_REQUIRE"] = "force",
        };
        string[] arguments =
        [
            "-F", config, "-p", server.Port.ToString(System.Globalization.CultureInfo.InvariantCulture),
            "-o", "UserKnownHostsFile=" + knownHosts, "-o", "GlobalKnownHostsFile=NUL", "-o", "StrictHostKeyChecking=ask",
            "-o", $"KnownHostsCommand=\"{Askpass}\" --known-hosts %I %H %t %K",
            "-o", "IdentitiesOnly=yes", "-o", "IdentityFile=NUL", "-o", "IdentityAgent=none", "-o", "PreferredAuthentications=password",
            "-o", "NumberOfPasswordPrompts=1", "-o", "BatchMode=no", "-o", "UpdateHostKeys=no",
            "-W", $"127.0.0.1:{peer.Port}", "tester@127.0.0.1",
        ];
        ssh = TidyVNC.Native.Tunnel.NativeOwnedProcess.Start(Ssh, arguments, environment);
        using (ssh)
        {
            var stderr = new StreamReader(ssh.Error).ReadToEndAsync();
            string version;
            try { version = Encoding.ASCII.GetString(await ReadExactly(ssh.Output, 12)); }
            catch (Exception error) when (error is EndOfStreamException or TimeoutException) { Assert.Fail("ssh ended: " + await stderr); throw; }
            Assert.AreEqual("RFB 003.008\n", version);
            Assert.AreEqual(1, server.Authenticated);
            Assert.AreEqual(0, server.FailedPasswords);
            var kinds = interaction.Seen.Select(p => p.Kind).ToList();
            CollectionAssert.AreEqual(new[] { TidyVNC.Native.Tunnel.NativeSshPromptKind.HostKey, TidyVNC.Native.Tunnel.NativeSshPromptKind.Secret }, kinds);
            var reviewed = interaction.Seen[0].HostKey!;
            Assert.AreEqual("ecdsa-sha2-nistp256", reviewed.Algorithm);
            StringAssert.Contains(File.ReadAllText(knownHosts), server.KnownHostsKey.Split(' ')[1], "OpenSSH saved the approved key");
            TestContext.WriteLine($"prompts: {string.Join(" | ", interaction.Seen.Select(p => p.Kind + ": " + p.Text.ReplaceLineEndings(" ")))}");
            ssh.Kill();
            var code = await ssh.Exited.WaitAsync(TimeSpan.FromSeconds(10));
            TestContext.WriteLine($"exit after kill {code}");
        }
    }

    [TestMethod]
    public async Task ConfigurationCaptureNeedsNoServer()
    {
        var config = Path.Combine(root, "config");
        File.WriteAllText(config, "Host desk-gateway\n  HostName gateway.example\n  User alice\n  Port 2222\n  ProxyCommand evil\n");
        var info = new ProcessStartInfo(Ssh) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        foreach (var argument in new[] { "-G", "-F", config, "desk-gateway" }) info.ArgumentList.Add(argument);
        using var ssh = Process.Start(info)!;
        var output = await ssh.StandardOutput.ReadToEndAsync();
        await ssh.WaitForExitAsync();
        Assert.AreEqual(0, ssh.ExitCode);
        var lines = output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        CollectionAssert.Contains(lines, "hostname gateway.example");
        CollectionAssert.Contains(lines, "user alice");
        CollectionAssert.Contains(lines, "port 2222");
        CollectionAssert.Contains(lines, "proxycommand evil", "the capture sees proxy directives, so the app can refuse them visibly");
        TestContext.WriteLine(string.Join(" | ", lines.Where(l => l.StartsWith("user", StringComparison.Ordinal) || l.StartsWith("identityfile", StringComparison.Ordinal) || l.StartsWith("userknownhostsfile", StringComparison.Ordinal))));
    }
}
