// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Collections.Immutable;
using CommunityToolkit.Mvvm.ComponentModel;
using TidyVNC.Native.Storage;
using TidyVNC.Native.Tunnel;

namespace TidyVNC.Native;

/// <summary>
/// Saved profiles (macOS NativeProfileLibrary; PARITY P07, P08, C10): one
/// app-owned editor over profiles-history.json. The store revision covers
/// profiles and recent history, so a stale draft never silently overwrites
/// either. A profile's settings inherit the application defaults, which are
/// read with it. UI thread only.
/// </summary>
public sealed partial class NativeProfileLibrary : ObservableObject, INativeSettingsEditor
{
    private readonly NativeProfileHistoryStore store;
    private readonly NativePreferencesStore preferences;
    private NativeConnectionProfile? baseline;
    private Guid? revision;
    private NativeSettings defaults = NativeSettings.Empty;
    private Task? operation;
    private bool stopped;

    [ObservableProperty] public partial ImmutableArray<NativeConnectionProfile> Profiles { get; private set; } = [];
    [ObservableProperty] public partial NativeConnectionProfile? Draft { get; private set; }
    [ObservableProperty] public partial string GatewayText { get; set; } = "";
    [ObservableProperty] public partial bool IsBusy { get; private set; }
    [ObservableProperty] public partial bool HasLoaded { get; private set; }
    [ObservableProperty] public partial bool NeedsReload { get; private set; }
    [ObservableProperty] public partial NativeStorageError? Error { get; private set; }
    [ObservableProperty] public partial NativePreferencesProblem? Problem { get; private set; }

