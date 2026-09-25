// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Immutable;
using System.Text.Json;

namespace TidyVNC.Native.Storage;

/// <summary>
/// A settings patch: canonical parameter values (unset parameters inherit),
/// plus the fullscreen display selection as stable display IDs. The Windows
/// counterpart of the macOS NativePreferences fields (SERVICES.md section 2),
/// validated by the core's configuration resolver rather than per-field code.
/// </summary>
public sealed record NativeSettings(ImmutableSortedDictionary<string, string> Parameters, ImmutableArray<string> FullscreenDisplays)
{
    public static NativeSettings Empty { get; } = new(ImmutableSortedDictionary.Create<string, string>(StringComparer.Ordinal), []);

    /// <summary>
    /// The parameters a settings patch may hold: connection, clipboard,
    /// fullscreen, remote resize, security and trust files, scaling, input and
    /// encoding. Never endpoints, credentials, tunnels, logging or listening.
    /// </summary>
    public static ImmutableSortedSet<string> Allowed { get; } = ImmutableSortedSet.Create(StringComparer.Ordinal,
        "SendClipboard", "AcceptClipboard", "Shared", "ReconnectOnError", "FullScreen", "FullScreenMode", "RemoteResize",
        "DesktopSize", "SecurityTypes", "GnuTLSPriority", "X509CA", "X509CRL", "ScalingFactor", "ScalingQuality",
        "DesktopPixelUnits", "ViewOnly", "EmulateMiddleButton", "FullscreenSystemKeys", "ShortcutModifiers", "AlwaysCursor",
        "CursorType", "AutoSelect", "FullColor", "LowColorLevel", "PreferredEncoding", "CustomCompressLevel", "CompressLevel",
        "NoJPEG", "QualityLevel");

    public bool Equals(NativeSettings? other) => other is not null && Parameters.SequenceEqual(other.Parameters) &&
                                                 FullscreenDisplays.SequenceEqual(other.FullscreenDisplays);
    public override int GetHashCode() => HashCode.Combine(Parameters.Count, FullscreenDisplays.Length);

    /// <summary>Canonicalizes and validates values through the core (source: app defaults or profile).</summary>
    public static NativeSettings Create(IEnumerable<KeyValuePair<string, string>> parameters, IEnumerable<string>? fullscreenDisplays = null)
    {
        var input = parameters.ToList();
        foreach (var parameter in input)
            if (!Allowed.Contains(parameter.Key, StringComparer.OrdinalIgnoreCase))
                throw new ArgumentException($"{parameter.Key} is not a stored setting", nameof(parameters));
        var resolved = NativeConfiguration.Resolve(input.Select((p, i) => new NativeConfigAssignment(p.Key, p.Value, NativeOptionSource.AppDefaults, (uint)i + 1)).ToList());
        if (resolved.Notes.Count != 0 || resolved.Values.Count != input.Count)
            throw new ArgumentException("Duplicate or deprecated parameters are not settings", nameof(parameters));
        foreach (var value in resolved.Values)
            if (!Allowed.Contains(value.Name)) throw new ArgumentException($"{value.Name} is not a stored setting", nameof(parameters));
        var displays = (fullscreenDisplays ?? []).ToImmutableArray();
        if (displays.Length > 64 || displays.Distinct(StringComparer.Ordinal).Count() != displays.Length ||
            displays.Any(d => d.Length is 0 or > 64 || !d.All(char.IsAsciiHexDigitLower)))
            throw new ArgumentException("Invalid display selection", nameof(fullscreenDisplays));
        return new NativeSettings(resolved.Values.ToImmutableSortedDictionary(v => v.Name, v => v.Value, StringComparer.Ordinal), displays);
    }

