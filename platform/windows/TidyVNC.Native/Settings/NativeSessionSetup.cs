// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Immutable;
using TidyVNC.Native.Credentials;
using TidyVNC.Native.Desktop;
using TidyVNC.Native.Storage;
using TidyVNC.Native.Trust;

namespace TidyVNC.Native;

public enum NativeSetupProblem
{
    NotLaunch, UnsupportedOption, InvalidEndpoint, InvalidValue, DisplayMappingRequired, RelativePathNeedsBase,
    ReviewRequired, UnrepresentableField, InvalidListenPort, InvalidTunnelTarget, TunnelListenUnsupported,
}

/// <summary>
/// Why a command line or connection file cannot be applied (macOS
/// NativeInvocationResolutionFailure and NativeDocumentResolutionFailure).
/// Position is the one-based argument or line, or zero.
/// </summary>
public sealed class NativeSetupFailure : Exception
{
    public NativeSetupProblem Problem { get; }
    /// <summary>CommandLine or Document.</summary>
    public NativeOptionSource Layer { get; }
    public uint Position { get; }
    /// <summary>For DisplayMappingRequired: the monitor numbers that need displays.</summary>
    public IReadOnlyList<int> MonitorNumbers { get; }

    public NativeSetupFailure(NativeSetupProblem problem, NativeOptionSource source, uint position, IReadOnlyList<int>? numbers = null)
        : base($"{source} setup: {problem} at {position}")
    {
        Problem = problem; Layer = source; Position = position; MonitorNumbers = numbers ?? [];
    }

    public NativeText Text => Layer == NativeOptionSource.Document ? DocumentText() : CommandLineText();

    private NativeText CommandLineText()
    {
        var message = new NativeText(Problem switch
        {
            NativeSetupProblem.NotLaunch => "document.help.and.version.requests.do.not.create.a.connection",
            NativeSetupProblem.UnsupportedOption => "document.a.command.line.option.needs.a.native.adapter.that.is.not.available",
            NativeSetupProblem.InvalidEndpoint => "document.the.command.line.server.address.is.invalid",
            NativeSetupProblem.DisplayMappingRequired => "document.resolve.the.command.line.monitor.selection.before.continuing",
            NativeSetupProblem.RelativePathNeedsBase => "document.resolve.the.command.line.file.path.before.continuing",
            NativeSetupProblem.InvalidListenPort => "document.the.listen.port.must.be.a.decimal.number.from.0.to.65535",
            NativeSetupProblem.InvalidTunnelTarget => "document.ssh.forwarding.requires.a.supported.tcp.server.address.unix.socket.targets.are",
            NativeSetupProblem.TunnelListenUnsupported => "document.ssh.forwarding.cannot.be.combined.with.listening.for.connections",
            _ => "document.a.command.line.value.cannot.be.applied.to.this.connection",
        });
        return Position == 0 ? message : new NativeText("document.error.argument", Position, message);
    }

    private NativeText DocumentText()
    {
        var message = new NativeText(Problem switch
        {
            NativeSetupProblem.ReviewRequired => "document.review.the.ignored.connection.file.fields.before.continuing",
            NativeSetupProblem.InvalidEndpoint => "document.the.connection.file.contains.an.invalid.server.address",
            NativeSetupProblem.DisplayMappingRequired => "document.resolve.the.connection.file.s.monitor.selection.before.continuing",
            NativeSetupProblem.RelativePathNeedsBase => "document.resolve.the.connection.file.s.relative.verification.file.path.before.continuing",
            NativeSetupProblem.UnrepresentableField => "document.the.connection.file.contains.a.setting.this.native.viewer.cannot.apply",
            NativeSetupProblem.InvalidListenPort => "document.the.connection.file.s.servername.must.be.empty.or.a.decimal.listen",
            NativeSetupProblem.TunnelListenUnsupported => "document.ssh.forwarding.cannot.be.combined.with.listening.for.connections",
            NativeSetupProblem.InvalidTunnelTarget => "document.ssh.forwarding.requires.a.supported.tcp.server.address.unix.socket.targets.are",
            _ => "document.a.connection.file.option.has.an.invalid.value",
        });
        return Position == 0 ? message : new NativeText("document.error.description.line", message, Position);
    }
}

