// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Immutable;
using CommunityToolkit.Mvvm.ComponentModel;
using TidyVNC.Native.Storage;

namespace TidyVNC.Native;

/// <summary>
/// A settings patch being edited: the application defaults (Settings) or a
/// saved profile's settings (Saved profiles). The same fields edit both; only
/// what an unset value inherits differs.
/// </summary>
public interface INativeSettingsEditor : System.ComponentModel.INotifyPropertyChanged
{
    NativeSettings Values { get; }
    bool CanEdit { get; }
    /// <summary>Where this patch's own values come from (app defaults or profile).</summary>
    NativeOptionSource OverrideSource { get; }
    /// <summary>The value used when this patch does not set one, and where it comes from.</summary>
    (string Value, NativeOptionSource Source) Inherited(string name);
    /// <summary>The display selection used when this patch has none.</summary>
    IReadOnlyList<string> InheritedFullscreenDisplays { get; }
    bool Set(params (string Name, string? Value)[] changes);
    bool SetFullscreenDisplays(IEnumerable<string> displays);
}

public static class NativeSettingsEditors
{
    public static string? Get(this INativeSettingsEditor editor, string name) => editor.Values.Parameters.GetValueOrDefault(name);
    public static string Effective(this INativeSettingsEditor editor, string name) => editor.Get(name) ?? editor.Inherited(name).Value;
    public static NativeOptionSource Source(this INativeSettingsEditor editor, string name) =>
        editor.Get(name) is null ? editor.Inherited(name).Source : editor.OverrideSource;
    public static bool Set(this INativeSettingsEditor editor, string name, string? value) => editor.Set((name, value));
}

/// <summary>Why an edit or Apply was refused without touching the store.</summary>
public enum NativePreferencesProblem { InvalidValue, InvalidPriority }

/// <summary>
/// The Settings window's draft of the application defaults (macOS
/// NativePreferencesDraft; PARITY P02-P05, P09). Edits are canonical
/// parameter values checked by the core as they are made; unset parameters
/// inherit the built-in defaults. Apply commits against the revision that was
/// read, so another TidyVNC process's save is a conflict that needs a
/// reload, never an overwrite. Existing connections are not affected.
/// UI thread only.
/// </summary>
public sealed partial class NativePreferencesDraft : ObservableObject, INativeSettingsEditor
{
    private static readonly Lazy<ImmutableSortedDictionary<string, string>> Compiled = new(CompiledDefaults);

