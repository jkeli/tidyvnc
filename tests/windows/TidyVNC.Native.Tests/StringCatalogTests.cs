// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Globalization;
using System.Reflection;
using System.Xml.Linq;

namespace TidyVNC.Native.Tests;

/// <summary>
/// The Windows string catalog (DECISIONS.md D20, TODO W5.18): every key a
/// model can produce, including computed ones the source audit
/// (apps/windows/strings.py) cannot see, exists in the generated .resw, and
/// its arguments fit the format string.
/// </summary>
[TestClass]
public sealed class StringCatalogTests
{
    private static readonly Lazy<Dictionary<string, string>> Catalog = new(() =>
    {
        var path = typeof(StringCatalogTests).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().First(a => a.Key == "TidyVncStrings").Value!;
        return XDocument.Load(path).Root!.Elements("data").ToDictionary(e => (string)e.Attribute("name")!, e => (string)e.Element("value")!);
    });

    /// <summary>Resolves a text the way the app does, failing on a missing key or a format mismatch.</summary>
    internal static string Resolve(NativeText text)
    {
        Assert.IsTrue(Catalog.Value.TryGetValue(text.Key.Replace('.', '_'), out var format), $"missing string {text.Key}");
        var arguments = text.Arguments.Select(a => a is NativeText nested ? Resolve(nested) : a).ToArray();
        var formatted = string.Format(CultureInfo.InvariantCulture, format, arguments);
        for (var i = arguments.Length; i < 10; i++)
            Assert.IsFalse(format.Contains("{" + i + "}", StringComparison.Ordinal), $"{text.Key} expects more than {arguments.Length} arguments");
        return formatted;
    }

    [TestMethod]
    public void ConnectionAndPresentationIssuesHaveStrings()
    {
        foreach (var issue in Enum.GetValues<NativeConnectionIssue>())
        {
            Assert.IsFalse(string.IsNullOrWhiteSpace(Resolve(issue.Title())), issue.ToString());
            Assert.IsFalse(string.IsNullOrWhiteSpace(Resolve(issue.Message())), issue.ToString());
        }
        foreach (var issue in Enum.GetValues<NativePresentationIssue>()) Resolve(issue.Message());
        Assert.AreEqual("Connection refused", Resolve(NativeConnectionIssue.Refused.Title()), "Windows sentence case");
        StringAssert.DoesNotMatch(Resolve(NativeConnectionIssue.NetworkPolicy.Message()), new System.Text.RegularExpressions.Regex("System Settings|Local Network"));
    }

    [TestMethod]
    public void SetupFailuresAndNoticesHaveStrings()
    {
        foreach (var problem in Enum.GetValues<NativeSetupProblem>())
            foreach (var layer in new[] { NativeOptionSource.CommandLine, NativeOptionSource.Document })
                foreach (var position in new uint[] { 0, 7 })
                {
                    var text = Resolve(new NativeSetupFailure(problem, layer, position).Text);
                    if (position != 0) StringAssert.Contains(text, "7");
                }
        Assert.AreEqual("Line 3: Audio — Unavailable on Windows",
            Resolve(new NativeDocumentNotice(NativeDocumentNotice.NoticeKind.PlatformOnly, 3, "Audio").Text));
        Resolve(new NativeDocumentNotice(NativeDocumentNotice.NoticeKind.UnknownField, 3, "Future").Text);
    }

    [TestMethod]
    public void WindowTextsHaveStrings()
    {
        foreach (var issue in Enum.GetValues<NativeEndpointIssue>()) if (NativeTexts.Endpoint(issue) is { } text) Resolve(text);
        foreach (var error in Enum.GetValues<Storage.NativeStorageError>())
        {
            Resolve(NativeTexts.Preferences(error)); Resolve(NativeTexts.Profile(error)); Resolve(NativeTexts.History(error));
        }
        foreach (var state in Enum.GetValues<NativeSessionState>()) Resolve(NativeTexts.Status(state));
        foreach (var kind in Enum.GetValues<Credentials.NativeCredentialNoticeKind>())
            foreach (var store in Enum.GetValues<Credentials.NativeCredentialError>())
                Resolve(NativeTexts.Credential(new Credentials.NativeCredentialNotice(kind, store)));
        foreach (var file in Enum.GetValues<Credentials.NativePasswordFileError>())
            Resolve(NativeTexts.Credential(new Credentials.NativeCredentialNotice(Credentials.NativeCredentialNoticeKind.LaunchFailure, null, file)));
        foreach (var error in Enum.GetValues<Tunnel.NativeSshTunnelError>()) Resolve(Tunnel.NativeTunnelTexts.Text(error));
        Resolve(Tunnel.NativeTunnelTexts.InvalidRequest); Resolve(Tunnel.NativeTunnelTexts.UnsupportedTarget);
        foreach (var error in Enum.GetValues<Documents.NativeDocumentOpenError>()) Resolve(NativeDocumentTexts.Text(error));
        foreach (var problem in Enum.GetValues<NativeDocumentProblem>())
            foreach (var line in new uint[] { 0, 3 }) Resolve(NativeDocumentTexts.Text(new NativeDocumentFailure(problem, line)));
        Resolve(NativeDocumentTexts.TopologyChanged);
        foreach (var notice in Enum.GetValues<Clipboard.NativeClipboardNotice>()) Resolve(NativeTexts.Clipboard(notice));
        foreach (var reason in Enum.GetValues<NativeCertificateReason>().Where(r => r != NativeCertificateReason.None)) Resolve(NativeTrustTexts.Reason(reason));
        foreach (var error in Enum.GetValues<Trust.NativeLegacyTrustError>()) Resolve(NativeTrustTexts.Issue(error, null)!);
        foreach (var error in Enum.GetValues<Storage.NativeStorageError>()) Resolve(NativeTrustTexts.Storage(error));
        foreach (var notice in Enum.GetValues<Trust.NativeTrustNotice>()) Resolve(NativeTrustTexts.Notice(notice));
        Resolve(NativeTrustTexts.Expected(new NativeKnownHostsIdentity(true, 2, "ab"))); Resolve(NativeTrustTexts.Expected(new NativeKnownHostsIdentity(false, 0, "ab")));
        Assert.AreEqual("Password saved on this PC.", Resolve(NativeTexts.Credential(new Credentials.NativeCredentialNotice(Credentials.NativeCredentialNoticeKind.Saved))));
    }

    [TestMethod]
    public void CatalogUsesWindowsTerms()
    {
        foreach (var (name, value) in Catalog.Value)
        {
            StringAssert.DoesNotMatch(value, new System.Text.RegularExpressions.Regex(@"\b(Keychain|Finder|macOS|this Mac)\b|[⌘⌥]"), name);
            Assert.IsFalse(value.Contains('%', StringComparison.Ordinal) && System.Text.RegularExpressions.Regex.IsMatch(value, "%[@ud]|%lld"), $"{name} keeps a printf placeholder");
        }
    }
}