/// <summary>A connection-file field the viewer does not apply; the value is never kept.</summary>
public sealed record NativeDocumentNotice(NativeDocumentNotice.NoticeKind Kind, uint Line, string Name)
{
    public enum NoticeKind { UnknownField, PlatformOnly }

    public NativeText Text => new(Kind == NoticeKind.PlatformOnly ? "document.notice.platform" : "document.notice.unknown", Line, Name);
}

public enum NativeDocumentEndpointUse { Connection, ListenPort }

/// <summary>
/// A connection file's validated fields (macOS NativeDocumentResolution's
/// first pass): every recognized occurrence is checked before resolution, so
/// a malformed earlier value cannot hide behind a later valid one. Unknown
/// and platform-only fields become notices the user must acknowledge.
/// </summary>
public sealed class NativeDocumentLayer
{
    /// <summary>The file fields a native viewer applies (plus ServerName).</summary>
    public static IReadOnlySet<string> Supported { get; } = NativeEncodingOptions.Schema().Select(s => s.Name).Concat(
    [
        "ServerName", "Shared", "ReconnectOnError", "AcceptClipboard", "SendClipboard", "ViewOnly", "EmulateMiddleButton",
        "FullscreenSystemKeys", "ShortcutModifiers", "AlwaysCursor", "CursorType", "DotWhenNoCursor", "ScalingFactor",
        "ScalingQuality", "DesktopPixelUnits", "SecurityTypes", "X509CA", "X509CRL", "FullScreen", "FullScreenMode",
        "FullScreenSelectedMonitors", "FullScreenAllMonitors",
    ]).ToHashSet(StringComparer.Ordinal);

    private static readonly Dictionary<string, string> PlatformOnly = new(StringComparer.OrdinalIgnoreCase)
    {
        ["audio"] = "Audio", ["sendprimary"] = "SendPrimary", ["setprimary"] = "SetPrimary",
    };

    public NativeConnectionDocument Document { get; }
    /// <summary>The file's folder: relative CA/CRL paths resolve against it.</summary>
    public string Directory { get; }
    public NativeDocumentEndpointUse EndpointUse { get; }
    public IReadOnlyList<(NativeDocumentAssignment Field, uint Line)> Fields { get; }
    public IReadOnlyList<NativeDocumentNotice> Notices { get; }

    private NativeDocumentLayer(NativeConnectionDocument document, string directory, NativeDocumentEndpointUse use,
                                IReadOnlyList<(NativeDocumentAssignment, uint)> fields, IReadOnlyList<NativeDocumentNotice> notices)
    {
        Document = document; Directory = directory; EndpointUse = use; Fields = fields; Notices = notices;
    }

    /// <summary>Throws <see cref="NativeSetupFailure"/> or <see cref="NativeDocumentFailure"/> for values that cannot be applied.</summary>
    public static NativeDocumentLayer Create(NativeConnectionDocument document, string directory,
                                             NativeDocumentEndpointUse use = NativeDocumentEndpointUse.Connection)
    {
        var fields = new List<(NativeDocumentAssignment, uint)>();
        var notices = new List<NativeDocumentNotice>();
        for (var index = 0; index < document.Entries.Count; index++)
        {
            var entry = document.Entries[index];
            if (PlatformOnly.TryGetValue(entry.Name, out var name))
            {
                // Unknown to the retained Windows viewer too; future escapes stay opaque.
                notices.Add(new(NativeDocumentNotice.NoticeKind.PlatformOnly, entry.Line, name));
                continue;
            }
            if (document.ValidatedOption(index) is not { } field)
            {
                notices.Add(new(NativeDocumentNotice.NoticeKind.UnknownField, entry.Line, entry.Name));
                continue;
            }
            if (!Supported.Contains(field.Name))
                throw new NativeSetupFailure(NativeSetupProblem.UnrepresentableField, NativeOptionSource.Document, entry.Line);
            if (use == NativeDocumentEndpointUse.ListenPort && field.Name == "ServerName" && field.Value.Length != 0 &&
                NativeEndpoint.ParsePort(field.Value) is null)
                throw new NativeSetupFailure(NativeSetupProblem.InvalidListenPort, NativeOptionSource.Document, entry.Line);
            fields.Add((field, entry.Line));
        }
        return new NativeDocumentLayer(document, directory, use, fields, notices);
    }

