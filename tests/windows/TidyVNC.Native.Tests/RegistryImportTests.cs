// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.Win32;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Registry import sources (plans/native-ui-winui TODO W4.5, SERVICES.md
/// section 9) against disposable keys under HKCU\Software\TidyVNC-test-*,
/// written here the way vncviewer/parameters.cxx writes them. The real
/// TidyVNC and TigerVNC keys are never touched.
/// </summary>
[TestClass]
public sealed class RegistryImportTests
{
    private string path = "";
    private RegistryKey root = null!;

    [TestInitialize]
    public void Setup()
    {
        path = @"Software\TidyVNC-test-" + Guid.NewGuid().ToString("N");
        root = Registry.CurrentUser.CreateSubKey(path, writable: true);
    }

    [TestCleanup]
    public void Teardown()
    {
        root.Dispose();
        Registry.CurrentUser.DeleteSubKeyTree(path, throwOnMissingSubKey: false);
    }

    private RegistryKey Viewer(string vendor) => root.CreateSubKey($@"Software\{vendor}\vncviewer", writable: true);

    [TestMethod]
    public void StoredStringsDecodeLikeTheFltkViewer()
    {
        Assert.AreEqual(@"C:\certs\ca.pem", NativeRegistryImport.DecodeStoredString(@"C:\\certs\\ca.pem"));
        Assert.AreEqual("a\nb\rc", NativeRegistryImport.DecodeStoredString(@"a\nb\rc"));
        Assert.AreEqual("", NativeRegistryImport.DecodeStoredString(""));
        Assert.AreEqual(new string('x', 255), NativeRegistryImport.DecodeStoredString(new string('x', 255)));
        Assert.IsNull(NativeRegistryImport.DecodeStoredString(new string('x', 256)));
        Assert.IsNull(NativeRegistryImport.DecodeStoredString(@"C:\certs"), "unknown escape");
        Assert.IsNull(NativeRegistryImport.DecodeStoredString(@"trailing\"));
        Assert.IsNull(NativeRegistryImport.DecodeStoredString("nul\0"));
    }

    [TestMethod]
    public void BothSourcesAreDiscoveredIndependently()
    {
        Assert.AreEqual(0, NativeRegistryImport.Available(root).Count);
        Assert.IsNull(NativeRegistryImport.Defaults(NativeRegistrySource.TidyVnc, root));
        Assert.IsNull(NativeRegistryImport.History(NativeRegistrySource.TigerVnc, root));
        using (var tiger = Viewer("TigerVNC")) tiger.SetValue("Shared", 1, RegistryValueKind.DWord);
        using (var tidy = Viewer("TidyVNC"))
        using (var history = tidy.CreateSubKey("history"))
            history.SetValue("0", "desk.example::5901", RegistryValueKind.String);
        var sources = NativeRegistryImport.Available(root);
        CollectionAssert.AreEqual(new[]
        {
            new NativeRegistryImportSource(NativeRegistrySource.TidyVnc, false, true),
            new NativeRegistryImportSource(NativeRegistrySource.TigerVnc, true, false),
        }, sources.ToArray());
    }

    [TestMethod]
    public void DefaultsGoThroughTheCoreProjection()
    {
        using (var key = Viewer("TigerVNC"))
        {
            key.SetValue("Shared", 1, RegistryValueKind.DWord);
            key.SetValue("QualityLevel", 7, RegistryValueKind.DWord);
            key.SetValue("PreferredEncoding", "ZRLE", RegistryValueKind.String);
            key.SetValue("PasswordFile", @"C:\\secret\\passwd", RegistryValueKind.String);
            key.SetValue("X509CA", @"C:\\certs\\ca.pem", RegistryValueKind.String);
            key.SetValue("SecurityTypes", "None", RegistryValueKind.String);
            key.SetValue("Future", "1", RegistryValueKind.String);
            key.SetValue("Binary", new byte[] { 1, 2 }, RegistryValueKind.Binary);
            key.SetValue("BadEscape", @"C:\certs", RegistryValueKind.String);
        }
        var defaults = NativeRegistryImport.Defaults(NativeRegistrySource.TigerVnc, root)!;
        var imported = defaults.Projection.Assignments.ToDictionary(a => a.Name, a => a.Value);
        Assert.AreEqual("on", imported["Shared"], "canonical boolean spelling");
        Assert.AreEqual("7", imported["QualityLevel"]);
        Assert.AreEqual("ZRLE", imported["PreferredEncoding"]);
        foreach (var never in new[] { "PasswordFile", "X509CA", "SecurityTypes", "Future" })
            Assert.IsFalse(imported.ContainsKey(never), never);
        var notices = defaults.Projection.Notices.ToDictionary(n => n.Name, n => n.Kind);
        Assert.AreEqual(NativeImportNoticeKind.Excluded, notices["PasswordFile"]);
        Assert.AreEqual(NativeImportNoticeKind.Unknown, notices["Future"]);
        CollectionAssert.AreEquivalent(new[] { "Binary", "BadEscape" }, defaults.SkippedValues.ToArray());
    }

    [TestMethod]
    public void HistoryIsReadInIndexOrderUntilTheFirstGap()
    {
        using (var key = Viewer("TidyVNC"))
        using (var history = key.CreateSubKey("history"))
        {
            history.SetValue("0", "newest.example", RegistryValueKind.String);
            history.SetValue("1", "older.example::5902", RegistryValueKind.String);
            history.SetValue("2", "newest.example", RegistryValueKind.String);
            history.SetValue("4", "after-a-gap.example", RegistryValueKind.String);
        }
        var projection = NativeRegistryImport.History(NativeRegistrySource.TidyVnc, root)!;
        CollectionAssert.AreEqual(new[] { "newest.example", "older.example::5902" }, projection.Endpoints.ToArray());
        Assert.AreEqual(1u, projection.Duplicates);
        Assert.IsTrue(projection.RequiresOmissionReview);

        using (var key = Viewer("TidyVNC"))
        using (var history = key.CreateSubKey("history"))
            history.SetValue("1", 5, RegistryValueKind.DWord);
        var failure = Assert.ThrowsExactly<NativeImportFailure>(() => NativeRegistryImport.History(NativeRegistrySource.TidyVnc, root));
        Assert.AreEqual(2u, failure.Line);
    }

    [TestMethod]
    public void ReadingNeverWrites()
    {
        using (var key = Viewer("TigerVNC")) key.SetValue("Shared", 0, RegistryValueKind.DWord);
        using var probe = root.OpenSubKey(@"Software\TigerVNC\vncviewer")!;
        var names = probe.GetValueNames();
        NativeRegistryImport.Defaults(NativeRegistrySource.TigerVnc, root);
        NativeRegistryImport.History(NativeRegistrySource.TigerVnc, root);
        CollectionAssert.AreEqual(names, probe.GetValueNames());
        Assert.IsNull(probe.OpenSubKey("history"), "absent keys are not created");
    }
}
