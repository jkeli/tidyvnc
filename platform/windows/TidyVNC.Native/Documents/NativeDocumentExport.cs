// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Trust;

namespace TidyVNC.Native.Documents;

public enum NativeExportProblem
{
    /// <summary>A custom TLS priority cannot be carried by the file format; a native profile keeps it.</summary>
    SecurityPolicy,
    /// <summary>Selected displays have no monitor number in the current arrangement.</summary>
    DisplayMapping,
    /// <summary>A setting cannot be represented in the file.</summary>
    InvalidConfiguration,
    /// <summary>Losses were not acknowledged.</summary>
    ReviewRequired,
}

public sealed class NativeExportFailure(NativeExportProblem problem) : Exception($"Connection export: {problem}")
{
    public NativeExportProblem Problem { get; } = problem;
}

/// <summary>A value snapshot of one connection's settings, taken before any UI appears.</summary>
public sealed record NativeExportSource(
    string Endpoint, bool Shared, bool ReconnectOnError, bool ClipboardSend, bool ClipboardReceive, NativeEncodingOptions Encoding,
    NativeInputSettings Input, NativeCursorFallback InactiveCursor, NativeScaling Scaling, NativeFullscreenPolicy Fullscreen,
    string SecurityTypes, string TlsPriority, string CaFile, string CrlFile, bool IgnoredInput, bool SshGateway);

/// <summary>
/// Save connection file as (macOS NativeDocumentExport; PARITY F05-F07): a
/// preflighted, non-secret compatibility file of the current settings. The
/// core decides the losses the review must show (W2 export-loss rules); a
/// custom TLS priority refuses the export; stable display IDs become the
/// monitor numbers of the current arrangement. Every emitted field is read
/// back through the shared file decoder before the export is offered.
/// Passwords and trust decisions are never written.
/// </summary>
public sealed class NativeDocumentExport
{
    private readonly byte[] data;

    public NativeExportLoss Losses { get; }
    public string Endpoint { get; }
    /// <summary>Display ID to exported monitor number.</summary>
    public IReadOnlyDictionary<string, int> MonitorIndices { get; }

    private NativeDocumentExport(byte[] data, NativeExportLoss losses, string endpoint, IReadOnlyDictionary<string, int> indices)
    {
        this.data = data; Losses = losses; Endpoint = endpoint; MonitorIndices = indices;
    }

    /// <summary>The file, only once every loss has been acknowledged.</summary>
    public byte[] Data(NativeExportLoss acknowledged) =>
        (Losses & ~acknowledged) == 0 ? data : throw new NativeExportFailure(NativeExportProblem.ReviewRequired);

