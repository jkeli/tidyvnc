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
    public void CatalogUsesWindowsTerms()
    {
        foreach (var (name, value) in Catalog.Value)
        {
            StringAssert.DoesNotMatch(value, new System.Text.RegularExpressions.Regex(@"\b(Keychain|Finder|macOS|this Mac)\b|[⌘⌥]"), name);
            Assert.IsFalse(value.Contains('%', StringComparison.Ordinal) && System.Text.RegularExpressions.Regex.IsMatch(value, "%[@ud]|%lld"), $"{name} keeps a printf placeholder");
        }
    }
}