    /// <summary>
    /// Every stored parameter's built-in value, as the canonical text the
    /// core writes: the typed defaults of a new session configuration (as
    /// macOS uses NativeSessionConfiguration()), the core's compiled encoding
    /// options and security selection.
    /// </summary>
    private static ImmutableSortedDictionary<string, string> CompiledDefaults()
    {
        static string Flag(bool value) => value ? "on" : "off";
        var configuration = new NativeSessionConfiguration();
        var input = NativeInputSettings.BuiltIn;
        var scaling = NativeScaling.BuiltIn;
        var values = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["SendClipboard"] = Flag(configuration.ClipboardSend), ["AcceptClipboard"] = Flag(configuration.ClipboardReceive),
            ["Shared"] = Flag(configuration.Shared), ["ReconnectOnError"] = Flag(configuration.ReconnectOnError),
            ["FullScreen"] = Flag(configuration.FullscreenPolicy.StartsFullscreen),
            ["FullScreenMode"] = NativeFullscreenPolicy.Canonical(configuration.FullscreenPolicy.Mode),
            ["RemoteResize"] = Flag(configuration.ResizePolicy.Enabled), ["DesktopSize"] = configuration.ResizePolicy.InitialSize,
            ["SecurityTypes"] = new NativeSecuritySelection().Canonical, ["GnuTLSPriority"] = configuration.TlsPriority,
            ["X509CA"] = "", ["X509CRL"] = "",
            ["ScalingFactor"] = scaling.Canonical, ["ScalingQuality"] = scaling.Filter.Canonical(),
            ["DesktopPixelUnits"] = scaling.DevicePixels ? "Device" : "Logical",
            ["ViewOnly"] = Flag(input.ViewOnly), ["EmulateMiddleButton"] = Flag(input.EmulateMiddle),
            ["FullscreenSystemKeys"] = Flag(input.FullscreenSystemKeys),
            ["ShortcutModifiers"] = NativeInputSettings.Canonical(input.ShortcutModifiers),
            ["AlwaysCursor"] = Flag(input.CursorFallback != NativeCursorFallback.Hidden),
            ["CursorType"] = input.CursorFallback == NativeCursorFallback.System ? "System" : "Dot",
        };
        using var encoding = new NativeEncodingOptions();
        foreach (var field in NativeEncodingOptions.Schema())
            if (NativeSettings.Allowed.Contains(field.Name)) values[field.Name] = encoding.Value(field.Id).Value;
        return values.ToImmutableSortedDictionary(StringComparer.Ordinal);
    }

    private readonly NativePreferencesStore store;
    private Task? operation;
    private bool stopped;

    [ObservableProperty] public partial NativeSettings Values { get; private set; } = NativeSettings.Empty;
    [ObservableProperty] public partial NativeRecordSnapshot<NativePreferencesRecord>? Snapshot { get; private set; }
    [ObservableProperty] public partial bool IsBusy { get; private set; }
    [ObservableProperty] public partial bool NeedsReload { get; private set; }
    [ObservableProperty] public partial NativeStorageError? Error { get; private set; }
    [ObservableProperty] public partial NativePreferencesProblem? Problem { get; private set; }
    [ObservableProperty] public partial bool DidApply { get; private set; }

    public NativePreferencesDraft(NativePreferencesStore store)
    {
        this.store = store;
        PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(Values) or nameof(Snapshot) or nameof(IsBusy) or nameof(NeedsReload))
            {
                OnPropertyChanged(nameof(HasChanges)); OnPropertyChanged(nameof(CanApply)); OnPropertyChanged(nameof(CanEdit));
            }
        };
    }

    /// <summary>The built-in value of every stored parameter (the core's compiled defaults).</summary>
    public static IReadOnlyDictionary<string, string> BuiltIn => Compiled.Value;

    public bool HasChanges => Snapshot is { } snapshot && !Values.Equals(snapshot.Value.Settings);
    public bool CanEdit => !stopped && !IsBusy && !NeedsReload && Snapshot is not null;
    public bool CanApply => CanEdit && HasChanges;

    public NativeOptionSource OverrideSource => NativeOptionSource.AppDefaults;
    public (string Value, NativeOptionSource Source) Inherited(string name) => (BuiltIn.GetValueOrDefault(name, ""), NativeOptionSource.Compiled);
    public IReadOnlyList<string> InheritedFullscreenDisplays => [];

    /// <summary>The app default for a parameter, or null when it inherits the built-in value.</summary>
    public string? Get(string name) => Values.Parameters.GetValueOrDefault(name);

    /// <summary>The value new connections start from.</summary>
    public string Effective(string name) => Get(name) ?? BuiltIn.GetValueOrDefault(name, "");

    /// <summary>Sets (or, with null, clears) parameters together; refused values leave the draft unchanged.</summary>
    public bool Set(params (string Name, string? Value)[] changes)
    {
        if (!CanEdit) return false;
        var parameters = Values.Parameters.ToDictionary(StringComparer.Ordinal);
        foreach (var (name, value) in changes)
        {
            if (!NativeSettings.Allowed.Contains(name)) throw new ArgumentException($"{name} is not a stored setting", nameof(changes));
            if (value is null) parameters.Remove(name);
            else parameters[name] = value;
        }
        try
        {
            Values = NativeSettings.Create(parameters, Values.FullscreenDisplays);
            Problem = null; DidApply = false;
            return true;
        }
        catch (Exception error) when (error is ArgumentException or NativeConfigFailure or NativeError)
        {
            // The core runs the bounded GnuTLS preflight on a priority as it resolves it.
            Problem = changes.Any(c => c.Name == "GnuTLSPriority" && c.Value is { Length: > 0 })
                ? NativePreferencesProblem.InvalidPriority : NativePreferencesProblem.InvalidValue;
            return false;
        }
    }

    public bool Set(string name, string? value) => Set((name, value));

    /// <summary>The saved full-screen display selection (stable display IDs).</summary>
    public bool SetFullscreenDisplays(IEnumerable<string> displays)
    {
        if (!CanEdit) return false;
        try
        {
            Values = NativeSettings.Create(Values.Parameters, displays.Order(StringComparer.Ordinal));
            Problem = null; DidApply = false;
            return true;
        }
        catch (ArgumentException)
        {
            Problem = NativePreferencesProblem.InvalidValue;
            return false;
        }
    }

    public void Reload()
    {
        if (stopped || operation is not null) return;
        IsBusy = true; Error = null; Problem = null; DidApply = false;
        operation = ReloadAsync();
    }

    private async Task ReloadAsync()
    {
        try
        {
            var result = await store.ReadAsync();
            if (!stopped)
            {
                Snapshot = result; Values = result.Value.Settings; NeedsReload = false;
            }
        }
        catch (NativeStorageException error)
        {
            if (!stopped) { Error = error.Error; NeedsReload = true; }
        }
        IsBusy = false; operation = null;
    }

    public void Apply()
    {
        if (!CanApply || Snapshot is not { } snapshot) return;
        IsBusy = true; Error = null; Problem = null; DidApply = false;
        operation = ApplyAsync(snapshot, Values);
    }

    private async Task ApplyAsync(NativeRecordSnapshot<NativePreferencesRecord> snapshot, NativeSettings submitted)
    {
        try
        {
            var result = await store.CommitAsync(snapshot.Value with { Settings = submitted }, snapshot.Revision);
            // An accepted commit is a commit even if the window closed meanwhile.
            if (!stopped)
            {
                Snapshot = result; NeedsReload = false; DidApply = true;
                if (Values.Equals(submitted)) Values = result.Value.Settings;
            }
        }
        catch (NativeStorageException error)
        {
            // Including uncertain writes: never retry an old draft or revision blindly.
            if (!stopped) { Error = error.Error; NeedsReload = true; }
        }
        finally
        {
            IsBusy = false; operation = null;
        }
    }

    /// <summary>Cancel edits: back to what was read. A conflicted or unreadable store stays that way.</summary>
    public void Cancel()
    {
        if (IsBusy) return;
        if (Snapshot is { } snapshot) Values = snapshot.Value.Settings;
        Problem = null;
        if (!NeedsReload) Error = null;
    }

    /// <summary>Only a draft until Apply.</summary>
    public void RestoreBuiltInDefaults()
    {
        if (!CanEdit) return;
        Values = NativeSettings.Empty;
        Problem = null; DidApply = false;
    }

    public void Stop() => stopped = true;

    public async Task CloseAsync()
    {
        Stop();
        if (operation is { } running) await running;
    }
}