    /// <param name="legacyDisplays">Connected displays in the retained monitor numbering.</param>
    /// <param name="monitorIndices">
    /// Numbers the user chose for every selected display (<see cref="NativeExportMapping"/>),
    /// or null to number them from the current arrangement.
    /// </param>
    public static NativeDocumentExport Create(NativeExportSource source, IReadOnlyList<string> legacyDisplays,
                                              IReadOnlyDictionary<string, int>? monitorIndices = null)
    {
        NativeExportLoss losses;
        try
        {
            losses = NativeExportLosses.For(!source.Fullscreen.SelectedDisplays.IsEmpty, source.IgnoredInput, source.SshGateway, source.TlsPriority);
        }
        catch (NativeExportRefused) { throw new NativeExportFailure(NativeExportProblem.SecurityPolicy); }
        if (source.InactiveCursor is not (NativeCursorFallback.Dot or NativeCursorFallback.System) ||
            ((uint)source.Input.ShortcutModifiers & ~15u) != 0 ||
            (source.CaFile.Length != 0 && !NativeTrustFiles.IsValidPath(source.CaFile)) ||
            (source.CrlFile.Length != 0 && !NativeTrustFiles.IsValidPath(source.CrlFile)))
            throw new NativeExportFailure(NativeExportProblem.InvalidConfiguration);
        if (source.Endpoint.Length != 0)
        {
            try { NativeEndpoint.Validate(source.Endpoint); }
            catch (NativeError) { throw new NativeExportFailure(NativeExportProblem.InvalidConfiguration); }
        }

        var fields = new List<NativeDocumentAssignment>();
        void Add(string name, string value) => fields.Add(new NativeDocumentAssignment(name, value));
        void Flag(string name, bool value) => Add(name, value ? "on" : "off");
        Add("ServerName", source.Endpoint);
        Add("SecurityTypes", source.SecurityTypes);
        Add("X509CA", source.CaFile); Add("X509CRL", source.CrlFile);
        Flag("Shared", source.Shared); Flag("ReconnectOnError", source.ReconnectOnError);
        Flag("SendClipboard", source.ClipboardSend); Flag("AcceptClipboard", source.ClipboardReceive);
        foreach (var field in NativeEncodingOptions.Schema().Where(f => f.Persistent)) Add(field.Name, source.Encoding.Value(field.Id).Value);
        var input = source.Input;
        Flag("ViewOnly", input.ViewOnly); Flag("EmulateMiddleButton", input.EmulateMiddle); Flag("FullscreenSystemKeys", input.FullscreenSystemKeys);
        Add("ShortcutModifiers", NativeInputSettings.Canonical(input.ShortcutModifiers));
        Flag("AlwaysCursor", input.CursorFallback != NativeCursorFallback.Hidden);
        var shape = input.CursorFallback == NativeCursorFallback.Hidden ? source.InactiveCursor : input.CursorFallback;
        Add("CursorType", shape == NativeCursorFallback.System ? "System" : "Dot");
        Add("ScalingFactor", source.Scaling.Canonical); Add("ScalingQuality", source.Scaling.Filter.Canonical());
        Add("DesktopPixelUnits", source.Scaling.DevicePixels ? "Device" : "Logical");
        var fullscreen = source.Fullscreen;
        Flag("FullScreen", fullscreen.StartsFullscreen);
        Add("FullScreenMode", NativeFullscreenPolicy.Canonical(fullscreen.Mode));
        var indices = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var id in fullscreen.SelectedDisplays)
        {
            var index = monitorIndices is null ? legacyDisplays.ToList().IndexOf(id) + 1 : monitorIndices.GetValueOrDefault(id);
            if (index <= 0) throw new NativeExportFailure(NativeExportProblem.DisplayMapping);
            indices[id] = index;
        }
        if (monitorIndices is not null && (monitorIndices.Count != indices.Count || indices.Values.Distinct().Count() != indices.Count))
            throw new NativeExportFailure(NativeExportProblem.DisplayMapping);
        Add("FullScreenSelectedMonitors", string.Join(',', indices.Values.Order()));

        byte[] bytes;
        try
        {
            bytes = NativeConnectionDocument.Serialize(fields);
            // Every emitted field must pass the shared file semantics, not only the syntax.
            using var parsed = new NativeConnectionDocument(bytes);
            for (var i = 0; i < parsed.Entries.Count; i++)
                if (parsed.ValidatedOption(i) is null) throw new NativeExportFailure(NativeExportProblem.InvalidConfiguration);
        }
        catch (Exception error) when (error is NativeDocumentFailure or NativeError)
        {
            throw new NativeExportFailure(NativeExportProblem.InvalidConfiguration);
        }
        return new NativeDocumentExport(bytes, losses, source.Endpoint, indices);
    }
}

/// <summary>
/// Exported monitor numbers chosen by the user (macOS NativeDocumentExportMapping):
/// offered when a selected display has no number in the current arrangement,
/// or to renumber for the receiving computer. Only the file changes; the
/// connection keeps its selected displays.
/// </summary>
public sealed class NativeExportMapping
{
    public Guid Id { get; } = Guid.NewGuid();
    public IReadOnlyList<string> SelectedDisplays { get; }
    public IReadOnlyDictionary<string, int> Suggested { get; }

    public NativeExportMapping(NativeFullscreenPolicy policy, IReadOnlyList<string> legacyDisplays, IReadOnlyDictionary<string, int>? previous = null)
    {
        SelectedDisplays = [.. policy.SelectedDisplays];
        if (previous is not null) { Suggested = previous; return; }
        var suggested = new Dictionary<string, int>(StringComparer.Ordinal);
        if (legacyDisplays.Count <= 64 && legacyDisplays.Distinct(StringComparer.Ordinal).Count() == legacyDisplays.Count)
            foreach (var id in SelectedDisplays)
                if (legacyDisplays.ToList().IndexOf(id) is var index and >= 0) suggested[id] = index + 1;
        Suggested = suggested;
    }

    /// <summary>Distinct positive whole numbers for every selected display, or null.</summary>
    public IReadOnlyDictionary<string, int>? Indices(IReadOnlyDictionary<string, string> text)
    {
        var result = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var id in SelectedDisplays)
        {
            if (!text.TryGetValue(id, out var value)) return null;
            var input = value.Trim();
            if (input.Length is 0 or > 10 || !input.All(char.IsAsciiDigit) || !int.TryParse(input, out var number) || number <= 0) return null;
            result[id] = number;
        }
        return result.Values.Distinct().Count() == result.Count ? result : null;
    }
}
