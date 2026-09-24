// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.Win32;
using TidyVNC.Native.Credentials;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Test isolation (plans/native-ui-winui TODO W4.12, TESTING.md section 2):
/// in Debug builds TIDYVNC_STATE_ROOT moves the stores, the Credential
/// Manager prefix, the registry import root and the log file together, so
/// app-level automation never touches real user state.
/// </summary>
[TestClass]
[DoNotParallelize]
public sealed class IsolationTests
{
    private string? previous;

    [TestInitialize]
    public void Save() => previous = Environment.GetEnvironmentVariable(NativeStateRoot.OverrideVariable);

    [TestCleanup]
    public void Restore() => Environment.SetEnvironmentVariable(NativeStateRoot.OverrideVariable, previous);

    [TestMethod]
    public void TheStateRootMovesEveryIsolatedResource()
    {
        Environment.SetEnvironmentVariable(NativeStateRoot.OverrideVariable, null);
        Assert.IsFalse(NativeStateRoot.IsIsolated);
        Assert.AreEqual("TidyVNC/credentials.v1/", NativeStateRoot.CredentialPrefix);
        Assert.IsNull(NativeStateRoot.LogFile);
        using (var root = NativeStateRoot.ImportRoot()) Assert.AreEqual(Registry.CurrentUser.Name, root!.Name);

        var one = Path.Combine(Path.GetTempPath(), "tidyvnc-root-" + Guid.NewGuid().ToString("N"));
        var two = Path.Combine(Path.GetTempPath(), "tidyvnc-root-" + Guid.NewGuid().ToString("N"));
        Environment.SetEnvironmentVariable(NativeStateRoot.OverrideVariable, one);
        Assert.IsTrue(NativeStateRoot.IsIsolated);
        var run = NativeStateRoot.RunId!;
        Assert.AreEqual(12, run.Length);
        Assert.AreEqual(one, NativeStateRoot.Directory);
        Assert.AreEqual($"TidyVNC-test-{run}/credentials.v1/", NativeStateRoot.CredentialPrefix);
        Assert.AreEqual(Path.Combine(one, "vncviewer.log"), NativeStateRoot.LogFile);
        Environment.SetEnvironmentVariable(NativeStateRoot.OverrideVariable, one.ToUpperInvariant());
        Assert.AreEqual(run, NativeStateRoot.RunId, "the same root (case-insensitively) is the same run");
        Environment.SetEnvironmentVariable(NativeStateRoot.OverrideVariable, two);
        Assert.AreNotEqual(run, NativeStateRoot.RunId, "different roots never share resources");
    }

    [TestMethod]
    public void IsolatedCredentialsAndImportsUseTheirOwnPlaces()
    {
        var root = Path.Combine(Path.GetTempPath(), "tidyvnc-root-" + Guid.NewGuid().ToString("N"));
        Environment.SetEnvironmentVariable(NativeStateRoot.OverrideVariable, root);
        var run = NativeStateRoot.RunId!;

        // Credentials: the default backing writes under the isolated prefix only.
        var backing = new NativeCredentialManagerBacking();
        var key = NativeCredentialKey.Create(Guid.NewGuid().ToString("N") + ".example", "", 2, false);
        try
        {
            using (var secret = NativeCredentialSecret.Consume("isolated"u8.ToArray())) backing.Save(key, secret, NativeCredentialSaveMode.Create);
            Assert.AreEqual(1, new NativeCredentialManagerBacking($"TidyVNC-test-{run}/credentials.v1/").List(10).Entries.Count);
            Assert.IsFalse(new NativeCredentialManagerBacking("TidyVNC/credentials.v1/").List(256).Entries.Any(e => e.Key.Equals(key)),
                "nothing reaches the real prefix");
        }
        finally
        {
            try { backing.Delete(key); } catch (NativeCredentialException) { }
        }

        // Imports: without a test key there are no sources; with one, it is what is read.
        Assert.IsNull(NativeStateRoot.ImportRoot());
        Assert.AreEqual(0, NativeRegistryImport.Available().Count);
        var path = $@"Software\TidyVNC-Test\{run}";
        try
        {
            using (var viewer = Registry.CurrentUser.CreateSubKey(path + @"\Software\TigerVNC\vncviewer", writable: true))
                viewer.SetValue("Shared", 1, RegistryValueKind.DWord);
            var sources = NativeRegistryImport.Available();
            Assert.AreEqual(NativeRegistrySource.TigerVnc, sources.Single().Source);
            Assert.AreEqual("on", NativeRegistryImport.Defaults(NativeRegistrySource.TigerVnc)!.Projection.Assignments.Single(a => a.Name == "Shared").Value);
        }
        finally
        {
            Registry.CurrentUser.DeleteSubKeyTree(path, throwOnMissingSubKey: false);
        }
    }
}