    /// <summary>The file's ServerName (last occurrence); an absent one is empty, never inherited.</summary>
    public string Endpoint => Fields.LastOrDefault(f => f.Field.Name == "ServerName").Field?.Value ?? "";
}

/// <summary>
/// A launch command line (macOS NativeInvocationRequest): the parsed
/// arguments, the classified server address and the launch working directory.
/// </summary>
public sealed class NativeInvocationLayer
{
    /// <summary>Command-line parameters a native connection applies (macOS supportedOptions).</summary>
    public static IReadOnlySet<string> Supported { get; } = NativeDocumentLayer.Supported.Where(n => n != "ServerName").Concat(
    [
        "AlertOnFatalError", "DesktopSize", "RemoteResize", "GnuTLSPriority", "UseIPv4", "UseIPv6", "PointerEventInterval",
        "MaxCutText", "geometry", "Maximize", "Log", "PasswordFile", "listen", "via",
    ]).ToHashSet(StringComparer.Ordinal);

    /// <summary>Launch metadata handled outside the settings layers.</summary>
    private static readonly HashSet<string> LaunchOnly = new(StringComparer.Ordinal) { "Log", "PasswordFile", "listen", "via" };

    public NativeInvocation Invocation { get; }
    public string Endpoint { get; }
    public string? WorkingDirectory { get; }
    public IReadOnlyDictionary<int, string>? MonitorMapping { get; }

    public NativeInvocationLayer(NativeInvocation invocation, string endpoint, string? workingDirectory,
                                 IReadOnlyDictionary<int, string>? monitorMapping = null)
    {
        Invocation = invocation; Endpoint = endpoint; WorkingDirectory = workingDirectory; MonitorMapping = monitorMapping;
    }

    /// <summary>AlertOnFatalError, known before any session exists (startup and listener failures).</summary>
    public bool AlertOnFatalError => Invocation.Value("AlertOnFatalError") != "off";

    /// <summary>
    /// The SSH gateway in effect: every via is validated, the last wins and an
    /// empty value selects a direct connection. Combined with listen it fails.
    /// </summary>
    public NativeSshGateway? Gateway(NativeSshGateway? inherited = null, string endpoint = "")
    {
        var gateway = inherited;
        uint argument = 0;
        foreach (var field in Invocation.Assignments.Where(a => a.Name == "via"))
        {
            argument = field.Argument;
            try { gateway = field.Value.Length == 0 ? null : NativeSshGateway.Parse(field.Value); }
            catch (NativeError) { throw new NativeSetupFailure(NativeSetupProblem.InvalidValue, NativeOptionSource.CommandLine, field.Argument); }
        }
        if (gateway is not null && Invocation.Value("listen") == "on")
            throw new NativeSetupFailure(NativeSetupProblem.TunnelListenUnsupported, NativeOptionSource.CommandLine, argument);
        if (gateway is not null && endpoint.Length != 0 && !NativeSessionSetup.IsTunnelTarget(endpoint))
            throw new NativeSetupFailure(NativeSetupProblem.InvalidTunnelTarget, NativeOptionSource.CommandLine, Invocation.OperandArgument);
        return gateway;
    }

