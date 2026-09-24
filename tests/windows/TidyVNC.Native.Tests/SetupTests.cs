// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Text;
using TidyVNC.Native.Desktop;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Session setup (plans/native-ui-winui TODO W5.1, PLAN.md section 6): app
/// defaults, profile, command line and connection file through the core
/// resolver, ported from the macOS NativeDocumentResolutionTests and
/// NativeInvocationResolutionTests.
/// </summary>
[TestClass]
public sealed class SetupTests
{
    private const string Directory = @"C:\fixture";

    private static NativeConnectionDocument Document(string body) =>
        new(Encoding.UTF8.GetBytes("TidyVNC Configuration file Version 1.0\n" + body));

    private static NativeDocumentLayer File(string body, string directory = Directory) =>
        NativeDocumentLayer.Create(Document(body), directory);

    private static NativeInvocationLayer CommandLine(params string[] arguments) =>
        new(NativeInvocation.Parse(arguments), "fixture.invalid", @"C:\launch");

    private static NativeSettings Settings(params (string Name, string Value)[] values) =>
        NativeSettings.Create(values.Select(v => KeyValuePair.Create(v.Name, v.Value)));

    private static NativeSetupFailure Failure(Action action)
    {
        var failure = Assert.ThrowsExactly<NativeSetupFailure>(action);
        Assert.IsFalse(failure.Message.Contains("private", StringComparison.Ordinal), "redacted");
        return failure;
    }

    private static void Expect(NativeSetupProblem problem, NativeOptionSource layer, uint position, Action action)
    {
        var failure = Failure(action);
        Assert.AreEqual((problem, layer, position), (failure.Problem, failure.Layer, failure.Position));
    }

    [TestMethod]
    public void AFileOverlaysEveryUnderstoodField()
    {
        var profile = new NativeConnectionProfile(Guid.NewGuid(), "Fixture", "profile.invalid",
            Settings(("FullColor", "off"), ("RemoteResize", "off"), ("DesktopSize", "800x600"), ("Shared", "off")), null, null);
        var file = File("""
            ServerName=private-fixture.invalid:2
            Shared=yes
            ReconnectOnError=no
            AcceptClipboard=off
            SendClipboard=on
            QualityLevel=0x3
            ScalingFactor=125%
            ScalingQuality=AREA
            DesktopPixelUnits=device
            ViewOnly=1
            EmulateMiddleButton=TRUE
            ShortcutModifiers= Cmd, Ctrl, Option,Win
            FullscreenSystemKeys=false
            AlwaysCursor=on
            CursorType=System
            FullScreen=on
            FullScreenMode=Selected
            FullScreenSelectedMonitors=2,1,2
            SecurityTypes=None
            X509CA=relative/../ca.pem
            X509CRL=
            """);
        var setup = NativeSessionSetup.Resolve(null, profile, CommandLine("-QualityLevel=9"), file, new(["left", "right"], ["left", "right"]));
        var config = setup.Configuration();
        Assert.AreEqual("private-fixture.invalid:2", setup.Endpoint);
        Assert.AreEqual(0, setup.Notices.Count);
        Assert.IsTrue(config.Shared && !config.ReconnectOnError);
        Assert.AreEqual((NativeOptionSource.Document, NativeOptionSource.Document), (config.SharedSource, config.ReconnectSource));
        Assert.IsTrue(!config.ClipboardReceive && config.ClipboardSend);
        var quality = config.Encoding!.Value(NativeEncodingOption.Quality);
        var color = config.Encoding.Value(NativeEncodingOption.FullColor);
        Assert.AreEqual(("3", NativeOptionSource.Document), (quality.Value, quality.Source), "explicit file wins over the command line");
        Assert.AreEqual(("off", NativeOptionSource.Profile), (color.Value, color.Source), "absent file field inherits");
        Assert.AreEqual(("125", NativeScalingFilter.Area, true), (config.Scaling!.Canonical, config.Scaling.Filter, config.Scaling.DevicePixels));
        Assert.IsTrue(config.Input.ViewOnly && config.Input.EmulateMiddle && !config.Input.FullscreenSystemKeys);
        Assert.AreEqual(NativeShortcutModifiers.Control | NativeShortcutModifiers.Option | NativeShortcutModifiers.Command, config.Input.ShortcutModifiers);
        Assert.AreEqual(NativeCursorFallback.System, config.Input.CursorFallback);
        Assert.AreEqual(NativeOptionSource.Document, config.InputSources[NativeInputOption.ViewOnly]);
        Assert.AreEqual(NativeOptionSource.Document, config.ScalingSources[NativeScalingOption.Scaling]);
        Assert.IsTrue(config.FullscreenPolicy.StartsFullscreen);
        Assert.AreEqual(NativeFullscreenMode.Selected, config.FullscreenPolicy.Mode);
        CollectionAssert.AreEqual(new[] { "left", "right" }, config.FullscreenPolicy.SelectedDisplays.ToArray(), "legacy ID mapping, deduplicated");
        CollectionAssert.AreEqual(new[] { 1, 2 }, setup.MonitorNumbers.ToArray());
        Assert.IsFalse(setup.ExplicitMonitorMapping);
        CollectionAssert.AreEqual(new uint[] { 1 }, config.SecurityTypes!.ToArray());
        Assert.AreEqual(NativeOptionSource.Document, config.SecuritySource);
        Assert.AreEqual(@"C:\fixture\relative/../ca.pem", config.CaFile, "relative path joins the file's folder and keeps its components");
        Assert.AreEqual("", config.CrlFile);
        Assert.AreEqual(new NativeRemoteResizePolicy(false, "800x600"), config.ResizePolicy, "unrepresented settings inherit");
        Assert.AreEqual(NativeOptionSource.Profile, config.ResizeSources[NativeResizeOption.InitialSize]);
    }