    internal static NativeSettings Decode(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object) throw new NativeStorageException(NativeStorageError.Corrupt);
        var parameters = new List<KeyValuePair<string, string>>();
        IEnumerable<string>? displays = null;
        foreach (var property in element.EnumerateObject())
        {
            if (property.Name == "fullscreenDisplays")
            {
                if (property.Value.ValueKind != JsonValueKind.Array) throw new NativeStorageException(NativeStorageError.Corrupt);
                displays = property.Value.EnumerateArray().Select(d => d.ValueKind == JsonValueKind.String ? d.GetString()! : throw new NativeStorageException(NativeStorageError.Corrupt)).ToList();
            }
            else if (property.Name == "parameters")
            {
                if (property.Value.ValueKind != JsonValueKind.Object) throw new NativeStorageException(NativeStorageError.Corrupt);
                foreach (var parameter in property.Value.EnumerateObject())
                {
                    if (!Allowed.Contains(parameter.Name)) throw new NativeStorageException(NativeStorageError.UnsupportedFields);
                    if (parameter.Value.ValueKind != JsonValueKind.String) throw new NativeStorageException(NativeStorageError.Corrupt);
                    parameters.Add(new(parameter.Name, parameter.Value.GetString()!));
                }
            }
            else throw new NativeStorageException(NativeStorageError.UnsupportedFields);
        }
        NativeSettings settings;
        try { settings = Create(parameters, displays); }
        catch (Exception error) when (error is ArgumentException or NativeConfigFailure) { throw new NativeStorageException(NativeStorageError.Corrupt); }
        // Only canonical values are ever written; anything else was edited or damaged.
        if (!settings.Parameters.SequenceEqual(parameters.OrderBy(p => p.Key, StringComparer.Ordinal)))
            throw new NativeStorageException(NativeStorageError.Corrupt);
        return settings;
    }

    internal void Encode(Utf8JsonWriter writer)
    {
        writer.WriteStartObject("parameters");
        foreach (var (name, value) in Parameters) writer.WriteString(name, value);
        writer.WriteEndObject();
        if (!FullscreenDisplays.IsEmpty)
        {
            writer.WriteStartArray("fullscreenDisplays");
            foreach (var display in FullscreenDisplays) writer.WriteStringValue(display);
            writer.WriteEndArray();
        }
    }
}

/// <summary>Where preferences were imported from, once (macOS: importedFrom).</summary>
public enum NativeImportOrigin { None, Registry }

public sealed record NativePreferencesRecord(NativeSettings Settings, NativeImportOrigin ImportedFrom);

/// <summary>preferences.json: application defaults (SERVICES.md section 2). Schema 1.</summary>
public sealed class NativePreferencesStore(string directory) : NativeRecordStore<NativePreferencesRecord>(directory, "preferences.json")
{
    public NativePreferencesStore() : this(NativeStateRoot.Directory) { }
    protected override int Schema => 1;
    protected override int MaximumBytes => 1024 * 1024;
    protected override NativePreferencesRecord Empty => new(NativeSettings.Empty, NativeImportOrigin.None);

    protected override NativePreferencesRecord Decode(JsonElement record, int schema)
    {
        RequireOnly(record, "settings", "importedFrom");
        var settings = record.TryGetProperty("settings", out var value) ? NativeSettings.Decode(value) : NativeSettings.Empty;
        var origin = NativeImportOrigin.None;
        if (record.TryGetProperty("importedFrom", out var imported))
            origin = imported.ValueKind == JsonValueKind.String && imported.GetString() == "registry" ? NativeImportOrigin.Registry : throw Corrupt();
        return new(settings, origin);
    }

    protected override void Encode(Utf8JsonWriter writer, NativePreferencesRecord value)
    {
        writer.WritePropertyName("settings");
        writer.WriteStartObject();
        value.Settings.Encode(writer);
        writer.WriteEndObject();
        if (value.ImportedFrom == NativeImportOrigin.Registry) writer.WriteString("importedFrom", "registry");
    }
}

