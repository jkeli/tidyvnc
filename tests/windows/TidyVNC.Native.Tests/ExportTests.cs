// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Text;
using TidyVNC.Native.Documents;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Save connection file as (plans/native-ui-winui TODO W5.14, PARITY F05-F07;
/// macOS NativeDocumentExportTests): the core's losses must be acknowledged,
/// a custom TLS priority refuses the export, display IDs become the current
/// monitor numbers, and the file reads back through the shared decoder.
/// </summary>
[TestClass]
public sealed class ExportTests
{
    private static NativeExportSource Source(NativeFullscreenPolicy? fullscreen = null, string priority = "", bool gateway = false) =>
        new("desk.example::5901", Shared: true, ReconnectOnError: true, ClipboardSend: true, ClipboardReceive: false, new NativeEncodingOptions(),
            NativeInputSettings.BuiltIn with { ViewOnly = true }, NativeCursorFallback.Dot, NativeScaling.BuiltIn,
            fullscreen ?? NativeFullscreenPolicy.BuiltIn, new NativeSecuritySelection().Canonical, priority, "", "", IgnoredInput: false, gateway);

    [TestMethod]
    public void ExportsNeedTheirLossesAcknowledged()
    {
        var export = NativeDocumentExport.Create(Source(), []);
        var always = NativeExportLoss.FailureAlerts | NativeExportLoss.RemoteResize | NativeExportLoss.NetworkFamilies | NativeExportLoss.PointerTiming |
                     NativeExportLoss.ClipboardLimit | NativeExportLoss.WindowPlacement;
        Assert.AreEqual(always, export.Losses, "omitted values always need review");
        Assert.AreEqual(NativeExportProblem.ReviewRequired, Assert.ThrowsExactly<NativeExportFailure>(() => export.Data(NativeExportLoss.None)).Problem);
        var text = Encoding.UTF8.GetString(export.Data(export.Losses));
        StringAssert.Contains(text, "ServerName=desk.example::5901");
        StringAssert.Contains(text, "Shared=on");
        StringAssert.Contains(text, "AcceptClipboard=off");
        StringAssert.Contains(text, "ViewOnly=on");
        Assert.IsFalse(text.Contains("Password", StringComparison.OrdinalIgnoreCase), "no secrets");

        Assert.AreEqual(NativeExportLoss.SshGateway, NativeDocumentExport.Create(Source(gateway: true), []).Losses & NativeExportLoss.SshGateway);
        Assert.AreEqual(NativeExportProblem.SecurityPolicy,
            Assert.ThrowsExactly<NativeExportFailure>(() => NativeDocumentExport.Create(Source(priority: "NORMAL"), [])).Problem);
    }

    [TestMethod]
    public void SelectedDisplaysBecomeMonitorNumbers()
    {
        var policy = new NativeFullscreenPolicy(true, NativeFullscreenMode.Selected, ["bbbbbbbbbbbbbbbb"]);
        var export = NativeDocumentExport.Create(Source(policy), ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"]);
        Assert.AreEqual(2, export.MonitorIndices["bbbbbbbbbbbbbbbb"]);
        Assert.AreEqual(NativeExportLoss.DisplayIdentity, export.Losses & NativeExportLoss.DisplayIdentity);
        var text = Encoding.UTF8.GetString(export.Data(export.Losses));
        StringAssert.Contains(text, "FullScreenSelectedMonitors=2");
        StringAssert.Contains(text, "FullScreenMode=Selected");
        Assert.AreEqual(NativeExportProblem.DisplayMapping,
            Assert.ThrowsExactly<NativeExportFailure>(() => NativeDocumentExport.Create(Source(policy), ["aaaaaaaaaaaaaaaa"])).Problem,
            "a disconnected display has no monitor number");

        // The user numbers a disconnected display; the connection's selection is unchanged.
        var mapping = new NativeExportMapping(policy, ["aaaaaaaaaaaaaaaa"]);
        Assert.AreEqual(0, mapping.Suggested.Count);
        Assert.IsNull(mapping.Indices(new Dictionary<string, string> { ["bbbbbbbbbbbbbbbb"] = "0" }));
        Assert.IsNull(mapping.Indices(new Dictionary<string, string> { ["bbbbbbbbbbbbbbbb"] = "+3" }));
        Assert.IsNull(mapping.Indices(new Dictionary<string, string>()));
        var chosen = mapping.Indices(new Dictionary<string, string> { ["bbbbbbbbbbbbbbbb"] = " 3 " })!;
        var mapped = NativeDocumentExport.Create(Source(policy), ["aaaaaaaaaaaaaaaa"], chosen);
        StringAssert.Contains(Encoding.UTF8.GetString(mapped.Data(mapped.Losses)), "FullScreenSelectedMonitors=3");

        var two = new NativeFullscreenPolicy(true, NativeFullscreenMode.Selected, ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"]);
        var both = new NativeExportMapping(two, ["bbbbbbbbbbbbbbbb", "aaaaaaaaaaaaaaaa"]);
        Assert.AreEqual(2, both.Suggested["aaaaaaaaaaaaaaaa"]);
        Assert.IsNull(both.Indices(new Dictionary<string, string> { ["aaaaaaaaaaaaaaaa"] = "1", ["bbbbbbbbbbbbbbbb"] = "1" }), "numbers are distinct");
        Assert.AreEqual(NativeExportProblem.DisplayMapping, Assert.ThrowsExactly<NativeExportFailure>(() =>
            NativeDocumentExport.Create(Source(two), [], new Dictionary<string, int> { ["aaaaaaaaaaaaaaaa"] = 1, ["bbbbbbbbbbbbbbbb"] = 1 })).Problem);
    }
}