    [TestMethod]
    public void IgnoredFieldsNeedReviewAndInvalidValuesFail()
    {
        var reviewed = NativeSessionSetup.Resolve(null, document: File("Future=\\q\nAudio=\\q\nFullColour=off\nRemoteResize=off\nShared=on\n"));
        CollectionAssert.AreEqual(new uint[] { 2, 3, 4, 5 }, reviewed.Notices.Select(n => n.Line).ToArray(), "every ignored field, undecoded");
        Assert.AreEqual(NativeDocumentNotice.NoticeKind.PlatformOnly, reviewed.Notices[1].Kind);
        Expect(NativeSetupProblem.ReviewRequired, NativeOptionSource.Document, 0, () => reviewed.Configuration());
        Expect(NativeSetupProblem.ReviewRequired, NativeOptionSource.Document, 0, () => reviewed.Configuration(new HashSet<uint> { 2, 3, 4 }));
        var accepted = reviewed.Configuration(new HashSet<uint> { 2, 3, 4, 5 });
        Assert.IsTrue(accepted.Shared && accepted.ResizePolicy.Enabled);

        void Syntax(NativeDocumentProblem problem, uint line, string body)
        {
            var failure = Assert.ThrowsExactly<NativeDocumentFailure>(() => File(body));
            Assert.AreEqual((problem, line), (failure.Problem, failure.Line));
        }
        Syntax(NativeDocumentProblem.InvalidValue, 2, "Shared=broken\nShared=on");
        Syntax(NativeDocumentProblem.InvalidEscape, 2, "Shared=\\q\nShared=on");
        Syntax(NativeDocumentProblem.InvalidValue, 2, "ShortcutModifiers=Ctrl,,Alt");
        Expect(NativeSetupProblem.InvalidEndpoint, NativeOptionSource.Document, 2,
            () => NativeSessionSetup.Resolve(null, document: File("ServerName=private-fixture::0")));
        Expect(NativeSetupProblem.RelativePathNeedsBase, NativeOptionSource.Document, 2,
            () => NativeSessionSetup.Resolve(null, document: File("X509CA=private-fixture.pem", directory: "relative")));
        Expect(NativeSetupProblem.RelativePathNeedsBase, NativeOptionSource.Document, 2,
            () => NativeSessionSetup.Resolve(null, document: File(@"X509CA=\\root-relative.pem")));
        var mapping = Failure(() => NativeSessionSetup.Resolve(null, document: File("FullScreenMode=Selected\nFullScreenSelectedMonitors=2"),
                                                             displays: new(["one"], ["one"])));
        Assert.AreEqual((NativeSetupProblem.DisplayMappingRequired, 3u), (mapping.Problem, mapping.Position));
        CollectionAssert.AreEqual(new[] { 2 }, mapping.MonitorNumbers.ToArray());
        Expect(NativeSetupProblem.DisplayMappingRequired, NativeOptionSource.Document, 2,
            () => NativeSessionSetup.Resolve(null, document: File("FullScreenMode=Selected")));
        // Launch-only fields are not file fields: they are listed for review and cannot override the command line.
        var launch = NativeSessionSetup.Resolve(null, commandLine: CommandLine("-AlertOnFatalError=off"), document: File("AlertOnFatalError=on\nShared=on"));
        Assert.AreEqual(NativeDocumentNotice.NoticeKind.UnknownField, launch.Notices.Single().Kind);
        Assert.IsFalse(launch.Configuration(new HashSet<uint> { 2 }).AlertOnFatalError);
        Expect(NativeSetupProblem.InvalidListenPort, NativeOptionSource.Document, 2,
            () => NativeDocumentLayer.Create(Document("ServerName=private.invalid"), Directory, NativeDocumentEndpointUse.ListenPort));
        var listen = NativeSessionSetup.Resolve(null, document: NativeDocumentLayer.Create(Document("ServerName="), Directory, NativeDocumentEndpointUse.ListenPort));
        Assert.AreEqual(5500u, listen.ListenPort, "an empty listen ServerName is the default port");
    }