    /// <summary>Checks the launch-only options and returns the settings assignments (macOS NativeInvocationPreparation).</summary>
    internal IEnumerable<NativeConfigAssignment> Assignments()
    {
        if (Invocation.Action != NativeInvocationAction.Launch) throw new NativeSetupFailure(NativeSetupProblem.NotLaunch, NativeOptionSource.CommandLine, 0);
        try { _ = NativeLaunchCredentialInputs.PasswordFile(Invocation, WorkingDirectory); }
        catch (NativeLaunchCredentialException error)
        {
            throw new NativeSetupFailure(error.Reason == NativeLaunchCredentialException.Problem.RelativePathNeedsBase
                ? NativeSetupProblem.RelativePathNeedsBase : NativeSetupProblem.InvalidValue, NativeOptionSource.CommandLine, error.Argument);
        }
        _ = Gateway();
        if (Endpoint.Length != 0 && NativeEndpoint.Issue(Endpoint) is not null)
            throw new NativeSetupFailure(NativeSetupProblem.InvalidEndpoint, NativeOptionSource.CommandLine, Invocation.OperandArgument);
        var result = new List<NativeConfigAssignment>();
        foreach (var field in Invocation.Assignments)
        {
            if (!Supported.Contains(field.Name)) throw new NativeSetupFailure(NativeSetupProblem.UnsupportedOption, NativeOptionSource.CommandLine, field.Argument);
            if (field.Name == "Log")
            {
                // Target admission (the core parser already checked the syntax).
                try { NativeProcessLogging.Validate(field.Value); }
                catch (NativeError error)
                {
                    throw new NativeSetupFailure(error.Status == NativeStatus.Unsupported ? NativeSetupProblem.UnsupportedOption
                        : NativeSetupProblem.InvalidValue, NativeOptionSource.CommandLine, field.Argument);
                }
            }
            if (LaunchOnly.Contains(field.Name)) continue;
            var value = field.Value;
            try
            {
                switch (field.Name)
                {
                    case "geometry": _ = NativeWindowGeometry.Parse(value); break;
                    // The retained DesktopWindow "%dx%d" leniency, canonicalized once here.
                    case "DesktopSize": value = NativeDesktopSize.Parse(value, legacy: true) is { } size ? $"{size.Width}x{size.Height}" : ""; break;
                    case "GnuTLSPriority" when System.Text.Encoding.UTF8.GetByteCount(value) > 4096:
                        throw new NativeSetupFailure(NativeSetupProblem.InvalidValue, NativeOptionSource.CommandLine, field.Argument);
                }
            }
            catch (NativeError) { throw new NativeSetupFailure(NativeSetupProblem.InvalidValue, NativeOptionSource.CommandLine, field.Argument); }
            result.Add(new NativeConfigAssignment(field.Name, value, NativeOptionSource.CommandLine, field.Argument));
        }
        return result;
    }
}

/// <summary>The displays a resolution may map monitor numbers to.</summary>
/// <param name="Legacy">Stable display IDs in legacy monitor-number order (monitor 1 first).</param>
/// <param name="Available">Every connected display.</param>
public sealed record NativeSetupDisplays(IReadOnlyList<string> Legacy, IReadOnlyList<string> Available)
{
    public static NativeSetupDisplays None { get; } = new([], []);
}

/// <summary>
/// The startup layers of one new connection (PLAN.md section 6): app
/// defaults, the selected profile, the command line and an explicit file.
/// The core resolver (W2.2) applies the precedence, migrations and
/// provenance; this type turns the effective values into a session
/// configuration and its frontend policies (macOS NativeOptionOverlay,
/// NativeInvocationResolution and NativeDocumentResolution).
/// </summary>
public sealed class NativeSessionSetup
{
    private static readonly NativeOptionSource[] Layers =
        [NativeOptionSource.AppDefaults, NativeOptionSource.Profile, NativeOptionSource.CommandLine, NativeOptionSource.Document];

    private readonly NativeSessionConfiguration candidate;

    public NativeConfigResolution Resolution { get; }
    /// <summary>The address this connection starts with: the file's (even empty), the command line's or the profile's.</summary>
    public string Endpoint { get; }
    /// <summary>For a listener file: the port to bind (an empty ServerName means 5500).</summary>
    public uint? ListenPort { get; }
    /// <summary>The cursor shape kept while the cursor fallback is hidden (dormant CursorType).</summary>
    public NativeCursorFallback InactiveCursor { get; }
    public IReadOnlyList<int> MonitorNumbers { get; }
    public NativeOptionSource? MonitorSource { get; }
    public IReadOnlyDictionary<int, string> MonitorMapping { get; }
    public bool ExplicitMonitorMapping { get; }
    public IReadOnlyList<NativeDocumentNotice> Notices { get; }