/// <summary>A destination: exact endpoint text plus an optional SSH gateway (part of its identity).</summary>
public sealed record NativeConnectionDestination(string Endpoint, NativeSshGateway? SshGateway)
{
    public bool Equals(NativeConnectionDestination? other) => other is not null && string.Equals(Endpoint, other.Endpoint, StringComparison.Ordinal) &&
                                                              SshGateway?.CanonicalUri == other.SshGateway?.CanonicalUri;
    public override int GetHashCode() => HashCode.Combine(Endpoint, SshGateway?.CanonicalUri);
}

public sealed record NativeConnectionProfile(Guid Id, string Name, string Endpoint, NativeSettings Settings, NativeSshGateway? SshGateway,
                                             Guid? CredentialReference)
{
    public NativeConnectionDestination Destination => new(Endpoint, SshGateway);
}

/// <summary>How history was first initialized (not the latest writer).</summary>
public enum NativeHistoryState { Uninitialized, Native, Registry }

public sealed record NativeProfileHistory(ImmutableArray<NativeConnectionProfile> Profiles,
                                          ImmutableArray<NativeConnectionDestination> RecentConnections, NativeHistoryState HistoryState)
{
    public static NativeProfileHistory Empty { get; } = new([], [], NativeHistoryState.Uninitialized);
    public bool CanImportHistory => HistoryState == NativeHistoryState.Uninitialized && RecentConnections.IsEmpty;
    public bool Equals(NativeProfileHistory? other) => other is not null && Profiles.SequenceEqual(other.Profiles) &&
                                                       RecentConnections.SequenceEqual(other.RecentConnections) && HistoryState == other.HistoryState;
    public override int GetHashCode() => HashCode.Combine(Profiles.Length, RecentConnections.Length, HistoryState);
}

/// <summary>profiles-history.json: saved profiles and recent connections. Schema 1.</summary>
public sealed class NativeProfileHistoryStore(string directory) : NativeRecordStore<NativeProfileHistory>(directory, "profiles-history.json")
{
    public const int HistoryCapacity = 20; // The retained SERVER_HISTORY_SIZE.
    public const int ProfileCapacity = 256;

    public NativeProfileHistoryStore() : this(NativeStateRoot.Directory) { }
    protected override int Schema => 1;
    protected override NativeProfileHistory Empty => NativeProfileHistory.Empty;

    private static string Text(JsonElement element, string name, int maximum, bool required = true)
    {
        if (!element.TryGetProperty(name, out var value))
            return required ? throw new NativeStorageException(NativeStorageError.Corrupt) : "";
        if (value.ValueKind != JsonValueKind.String) throw new NativeStorageException(NativeStorageError.Corrupt);
        var text = value.GetString()!;
        if (System.Text.Encoding.UTF8.GetByteCount(text) > maximum || text.Contains('\0', StringComparison.Ordinal))
            throw new NativeStorageException(NativeStorageError.Corrupt);
        return text;
    }

    private static NativeSshGateway? Gateway(JsonElement element)
    {
        if (!element.TryGetProperty("sshGateway", out var value)) return null;
        if (value.ValueKind != JsonValueKind.String) throw new NativeStorageException(NativeStorageError.Corrupt);
        try
        {
            var gateway = NativeSshGateway.Parse(value.GetString()!);
            // Stored gateways are canonical; a route digest is never a gateway.
            return gateway.CanonicalUri == value.GetString() ? gateway : throw new NativeStorageException(NativeStorageError.Corrupt);
        }
        catch (NativeError) { throw new NativeStorageException(NativeStorageError.Corrupt); }
    }

    private static string Endpoint(JsonElement element)
    {
        var endpoint = Text(element, "endpoint", 4096);
        if (endpoint.Length != 0 && NativeEndpoint.Issue(endpoint) is not null) throw new NativeStorageException(NativeStorageError.Corrupt);
        return endpoint;
    }