    [TestMethod]
    public void MappingUsesExplicitAssignmentsAndChecksThem()
    {
        var file = File("FullScreenMode=Selected\nFullScreenSelectedMonitors=99");
        var displays = new NativeSetupDisplays(["one"], ["one", "two"]);
        var failure = Failure(() => NativeSessionSetup.Resolve(null, document: file, displays: displays));
        CollectionAssert.AreEqual(new[] { 99 }, failure.MonitorNumbers.ToArray());
        var mapped = NativeSessionSetup.Resolve(null, document: file, displays: displays, mapping: new Dictionary<int, string> { [99] = "two" });
        CollectionAssert.AreEqual(new[] { "two" }, mapped.Configuration().FullscreenPolicy.SelectedDisplays.ToArray());
        Assert.IsTrue(mapped.ExplicitMonitorMapping);
        Assert.AreEqual(NativeOptionSource.Document, mapped.Configuration().FullscreenSources[NativeFullscreenOption.SelectedDisplays]);
        Expect(NativeSetupProblem.DisplayMappingRequired, NativeOptionSource.Document, 3, () => NativeSessionSetup.Resolve(null, document: file,
            displays: displays, mapping: new Dictionary<int, string> { [99] = "gone" }));
        Expect(NativeSetupProblem.DisplayMappingRequired, NativeOptionSource.Document, 3, () => NativeSessionSetup.Resolve(null, document: file,
            displays: displays, mapping: new Dictionary<int, string> { [99] = "one", [1] = "two" }));
        // Stored settings carry stable IDs and never need a mapping.
        var stored = NativeSessionSetup.Resolve(Settings(("FullScreenMode", "Selected")) with { FullscreenDisplays = ["0123abcd"] });
        CollectionAssert.AreEqual(new[] { "0123abcd" }, stored.Configuration().FullscreenPolicy.SelectedDisplays.ToArray());
        Assert.AreEqual(NativeOptionSource.AppDefaults, stored.Configuration().FullscreenSources[NativeFullscreenOption.SelectedDisplays]);
        Assert.AreEqual(0, stored.MonitorNumbers.Count);
    }