    private NativeSessionSetup(NativeSessionConfiguration candidate, NativeConfigResolution resolution, string endpoint, uint? listenPort,
                               NativeCursorFallback inactive, IReadOnlyList<int> numbers, NativeOptionSource? monitorSource,
                               IReadOnlyDictionary<int, string> mapping, bool explicitMapping, IReadOnlyList<NativeDocumentNotice> notices)
    {
        this.candidate = candidate; Resolution = resolution; Endpoint = endpoint; ListenPort = listenPort; InactiveCursor = inactive;
        MonitorNumbers = numbers; MonitorSource = monitorSource; MonitorMapping = mapping; ExplicitMonitorMapping = explicitMapping; Notices = notices;
    }

    /// <summary>The configuration; a file's ignored fields must be acknowledged by line first.</summary>
    public NativeSessionConfiguration Configuration(IReadOnlySet<uint>? acknowledged = null)
    {
        if (Notices.Any(n => acknowledged?.Contains(n.Line) != true))
            throw new NativeSetupFailure(NativeSetupProblem.ReviewRequired, NativeOptionSource.Document, 0);
        return candidate;
    }

    public static bool IsTunnelTarget(string endpoint)
    {
        try
        {
            using var identity = NativeEndpointIdentity.Create(endpoint, allowUnixSockets: false);
            return identity.Kind == NativeEndpointIdentity.NativeEndpointKind.Tcp;
        }
        catch (NativeError) { return false; }
    }