    public NativeProfileLibrary(NativeProfileHistoryStore store, NativePreferencesStore preferences)
    {
        this.store = store; this.preferences = preferences;
        PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(Draft) or nameof(GatewayText) or nameof(IsBusy) or nameof(HasLoaded) or nameof(NeedsReload))
            {
                OnPropertyChanged(nameof(Values)); OnPropertyChanged(nameof(HasChanges)); OnPropertyChanged(nameof(CanEdit));
                OnPropertyChanged(nameof(CanSave)); OnPropertyChanged(nameof(CanUse)); OnPropertyChanged(nameof(EndpointIssue));
                OnPropertyChanged(nameof(GatewayIssue));
            }
        };
    }

    public NativeSettings Values => Draft?.Settings ?? NativeSettings.Empty;
    public NativeOptionSource OverrideSource => NativeOptionSource.Profile;

    /// <summary>Unset profile values inherit the app defaults, then the built-in values.</summary>
    public (string Value, NativeOptionSource Source) Inherited(string name) =>
        defaults.Parameters.TryGetValue(name, out var value) ? (value, NativeOptionSource.AppDefaults)
            : (NativePreferencesDraft.BuiltIn.GetValueOrDefault(name, ""), NativeOptionSource.Compiled);

    public IReadOnlyList<string> InheritedFullscreenDisplays => defaults.FullscreenDisplays;

    public bool HasChanges => Draft != baseline || GatewayText != (baseline?.SshGateway?.CanonicalUri ?? "");
    public bool CanEdit => !stopped && !IsBusy && HasLoaded && !NeedsReload && Draft is not null;

    public NativeEndpointIssue? EndpointIssue => Draft is null ? null : NativeEndpoint.Issue(Draft.Endpoint);

    /// <summary>Why the gateway cannot be used with this address (the connection window's rule), or null.</summary>
    public NativeText? GatewayIssue
    {
        get
        {
            if (GatewayText.Length == 0) return null;
            try { _ = NativeSshGateway.Parse(GatewayText); }
            catch (NativeError) { return NativeTunnelTexts.InvalidRequest; }
            return EndpointIssue is null && Draft is not null && !NativeSessionSetup.IsTunnelTarget(Draft.Endpoint) ? NativeTunnelTexts.UnsupportedTarget : null;
        }
    }

    public bool CanSave => CanEdit && HasChanges && GatewayIssue is null && EndpointIssue is null && Draft is { } draft &&
                           draft.Name.Trim().Length != 0 && !draft.Name.Contains('\0', StringComparison.Ordinal) &&
                           System.Text.Encoding.UTF8.GetByteCount(draft.Name) <= 256;

    /// <summary>A saved, unedited profile can be connected to or deleted.</summary>
    public bool CanUse => !stopped && !IsBusy && HasLoaded && !NeedsReload && !HasChanges && baseline is not null;

    /// <summary>An explicit reload discards the draft only after both reads succeed.</summary>
    public void Reload()
    {
        if (stopped || operation is not null) return;
        IsBusy = true; Error = null; Problem = null;
        operation = ReloadAsync(Draft?.Id);
    }

    private async Task ReloadAsync(Guid? selection)
    {
        try
        {
            var snapshot = await store.ReadAsync();
            var saved = await preferences.ReadAsync();
            if (!stopped)
            {
                defaults = saved.Value.Settings;
                Profiles = snapshot.Value.Profiles; revision = snapshot.Revision;
                baseline = Profiles.FirstOrDefault(p => p.Id == selection);
                Draft = baseline; GatewayText = baseline?.SshGateway?.CanonicalUri ?? "";
                HasLoaded = true; NeedsReload = false;
            }
        }
        catch (NativeStorageException error)
        {
            if (!stopped) { Error = error.Error; Profiles = []; HasLoaded = false; NeedsReload = true; }
        }
        IsBusy = false; operation = null;
    }

    /// <summary>Reloads unless there are edits (the window was activated again).</summary>
    public void RefreshIfClean()
    {
        if (!NeedsReload && !HasChanges && !IsBusy) Reload();
    }

    public void Select(Guid id)
    {
        if (stopped || IsBusy || !HasLoaded || NeedsReload || HasChanges || Profiles.FirstOrDefault(p => p.Id == id) is not { } value) return;
        baseline = value; Draft = value; GatewayText = value.SshGateway?.CanonicalUri ?? ""; Error = null; Problem = null;
    }

    public void NewProfile()
    {
        if (stopped || IsBusy || !HasLoaded || NeedsReload || HasChanges || Profiles.Length >= NativeProfileHistoryStore.ProfileCapacity) return;
        baseline = null;
        Draft = new NativeConnectionProfile(Guid.NewGuid(), "", "", NativeSettings.Empty, null, null);
        GatewayText = ""; Error = null; Problem = null;
    }

    public void SetName(string name)
    {
        if (CanEdit && Draft is { } draft) Draft = draft with { Name = name };
    }

    public void SetEndpoint(string endpoint)
    {
        if (CanEdit && Draft is { } draft) Draft = draft with { Endpoint = endpoint };
    }

    public bool Set(params (string Name, string? Value)[] changes)
    {
        if (!CanEdit || Draft is not { } draft) return false;
        var parameters = draft.Settings.Parameters.ToDictionary(StringComparer.Ordinal);
        foreach (var (name, value) in changes)
        {
            if (!NativeSettings.Allowed.Contains(name)) throw new ArgumentException($"{name} is not a stored setting", nameof(changes));
            if (value is null) parameters.Remove(name);
            else parameters[name] = value;
        }
        try
        {
            Draft = draft with { Settings = NativeSettings.Create(parameters, draft.Settings.FullscreenDisplays) };
            Problem = null;
            return true;
        }
        catch (Exception error) when (error is ArgumentException or NativeConfigFailure or NativeError)
        {
            Problem = changes.Any(c => c.Name == "GnuTLSPriority" && c.Value is { Length: > 0 })
                ? NativePreferencesProblem.InvalidPriority : NativePreferencesProblem.InvalidValue;
            return false;
        }
    }

    public bool SetFullscreenDisplays(IEnumerable<string> displays)
    {
        if (!CanEdit || Draft is not { } draft) return false;
        try
        {
            Draft = draft with { Settings = NativeSettings.Create(draft.Settings.Parameters, displays.Order(StringComparer.Ordinal)) };
            Problem = null;
            return true;
        }
        catch (ArgumentException)
        {
            Problem = NativePreferencesProblem.InvalidValue;
            return false;
        }
    }

    public void CancelEdits()
    {
        if (IsBusy || stopped) return;
        Draft = baseline; GatewayText = baseline?.SshGateway?.CanonicalUri ?? ""; Problem = null;
        if (!NeedsReload) Error = null;
    }

    public void Save()
    {
        if (!CanSave || Draft is not { } draft) return;
        var submitted = draft with { Name = draft.Name.Trim(), SshGateway = GatewayText.Length == 0 ? null : NativeSshGateway.Parse(GatewayText) };
        Mutate(submitted.Id, expected => store.UpsertProfileAsync(submitted, expected));
    }

    public void DeleteSelected()
    {
        if (!CanUse || baseline is not { } selected) return;
        Mutate(null, expected => store.DeleteProfileAsync(selected.Id, expected));
    }

    private void Mutate(Guid? selection, Func<Guid?, Task<NativeRecordSnapshot<NativeProfileHistory>>> action)
    {
        IsBusy = true; Error = null; Problem = null;
        operation = Run();
        async Task Run()
        {
            try
            {
                var result = await action(revision);
                if (!stopped)
                {
                    Profiles = result.Value.Profiles; revision = result.Revision;
                    baseline = Profiles.FirstOrDefault(p => p.Id == selection);
                    Draft = baseline; GatewayText = baseline?.SshGateway?.CanonicalUri ?? "";
                }
            }
            catch (NativeStorageException error)
            {
                // Uncertain or refused commits need a reload before anything else is written.
                if (!stopped) { Error = error.Error; NeedsReload = error.Error != NativeStorageError.Invalid; }
            }
            IsBusy = false; operation = null;
        }
    }

    public void Stop() => stopped = true;

    public async Task CloseAsync()
    {
        Stop();
        if (operation is { } running) await running;
    }
}