    [TestMethod]
    public void DeprecatedFlagsMigrateAfterEveryLayer()
    {
        var setup = NativeSessionSetup.Resolve(null, document: File("DotWhenNoCursor=on\nAlwaysCursor=off\nCursorType=System\nFullScreenAllMonitors=on\nFullScreenMode=Selected"));
        var config = setup.Configuration();
        Assert.AreEqual((NativeCursorFallback.Dot, NativeCursorFallback.Dot), (config.Input.CursorFallback, setup.InactiveCursor), "deprecated cursor wins after later fields");
        Assert.AreEqual(NativeFullscreenMode.All, config.FullscreenPolicy.Mode, "deprecated all displays wins after the modern mode");
        Assert.AreEqual((2u, 5u), (setup.Resolution["AlwaysCursor"]!.Position, setup.Resolution["FullScreenMode"]!.Position), "migrated provenance");
        var hidden = NativeSessionSetup.Resolve(null, document: File("CursorType=System\nAlwaysCursor=off"));
        Assert.AreEqual((NativeCursorFallback.Hidden, NativeCursorFallback.System), (hidden.Configuration().Input.CursorFallback, hidden.InactiveCursor), "inactive shape kept");
        var off = NativeSessionSetup.Resolve(null, document: File("DotWhenNoCursor=on\nDotWhenNoCursor=off\nAlwaysCursor=off\nFullScreenAllMonitors=on\nFullScreenAllMonitors=off\nFullScreenMode=Current"));
        Assert.AreEqual((NativeCursorFallback.Hidden, NativeFullscreenMode.Current), (off.Configuration().Input.CursorFallback, off.Configuration().FullscreenPolicy.Mode));
        var first = NativeSessionSetup.Resolve(null, document: File("FullScreenMode=Selected"), displays: new(["first"], ["first"]));
        CollectionAssert.AreEqual(new[] { "first" }, first.Configuration().FullscreenPolicy.SelectedDisplays.ToArray(), "retained default monitor 1");
        Assert.AreEqual("", NativeSessionSetup.Resolve(null, document: File("ServerName=")).Endpoint, "an empty address clears");
        var absent = NativeSessionSetup.Resolve(null, new NativeConnectionProfile(Guid.NewGuid(), "P", "profile.invalid", NativeSettings.Empty, null, null),
                                                document: File("Shared=on"));
        Assert.AreEqual("", absent.Endpoint, "an explicit file never connects to another layer's host");
    }