    /// <summary>
    /// Resolves the layers. Monitor numbers from the command line or the file
    /// map to displays through <paramref name="mapping"/> when given, otherwise
    /// through legacy numbering; when neither covers them this throws
    /// DisplayMappingRequired with the numbers to ask about.
    /// </summary>
    public static NativeSessionSetup Resolve(NativeSettings? appDefaults, NativeConnectionProfile? profile = null,
                                             NativeInvocationLayer? commandLine = null, NativeDocumentLayer? document = null,
                                             NativeSetupDisplays? displays = null, IReadOnlyDictionary<int, string>? mapping = null)
    {
        displays ??= NativeSetupDisplays.None;
        var assignments = new List<NativeConfigAssignment>();
        void AddSettings(NativeSettings? settings, NativeOptionSource source)
        {
            if (settings is null) return;
            var position = 0u;
            foreach (var (name, value) in settings.Parameters) assignments.Add(new(name, value, source, ++position));
        }
        AddSettings(appDefaults, NativeOptionSource.AppDefaults);
        AddSettings(profile?.Settings, NativeOptionSource.Profile);
        if (commandLine is not null) assignments.AddRange(commandLine.Assignments());
        if (document is not null)
            assignments.AddRange(document.Fields.Where(f => f.Field.Name != "ServerName")
                .Select(f => new NativeConfigAssignment(f.Field.Name, f.Field.Value, NativeOptionSource.Document, f.Line)));

        NativeConfigResolution resolution;
        try { resolution = NativeConfiguration.Resolve(assignments); }
        catch (NativeConfigFailure failure)
        {
            var failed = failure.Index is > 0 && failure.Index <= assignments.Count ? assignments[(int)failure.Index - 1] : null;
            if (failed is null || failed.Source is NativeOptionSource.AppDefaults or NativeOptionSource.Profile)
                throw new NativeStorageException(NativeStorageError.Corrupt);
            throw new NativeSetupFailure(failure.Reason == NativeConfigFailure.Problem.Unavailable && failed.Source == NativeOptionSource.CommandLine
                ? NativeSetupProblem.UnsupportedOption : NativeSetupProblem.InvalidValue, failed.Source, failed.Position);
        }

        var builder = new Builder(resolution);
        var configuration = new NativeSessionConfiguration();

        // Endpoint: an explicit file never silently connects to another layer's host.
        string endpoint;
        uint? listenPort = null;
        if (document is not null)
        {
            endpoint = document.Endpoint;
            var line = document.Fields.LastOrDefault(f => f.Field.Name == "ServerName").Line;
            if (document.EndpointUse == NativeDocumentEndpointUse.ListenPort)
                listenPort = endpoint.Length == 0 ? 5500 : NativeEndpoint.ParsePort(endpoint) ??
                    throw new NativeSetupFailure(NativeSetupProblem.InvalidListenPort, NativeOptionSource.Document, line);
            else if (endpoint.Length != 0 && NativeEndpoint.Issue(endpoint) is not null)
                throw new NativeSetupFailure(NativeSetupProblem.InvalidEndpoint, NativeOptionSource.Document, line);
        }
        else endpoint = commandLine?.Endpoint is { Length: > 0 } operand ? operand : profile?.Endpoint ?? "";

        builder.Flag("Shared", v => configuration.Shared = v, s => configuration.SharedSource = s);
        builder.Flag("ReconnectOnError", v => configuration.ReconnectOnError = v, s => configuration.ReconnectSource = s);
        builder.Flag("SendClipboard", v => configuration.ClipboardSend = v);
        builder.Flag("AcceptClipboard", v => configuration.ClipboardReceive = v);
        builder.Flag("AlertOnFatalError", v => configuration.AlertOnFatalError = v);
        builder.Flag("UseIPv4", v => configuration.Ipv4 = v, s => configuration.NetworkSources[NativeNetworkOption.Ipv4] = s);
        builder.Flag("UseIPv6", v => configuration.Ipv6 = v, s => configuration.NetworkSources[NativeNetworkOption.Ipv6] = s);
        if (builder.Value("PointerEventInterval") is { } interval)
        {
            configuration.PointerEventIntervalMilliseconds = uint.Parse(interval.Value, System.Globalization.CultureInfo.InvariantCulture);
            configuration.PointerEventIntervalSource = interval.Source;
        }
        if (builder.Value("MaxCutText") is { } limit)
        {
            configuration.MaxCutText = uint.Parse(limit.Value, System.Globalization.CultureInfo.InvariantCulture);
            configuration.MaxCutTextSource = limit.Source;
        }

        // Encoding: each layer patches the one below with its own provenance.
        var schema = NativeEncodingOptions.Schema().Select(s => s.Name).ToHashSet(StringComparer.Ordinal);
        NativeEncodingOptions? encoding = null;
        foreach (var layer in Layers)
        {
            var patch = resolution.Values.Where(v => v.Source == layer && schema.Contains(v.Name))
                .Select(v => new NativeEncodingAssignment(v.Name, v.Value)).ToList();
            if (patch.Count == 0) continue;
            try { encoding = (encoding ?? new NativeEncodingOptions()).Applying(patch, layer); }
            catch (NativeError) { throw builder.Failure(patch[0].Name); }
        }
        configuration.Encoding = encoding;

        // Input, with the retained cursor rules (the core already migrated DotWhenNoCursor).
        var input = NativeInputSettings.BuiltIn;
        builder.Flag("ViewOnly", v => input = input with { ViewOnly = v }, s => configuration.InputSources[NativeInputOption.ViewOnly] = s);
        builder.Flag("EmulateMiddleButton", v => input = input with { EmulateMiddle = v }, s => configuration.InputSources[NativeInputOption.EmulateMiddle] = s);
        builder.Flag("FullscreenSystemKeys", v => input = input with { FullscreenSystemKeys = v }, s => configuration.InputSources[NativeInputOption.FullscreenSystemKeys] = s);
        if (builder.Value("ShortcutModifiers") is { } modifiers)
        {
            input = input with { ShortcutModifiers = NativeInputSettings.ParseModifiers(modifiers.Value) };
            configuration.InputSources[NativeInputOption.ShortcutModifiers] = modifiers.Source;
        }
        var always = builder.Value("AlwaysCursor");
        var shape = builder.Value("CursorType");
        var inactive = shape?.Value == "System" ? NativeCursorFallback.System : NativeCursorFallback.Dot;
        if (always is not null || shape is not null)
        {
            input = input with { CursorFallback = always?.Value == "on" ? inactive : NativeCursorFallback.Hidden };
            configuration.InputSources[NativeInputOption.CursorFallback] = Highest(always?.Source, shape is { Dormant: false } ? shape.Source : null)!.Value;
        }
        configuration.Input = input;

        // Scaling.
        var factor = builder.Value("ScalingFactor");
        var units = builder.Value("DesktopPixelUnits");
        var quality = builder.Value("ScalingQuality");
        if (factor is not null || units is not null || quality is not null)
        {
            try
            {
                configuration.Scaling = NativeScaling.Parse(factor?.Value ?? NativeScaling.BuiltIn.Canonical, units?.Value == "Device",
                    quality is null ? NativeScalingFilter.Bilinear : NativeScalingModes.ParseFilter(quality.Value));
            }
            catch (NativeError) { throw builder.Failure("ScalingFactor"); }
            if (factor is not null) configuration.ScalingSources[NativeScalingOption.Scaling] = factor.Source;
            if (units is not null) configuration.ScalingSources[NativeScalingOption.DevicePixels] = units.Source;
            if (quality is not null) configuration.ScalingSources[NativeScalingOption.Filter] = quality.Source;
        }

        // Security and verification files.
        if (builder.Value("SecurityTypes") is { } types)
        {
            try { configuration.SecurityTypes = new NativeSecuritySelection(types.Value).Types; }
            catch (NativeError) { throw builder.Failure("SecurityTypes"); }
            configuration.SecuritySource = types.Source;
        }
        if (builder.Value("GnuTLSPriority") is { } priority)
        {
            configuration.TlsPriority = priority.Value; configuration.TlsPrioritySource = priority.Source;
        }
        configuration.CaFile = builder.Path("X509CA", commandLine?.WorkingDirectory, document?.Directory) ?? "";
        configuration.CrlFile = builder.Path("X509CRL", commandLine?.WorkingDirectory, document?.Directory) ?? "";

        // Remote resize and window placement.
        var resize = builder.Value("RemoteResize");
        var size = builder.Value("DesktopSize");
        if (resize is not null || size is not null)
        {
            try { configuration.ResizePolicy = new NativeRemoteResizePolicy(resize?.Value != "off", size?.Value ?? ""); }
            catch (NativeError) { throw builder.Failure("DesktopSize"); }
            if (resize is not null) configuration.ResizeSources[NativeResizeOption.Enabled] = resize.Source;
            if (size is not null) configuration.ResizeSources[NativeResizeOption.InitialSize] = size.Source;
        }
        var geometry = builder.Value("geometry");
        var maximize = builder.Value("Maximize");
        if (geometry is not null || maximize is not null)
        {
            configuration.WindowStartupPolicy = new NativeWindowStartupPolicy(geometry is null ? null : NativeWindowGeometry.Parse(geometry.Value), maximize?.Value == "on");
            if (geometry is not null) configuration.WindowStartupSources[NativeWindowStartupOption.Geometry] = geometry.Source;
            if (maximize is not null) configuration.WindowStartupSources[NativeWindowStartupOption.Maximize] = maximize.Source;
        }

        // Full screen: stable IDs from settings layers; monitor numbers from the command line or file.
        var starts = builder.Value("FullScreen");
        var mode = builder.Value("FullScreenMode");
        var fullscreenMode = mode is null ? NativeFullscreenMode.Current : Enum.Parse<NativeFullscreenMode>(mode.Value);
        var selection = builder.Value("FullScreenSelectedMonitors");
        var (settingsIds, settingsSource) = profile?.Settings.FullscreenDisplays is { IsEmpty: false } profileIds
            ? (profileIds, (NativeOptionSource?)NativeOptionSource.Profile)
            : appDefaults?.FullscreenDisplays is { IsEmpty: false } appIds ? (appIds, NativeOptionSource.AppDefaults) : ([], null);
        IReadOnlyList<int> numbers = selection is not null
            ? [.. selection.Value.Split(',').Select(n => int.Parse(n, System.Globalization.CultureInfo.InvariantCulture)).Distinct().Order()]
            : fullscreenMode == NativeFullscreenMode.Selected && settingsIds.IsEmpty ? [1] : [];
        NativeOptionSource? numberSource = numbers.Count == 0 ? null : selection?.Source ?? mode?.Source;
        if (numbers.Count > 64) throw new NativeSetupFailure(NativeSetupProblem.UnrepresentableField, numberSource ?? NativeOptionSource.Document, 0);
        var explicitMapping = mapping ?? (numbers.Count != 0 ? commandLine?.MonitorMapping : null);
        var assigned = new SortedDictionary<int, string>();
        var numberPosition = selection?.Position ?? mode?.Position ?? 0;
        var mappingFailure = () => new NativeSetupFailure(NativeSetupProblem.DisplayMappingRequired,
            numberSource is NativeOptionSource.CommandLine ? NativeOptionSource.CommandLine : NativeOptionSource.Document, numberPosition, numbers);
        if (explicitMapping is not null && numbers.Count != 0)
        {
            if (!explicitMapping.Keys.Order().SequenceEqual(numbers) || explicitMapping.Values.Any(id => !displays.Available.Contains(id)))
                throw mappingFailure();
        }
        foreach (var number in numbers)
        {
            if (explicitMapping is not null) assigned[number] = explicitMapping[number];
            else if (number <= displays.Legacy.Count) assigned[number] = displays.Legacy[number - 1];
            else throw mappingFailure();
        }
        try
        {
            configuration.FullscreenPolicy = new NativeFullscreenPolicy(starts?.Value == "on", fullscreenMode,
                numbers.Count != 0 ? assigned.Values.Distinct(StringComparer.Ordinal) : settingsIds);
        }
        catch (ArgumentException) { throw mappingFailure(); }
        if (starts is not null) configuration.FullscreenSources[NativeFullscreenOption.StartsFullscreen] = starts.Source;
        if (mode is not null) configuration.FullscreenSources[NativeFullscreenOption.Mode] = mode.Source;
        if ((numberSource ?? settingsSource) is { } selectedSource)
            configuration.FullscreenSources[NativeFullscreenOption.SelectedDisplays] = selectedSource;

        return new NativeSessionSetup(configuration, resolution, endpoint, listenPort, inactive, numbers, numberSource,
            assigned, explicitMapping is not null && numbers.Count != 0, document?.Notices ?? []);
    }