    protected override NativeProfileHistory Decode(JsonElement record, int schema)
    {
        RequireOnly(record, "profiles", "recentConnections", "historyState");
        var profiles = ImmutableArray.CreateBuilder<NativeConnectionProfile>();
        if (record.TryGetProperty("profiles", out var list))
        {
            if (list.ValueKind != JsonValueKind.Array || list.GetArrayLength() > ProfileCapacity) throw Corrupt();
            foreach (var item in list.EnumerateArray())
            {
                RequireOnly(item, "id", "name", "endpoint", "settings", "sshGateway", "credentialReference");
                if (!Guid.TryParseExact(Text(item, "id", 64), "D", out var id)) throw Corrupt();
                var name = Text(item, "name", 1024);
                if (name.Length == 0) throw Corrupt();
                Guid? credential = null;
                if (item.TryGetProperty("credentialReference", out _))
                    credential = Guid.TryParseExact(Text(item, "credentialReference", 64), "D", out var reference) ? reference : throw Corrupt();
                var settings = item.TryGetProperty("settings", out var value) ? NativeSettings.Decode(value) : NativeSettings.Empty;
                profiles.Add(new NativeConnectionProfile(id, name, Endpoint(item), settings, Gateway(item), credential));
            }
            if (profiles.Select(p => p.Id).Distinct().Count() != profiles.Count) throw Corrupt();
        }
        var recent = ImmutableArray.CreateBuilder<NativeConnectionDestination>();
        if (record.TryGetProperty("recentConnections", out var connections))
        {
            if (connections.ValueKind != JsonValueKind.Array || connections.GetArrayLength() > HistoryCapacity) throw Corrupt();
            foreach (var item in connections.EnumerateArray())
            {
                RequireOnly(item, "endpoint", "sshGateway");
                recent.Add(new NativeConnectionDestination(Endpoint(item), Gateway(item)));
            }
            if (recent.Distinct().Count() != recent.Count) throw Corrupt();
        }
        var state = NativeHistoryState.Uninitialized;
        if (record.TryGetProperty("historyState", out var stateValue))
            state = stateValue.ValueKind == JsonValueKind.String ? stateValue.GetString() switch
            {
                "uninitialized" => NativeHistoryState.Uninitialized,
                "native" => NativeHistoryState.Native,
                "registry" => NativeHistoryState.Registry,
                _ => throw Corrupt(),
            } : throw Corrupt();
        return new NativeProfileHistory(profiles.ToImmutable(), recent.ToImmutable(), state);
    }

    protected override void Encode(Utf8JsonWriter writer, NativeProfileHistory value)
    {
        if (value.Profiles.Length > ProfileCapacity || value.RecentConnections.Length > HistoryCapacity)
            throw new NativeStorageException(NativeStorageError.ResourceLimit);
        writer.WriteStartArray("profiles");
        foreach (var profile in value.Profiles)
        {
            writer.WriteStartObject();
            writer.WriteString("id", profile.Id.ToString("D"));
            writer.WriteString("name", profile.Name);
            writer.WriteString("endpoint", profile.Endpoint);
            writer.WritePropertyName("settings");
            writer.WriteStartObject();
            profile.Settings.Encode(writer);
            writer.WriteEndObject();
            if (profile.SshGateway is { } gateway) writer.WriteString("sshGateway", gateway.CanonicalUri);
            if (profile.CredentialReference is { } reference) writer.WriteString("credentialReference", reference.ToString("D"));
            writer.WriteEndObject();
        }
        writer.WriteEndArray();
        writer.WriteStartArray("recentConnections");
        foreach (var destination in value.RecentConnections)
        {
            writer.WriteStartObject();
            writer.WriteString("endpoint", destination.Endpoint);
            if (destination.SshGateway is { } gateway) writer.WriteString("sshGateway", gateway.CanonicalUri);
            writer.WriteEndObject();
        }
        writer.WriteEndArray();
        writer.WriteString("historyState", value.HistoryState switch
        {
            NativeHistoryState.Native => "native",
            NativeHistoryState.Registry => "registry",
            _ => "uninitialized",
        });
    }
}