    [TestMethod]
    public void CommandLineValuesAreCheckedAndApplied()
    {
        var silent = NativeSessionSetup.Resolve(null, commandLine: CommandLine("-AlertOnFatalError=off"));
        Assert.IsFalse(silent.Configuration().AlertOnFatalError);
        Assert.IsTrue(NativeSessionSetup.Resolve(null, commandLine: CommandLine("-AlertOnFatalError=off", "-AlertOnFatalError")).Configuration().AlertOnFatalError);
        var invalid = Assert.ThrowsExactly<NativeInvocationFailure>(() => CommandLine("-AlertOnFatalError=private", "-AlertOnFatalError=off"));
        Assert.AreEqual((NativeInvocationFailure.Problem.InvalidValue, 1u), (invalid.Reason, invalid.Argument));
        foreach (var arguments in new[] { new[] { "-DesktopSize=0x600", "-DesktopSize=800x600" }, ["-DesktopSize=65536x1"], ["-DesktopSize=800 x600"] })
            Expect(NativeSetupProblem.InvalidValue, NativeOptionSource.CommandLine, 1, () => NativeSessionSetup.Resolve(null, commandLine: CommandLine(arguments)));
        Expect(NativeSetupProblem.InvalidValue, NativeOptionSource.CommandLine, 1, () => NativeSessionSetup.Resolve(null, commandLine: CommandLine("-via=private invalid")));
        Expect(NativeSetupProblem.TunnelListenUnsupported, NativeOptionSource.CommandLine, 1,
            () => NativeSessionSetup.Resolve(null, commandLine: CommandLine("-via=gateway.invalid", "-listen")));
        Expect(NativeSetupProblem.InvalidTunnelTarget, NativeOptionSource.CommandLine, 0,
            () => new NativeInvocationLayer(NativeInvocation.Parse(["-via=gateway.invalid"]), "/tmp/socket", @"C:\launch").Gateway(endpoint: "/tmp/socket"));
        NativeSessionSetup.Resolve(null, commandLine: CommandLine("-Log=*:stderr:30"));
        NativeSessionSetup.Resolve(null, commandLine: CommandLine("-Log=*:file:30"));
        Expect(NativeSetupProblem.UnsupportedOption, NativeOptionSource.CommandLine, 1,
            () => NativeSessionSetup.Resolve(null, commandLine: CommandLine("-Log=*:syslog:30")));
        Expect(NativeSetupProblem.NotLaunch, NativeOptionSource.CommandLine, 0, () => NativeSessionSetup.Resolve(null, commandLine: CommandLine("--help")));
        Expect(NativeSetupProblem.InvalidEndpoint, NativeOptionSource.CommandLine, 0,
            () => NativeSessionSetup.Resolve(null, commandLine: new NativeInvocationLayer(NativeInvocation.Parse([]), "private::0", null)));
        Expect(NativeSetupProblem.RelativePathNeedsBase, NativeOptionSource.CommandLine, 1,
            () => NativeSessionSetup.Resolve(null, commandLine: new NativeInvocationLayer(NativeInvocation.Parse(["-X509CA=ca.pem"]), "", null)));

        var window = NativeSessionSetup.Resolve(null, commandLine: CommandLine("-geometry=800x600+-10+20", "-Maximize")).Configuration();
        Assert.AreEqual((800, -10, true), (window.WindowStartupPolicy.Geometry!.Width, window.WindowStartupPolicy.Geometry.X, window.WindowStartupPolicy.Maximize));
        Assert.AreEqual(NativeOptionSource.CommandLine, window.WindowStartupSources[NativeWindowStartupOption.Maximize]);
        var result = NativeSessionSetup.Resolve(Settings(("Shared", "off"), ("ViewOnly", "off")),
            commandLine: CommandLine("-Shared=on", "-ViewOnly", "-RemoteResize=off", "-DesktopSize= +0800x+600trailing", "-QualityLevel=3",
                                     "-PointerEventInterval=0x10", "-MaxCutText=4096", "-UseIPv6=off"));
        var config = result.Configuration();
        Assert.AreEqual("fixture.invalid", result.Endpoint);
        Assert.IsTrue(config.Shared);
        Assert.AreEqual(NativeOptionSource.CommandLine, config.SharedSource);
        Assert.IsTrue(config.Input.ViewOnly);
        Assert.AreEqual(NativeOptionSource.CommandLine, config.InputSources[NativeInputOption.ViewOnly]);
        Assert.AreEqual(("800x600", false), (config.ResizePolicy.InitialSize, config.ResizePolicy.Enabled), "retained size leniency");
        Assert.AreEqual((16u, 4096u), (config.PointerEventIntervalMilliseconds, config.MaxCutText));
        Assert.IsTrue(config.Ipv4 && !config.Ipv6);
        Assert.AreEqual(NativeOptionSource.CommandLine, config.NetworkSources[NativeNetworkOption.Ipv6]);
        var path = new string('x', 300) + @"\..\ca.pem";
        Assert.AreEqual(@"C:\launch\" + path, NativeSessionSetup.Resolve(null, commandLine: CommandLine("-X509CA=" + path)).Configuration().CaFile);
    }

    [TestMethod]
    public void LayersApplyInPrecedenceWithProvenance()
    {
        var hidden = CommandLine("-AlwaysCursor=off", "-CursorType=System");
        var file = NativeSessionSetup.Resolve(null, commandLine: hidden, document: File("Shared=on"));
        Assert.AreEqual((NativeCursorFallback.System, NativeCursorFallback.Hidden), (file.InactiveCursor, file.Configuration().Input.CursorFallback));
        var migrated = CommandLine("-DotWhenNoCursor=on", "-FullScreenAllMonitors=on", "-Shared=on", "-QualityLevel=9");
        var inherited = NativeSessionSetup.Resolve(null, commandLine: migrated,
            document: File("AlwaysCursor=off\nCursorType=System\nFullScreenMode=Selected\nShared=off\nQualityLevel=2"));
        var effective = inherited.Configuration();
        Assert.AreEqual((NativeCursorFallback.Dot, NativeFullscreenMode.All, 0), (effective.Input.CursorFallback, effective.FullscreenPolicy.Mode, inherited.MonitorNumbers.Count),
            "the command line's deprecated flags still migrate after the file");
        Assert.AreEqual((NativeOptionSource.CommandLine, NativeOptionSource.CommandLine),
            (effective.InputSources[NativeInputOption.CursorFallback], effective.FullscreenSources[NativeFullscreenOption.Mode]));
        Assert.AreEqual((NativeOptionSource.CommandLine, 1u), (inherited.Resolution["CursorType"]!.Source, inherited.Resolution["CursorType"]!.Position),
            "migrated values carry the flag's source and argument, never a file line");
        Assert.IsTrue(!effective.Shared && effective.SharedSource == NativeOptionSource.Document && inherited.Endpoint.Length == 0);
        var quality = effective.Encoding!.Value(NativeEncodingOption.Quality);
        Assert.AreEqual(("2", NativeOptionSource.Document), (quality.Value, quality.Source));
        var mapped = NativeSessionSetup.Resolve(null, commandLine: CommandLine("-FullScreenMode=Selected", "-FullScreenSelectedMonitors=2,1,2"),
                                                displays: new(["one", "two"], ["one", "two"]));
        CollectionAssert.AreEqual(new[] { "one", "two" }, mapped.Configuration().FullscreenPolicy.SelectedDisplays.ToArray());
        Assert.AreEqual(NativeOptionSource.CommandLine, mapped.MonitorSource);
        var cliMapping = Failure(() => NativeSessionSetup.Resolve(null, commandLine: CommandLine("-FullScreenSelectedMonitors=3")));
        Assert.AreEqual((NativeOptionSource.CommandLine, 1u), (cliMapping.Layer, cliMapping.Position));

        // App defaults, then profile, then command line.
        var app = Settings(("Shared", "on"), ("ReconnectOnError", "off"), ("SendClipboard", "off"), ("ScalingFactor", "Auto"));
        var profile = new NativeConnectionProfile(Guid.NewGuid(), "P", "profile.invalid", Settings(("Shared", "off"), ("ScalingQuality", "Nearest")), null, null);
        var layered = NativeSessionSetup.Resolve(app, profile, new NativeInvocationLayer(NativeInvocation.Parse(["-ReconnectOnError=on"]), "", null));
        var value = layered.Configuration();
        Assert.AreEqual("profile.invalid", layered.Endpoint, "without an operand the profile's address is used");
        Assert.AreEqual((false, NativeOptionSource.Profile), (value.Shared, value.SharedSource));
        Assert.AreEqual((true, NativeOptionSource.CommandLine), (value.ReconnectOnError, value.ReconnectSource));
        Assert.IsFalse(value.ClipboardSend);
        Assert.AreEqual(("Auto", NativeScalingFilter.Nearest), (value.Scaling!.Canonical, value.Scaling.Filter));
        Assert.AreEqual((NativeOptionSource.AppDefaults, NativeOptionSource.Profile),
            (value.ScalingSources[NativeScalingOption.Scaling], value.ScalingSources[NativeScalingOption.Filter]));
    }

    [TestMethod]
    public async Task SessionsCaptureTheirOwnPolicies()
    {
        using var ui = new SingleThreadDispatcher();
        await ui.InvokeAsync(async () =>
        {
            var runtime = new NativeRuntime(ui);
            var configuration = NativeSessionSetup.Resolve(null, document: File("Shared=on\nReconnectOnError=off\nViewOnly=on\nAlwaysCursor=on\nCursorType=System"))
                .Configuration();
            var first = runtime.CreateSession(configuration);
            var second = runtime.CreateSession();
            Assert.IsTrue(first.InitialShared && !first.InitialReconnectOnError && !second.InitialShared);
            Assert.AreEqual(NativeCursorFallback.System, first.InitialInput.CursorFallback);
            Assert.AreEqual(NativeOptionSource.Document, first.InitialInputSources[NativeInputOption.ViewOnly]);
            Assert.IsTrue(first.IsViewOnly && !second.IsViewOnly, "file input policy reaches the session");
            Assert.AreEqual(0, second.InitialInputSources.Count);
            await first.CloseAsync(); await second.CloseAsync();
            await runtime.ShutdownAsync();
            return 0;
        });
    }
}