    private static NativeOptionSource? Highest(NativeOptionSource? a, NativeOptionSource? b)
    {
        static int Rank(NativeOptionSource? s) => s is null ? -1 : Array.IndexOf(Layers, s.Value);
        return Rank(a) >= Rank(b) ? a : b;
    }

    private sealed class Builder(NativeConfigResolution resolution)
    {
        public NativeConfigValue? Value(string name) => resolution[name];

        public void Flag(string name, Action<bool> set, Action<NativeOptionSource>? source = null)
        {
            if (Value(name) is not { } value) return;
            set(value.Value == "on");
            source?.Invoke(value.Source);
        }

        public NativeSetupFailure Failure(string name)
        {
            var value = Value(name);
            if (value is null || value.Source is NativeOptionSource.AppDefaults or NativeOptionSource.Profile)
                throw new NativeStorageException(NativeStorageError.Corrupt);
            return new NativeSetupFailure(NativeSetupProblem.InvalidValue, value.Source, value.Position);
        }

        /// <summary>
        /// A CA/CRL path under the Windows rules: fully qualified as given;
        /// plain relative ones against the launch directory (command line) or
        /// the file's folder (file); drive- and root-relative ones refused.
        /// </summary>
        public string? Path(string name, string? workingDirectory, string? documentDirectory)
        {
            if (Value(name) is not { } value) return null;
            var directory = value.Source switch
            {
                NativeOptionSource.CommandLine => workingDirectory,
                NativeOptionSource.Document => documentDirectory,
                _ => null,
            };
            if (NativeTrustFiles.IsValidPath(value.Value)) return value.Value;
            if (directory is not null && NativeTrustFiles.ResolveRelative(value.Value, directory) is { } resolved) return resolved;
            if (value.Source is NativeOptionSource.AppDefaults or NativeOptionSource.Profile) throw new NativeStorageException(NativeStorageError.Corrupt);
            throw new NativeSetupFailure(NativeSetupProblem.RelativePathNeedsBase, value.Source, value.Position);
        }
    }
}