/// <summary>A window's last placement in physical virtual-screen pixels, and the display it was on.</summary>
public sealed record NativeWindowPlacement(int X, int Y, int Width, int Height, bool Maximized, string? Display);

/// <summary>
/// window-state.json: window placement and the connection window's chrome, kept apart from settings.
/// Schema 2 adds <see cref="NativeWindowState.StatusBarHidden"/>; schema 1 records read as a visible status bar.
/// </summary>
public sealed record NativeWindowState(ImmutableSortedDictionary<string, NativeWindowPlacement> Windows, bool StatusBarHidden = false)
{
    public static NativeWindowState Empty { get; } = new(ImmutableSortedDictionary.Create<string, NativeWindowPlacement>(StringComparer.Ordinal));
}

public sealed class NativeWindowStateStore(string directory) : NativeRecordStore<NativeWindowState>(directory, "window-state.json")
{
    public NativeWindowStateStore() : this(NativeStateRoot.Directory) { }
    protected override int Schema => 2;
    protected override int MaximumBytes => 256 * 1024;
    protected override NativeWindowState Empty => NativeWindowState.Empty;

    protected override NativeWindowState Decode(JsonElement record, int schema)
    {
        if (schema >= 2) RequireOnly(record, "windows", "statusBar");
        else RequireOnly(record, "windows");
        var hidden = false;
        if (record.TryGetProperty("statusBar", out var statusBar))
            hidden = statusBar.ValueKind is JsonValueKind.True or JsonValueKind.False ? !statusBar.GetBoolean() : throw Corrupt();
        var builder = ImmutableSortedDictionary.CreateBuilder<string, NativeWindowPlacement>(StringComparer.Ordinal);
        if (!record.TryGetProperty("windows", out var windows)) return new(builder.ToImmutable(), hidden);
        if (windows.ValueKind != JsonValueKind.Object) throw Corrupt();
        foreach (var window in windows.EnumerateObject())
        {
            if (builder.Count >= 256 || window.Name.Length is 0 or > 128) throw Corrupt();
            var item = window.Value;
            RequireOnly(item, "x", "y", "width", "height", "maximized", "display");
            int Number(string name) => item.TryGetProperty(name, out var value) && value.TryGetInt32(out var number) ? number : throw Corrupt();
            var width = Number("width");
            var height = Number("height");
            if (width is <= 0 or > 65535 || height is <= 0 or > 65535) throw Corrupt();
            var maximized = item.TryGetProperty("maximized", out var flag) && flag.ValueKind is JsonValueKind.True or JsonValueKind.False
                ? flag.GetBoolean() : throw Corrupt();
            string? display = null;
            if (item.TryGetProperty("display", out var id))
                display = id.ValueKind == JsonValueKind.String && id.GetString() is { Length: > 0 and <= 64 } text ? text : throw Corrupt();
            builder[window.Name] = new NativeWindowPlacement(Number("x"), Number("y"), width, height, maximized, display);
        }
        return new(builder.ToImmutable(), hidden);
    }

    protected override void Encode(Utf8JsonWriter writer, NativeWindowState value)
    {
        if (value.StatusBarHidden) writer.WriteBoolean("statusBar", false);
        writer.WriteStartObject("windows");
        foreach (var (key, placement) in value.Windows)
        {
            writer.WriteStartObject(key);
            writer.WriteNumber("x", placement.X); writer.WriteNumber("y", placement.Y);
            writer.WriteNumber("width", placement.Width); writer.WriteNumber("height", placement.Height);
            writer.WriteBoolean("maximized", placement.Maximized);
            if (placement.Display is { } display) writer.WriteString("display", display);
            writer.WriteEndObject();
        }
        writer.WriteEndObject();
    }
}
