// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TidyVNC.Native;
using TidyVNC.Native.Documents;
using TidyVNC.Native.Trust;

namespace TidyVNC;

/// <summary>
/// Security method and TLS priority fields shared by the Security dialog,
/// the Settings window and profiles (macOS SecuritySettingsFields and
/// TLSPrioritySettingsFields; PARITY S01-S04).
/// </summary>
internal sealed partial class SecurityFields : UserControl
{
    private readonly Func<NativeSecurityPatch> get;
    private readonly Action<NativeSecurityPatch> set;
    private readonly CheckBox overrideMethods, overridePriority;
    private readonly TextBlock inheritanceText, emptyWarning, invalidError, priorityStatus, priorityInvalid, priorityUnavailable;
    private readonly TextBox priority;
    private readonly Button libraryDefault;
    private readonly StackPanel groups = new() { Spacing = 12 };
    private readonly Dictionary<uint, CheckBox> methods = [];
    private NativeSecuritySelection inherited = new("");
    private IReadOnlyList<NativeSecurityChoice> choices = [];
    private string inheritance = "", inheritedPriority = "";
    private bool updating;

    public SecurityFields(Func<NativeSecurityPatch> get, Action<NativeSecurityPatch> set, string scopeMessage)
    {
        this.get = get;
        this.set = set;
        overridePriority = new CheckBox { Content = Strings.Get("settings.security.override.tls.priority") };
        AutomationProperties.SetAutomationId(overridePriority, "security.priority.override");
        overridePriority.Click += (_, _) => { if (!updating) set(get() with { TlsPriority = overridePriority.IsChecked == true ? inheritedPriority : null }); };
        priority = new TextBox { PlaceholderText = Strings.Get("settings.security.library.default.empty"), IsSpellCheckEnabled = false };
        AutomationProperties.SetAutomationId(priority, "security.priority.expression");
        AutomationProperties.SetName(priority, Strings.Get("settings.security.advanced.tls.priority"));
        priority.TextChanged += (_, _) => { if (!updating && get().TlsPriority is not null) set(get() with { TlsPriority = priority.Text }); };
        libraryDefault = Ui.Button(Strings.Get("settings.security.use.library.default"), (_, _) => set(get() with { TlsPriority = "" }), "security.priority.libraryDefault");
        priorityStatus = Ui.Caption("");
        priorityInvalid = Ui.Text(Strings.Get("settings.security.use.at.most.4096.utf.8.bytes.with.no.nul.characters"));
        priorityInvalid.Foreground = Ui.Error;
        priorityUnavailable = Ui.Caption(Strings.Get("settings.security.custom.tls.priorities.are.unavailable.in.this.build.use.the.library.default"));
        var tls = new Expander
        {
            Header = Strings.Get("settings.security.advanced.tls.priority"), HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = Ui.Stack(8, overridePriority, priority, libraryDefault, priorityStatus,
                Ui.Caption(Strings.Get("settings.security.applies.to.tls.methods.when.connecting.gnutls.expressions.are.checked.on.apply")),
                priorityInvalid, priorityUnavailable),
        };
        AutomationProperties.SetAutomationId(tls, "security.priority");
        overrideMethods = new CheckBox { Content = Strings.Get("settings.security.override.allowed.security.methods") };
        AutomationProperties.SetAutomationId(overrideMethods, "security.override");
        overrideMethods.Click += (_, _) => { if (!updating) set(get() with { Types = overrideMethods.IsChecked == true ? inherited.Canonical : null }); };
        inheritanceText = Ui.Caption("");
        emptyWarning = Ui.Text(Strings.Get("settings.security.no.methods.are.allowed.new.connections.will.be.refused"), "security.empty");
        emptyWarning.Foreground = Ui.Warning;
        invalidError = Ui.Text(Strings.Get("settings.security.the.security.selection.is.invalid.or.unavailable.in.this.build"));
        invalidError.Foreground = Ui.Error;
        Content = Ui.Stack(12, tls, overrideMethods, inheritanceText, Ui.Caption(scopeMessage), emptyWarning, invalidError, groups);
    }

    private static string Title(NativeSecurityChoice.ProtectionKind group) => Strings.Get(group switch
    {
        NativeSecurityChoice.ProtectionKind.Unencrypted => "settings.security.unencrypted.session",
        NativeSecurityChoice.ProtectionKind.AnonymousTls => "settings.security.tls.without.server.identity.verification",
        NativeSecurityChoice.ProtectionKind.X509Tls => "settings.security.tls.with.x509.certificate.verification",
        NativeSecurityChoice.ProtectionKind.RsaAes => "settings.security.rsa.aes.session.encryption",
        NativeSecurityChoice.ProtectionKind.RsaAuthentication => "settings.security.rsa.aes.authentication.only",
        _ => "settings.security.legacy.authentication.only",
    });

    private static string Details(NativeSecurityChoice choice)
    {
        var authentication = Strings.Get(choice.Credentials switch
        {
            NativeSecurityChoice.CredentialKind.None => "settings.security.no.user.authentication",
            NativeSecurityChoice.CredentialKind.Password => "settings.security.vnc.password",
            NativeSecurityChoice.CredentialKind.UsernamePassword => "settings.security.username.and.password",
            _ => "settings.security.server.selects.password.or.username.and.password",
        });
        return choice.AesBits == 0 ? authentication : Strings.Format("settings.security.aes.authentication", choice.AesBits, authentication);
    }

    private void Toggle(NativeSecurityChoice choice, bool enabled)
    {
        var patch = get();
        if (patch.Types is null || !choice.Available || patch.Selection(inherited) is not { } selected) return;
        var tokens = selected.Canonical.Length == 0 ? [] : selected.Canonical.Split(',').ToList();
        tokens.Remove(choice.Name);
        if (enabled) tokens.Add(choice.Name);
        set(patch with { Types = string.Join(',', tokens) });
    }

    public void Refresh(NativeSecuritySelection inheritedSelection, IReadOnlyList<NativeSecurityChoice> catalog, string inheritanceLabel, string priorityInherited, bool enabled)
    {
        updating = true;
        try
        {
            inherited = inheritedSelection; inheritance = inheritanceLabel; inheritedPriority = priorityInherited;
            if (!ReferenceEquals(choices, catalog))
            {
                choices = catalog;
                groups.Children.Clear(); methods.Clear();
                foreach (var group in Enum.GetValues<NativeSecurityChoice.ProtectionKind>())
                {
                    var members = choices.Where(c => c.Protection == group).ToList();
                    if (members.Count == 0) continue;
                    var box = new StackPanel { Spacing = 8 };
                    box.Children.Add(Ui.Heading(Title(group)));
                    if (group is NativeSecurityChoice.ProtectionKind.RsaAuthentication or NativeSecurityChoice.ProtectionKind.LegacyAuthentication)
                        box.Children.Add(Ui.Caption(Strings.Get("settings.security.desktop.traffic.remains.unencrypted")));
                    foreach (var choice in members)
                    {
                        var check = new CheckBox
                        {
                            Content = Ui.Stack(2, Ui.Text(choice.Name),
                                Ui.Caption(choice.Available ? Details(choice) : Strings.Get("settings.security.unavailable.in.this.build"))),
                        };
                        AutomationProperties.SetAutomationId(check, "security.method." + choice.Name);
                        AutomationProperties.SetName(check, choice.Name);
                        var entry = choice;
                        check.Click += (_, _) => { if (!updating) Toggle(entry, check.IsChecked == true); };
                        methods[choice.Id] = check;
                        box.Children.Add(check);
                    }
                    groups.Children.Add(box);
                }
            }
            var patch = get();
            var selected = patch.Selection(inherited);
            overrideMethods.IsChecked = patch.Types is not null;
            overrideMethods.IsEnabled = enabled;
            inheritanceText.Text = patch.Types is null ? inheritance : Strings.Get("settings.security.explicit.selection");
            emptyWarning.Visibility = selected is { Types.Count: 0 } ? Visibility.Visible : Visibility.Collapsed;
            invalidError.Visibility = selected is null ? Visibility.Visible : Visibility.Collapsed;
            foreach (var choice in choices)
            {
                var check = methods[choice.Id];
                check.IsChecked = selected?.Types.Contains(choice.Id) == true;
                check.IsEnabled = enabled && patch.Types is not null && choice.Available && selected is not null;
            }
            var tlsAvailable = choices.Any(c => c.Protection == NativeSecurityChoice.ProtectionKind.X509Tls && c.Available);
            overridePriority.IsChecked = patch.TlsPriority is not null;
            overridePriority.IsEnabled = enabled;
            var text = patch.TlsPriority ?? inheritedPriority;
            if (priority.Text != text) priority.Text = text;
            priority.IsEnabled = enabled && patch.TlsPriority is not null && tlsAvailable;
            libraryDefault.Visibility = patch.TlsPriority is not null ? Visibility.Visible : Visibility.Collapsed;
            libraryDefault.IsEnabled = enabled;
            priorityStatus.Text = patch.TlsPriority is null ? inheritance
                : Strings.Get(patch.TlsPriority.Length == 0 ? "settings.security.library.default" : "settings.security.custom.tls.priority");
            priorityInvalid.Visibility = patch.IsPriorityTextValid ? Visibility.Collapsed : Visibility.Visible;
            priorityUnavailable.Visibility = tlsAvailable ? Visibility.Collapsed : Visibility.Visible;
        }
        finally { updating = false; }
    }
}

/// <summary>CA and CRL file fields (macOS TrustFileSettingsFields; PARITY S05, SERVICES.md section 5).</summary>
internal sealed partial class TrustFileFields : UserControl
{
    private readonly Func<NativeTrustFiles> get;
    private readonly Action<NativeTrustFiles> set;
    private readonly Func<Window?> owner;
    private readonly (CheckBox Override, TextBox Path, Button Choose, Button None, TextBlock Status) ca, crl;
    private NativeTrustFiles inherited = new();
    private string inheritance = "";
    private bool updating;

    public TrustFileFields(Func<NativeTrustFiles> get, Action<NativeTrustFiles> set, Func<Window?> owner, string scopeMessage)
    {
        this.get = get;
        this.set = set;
        this.owner = owner;
        ca = Field("ca", "settings.trustFiles.certificate.authorities", "settings.trustFiles.override.certificate.authorities",
            "settings.trustFiles.choose.certificate.authorities.file", "settings.trustFiles.no.additional.certificate.authorities.file", authorities: true);
        crl = Field("crl", "settings.trustFiles.certificate.revocations", "settings.trustFiles.override.certificate.revocations",
            "settings.trustFiles.choose.certificate.revocations.file", "settings.trustFiles.no.additional.certificate.revocations.file", authorities: false);
        Content = Ui.Stack(12,
            Ui.Caption(Strings.Get("settings.trustFiles.for.x509.tls.connections.a.ca.file.adds.certificate.authorities.to.system")),
            Group(ca), Group(crl),
            Ui.Caption(Strings.Get("settings.trustFiles.selected.files.are.read.at.each.connection.attempt.if.a.file.cannot")),
            Ui.Caption(scopeMessage));
    }

    private static StackPanel Group((CheckBox Override, TextBox Path, Button Choose, Button None, TextBlock Status) field)
    {
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttons.Children.Add(field.Choose);
        buttons.Children.Add(field.None);
        return Ui.Stack(6, field.Override, field.Path, buttons, field.Status);
    }

    private static string? Value(NativeTrustFiles files, bool authorities) => authorities ? files.CaFile : files.CrlFile;
    private static NativeTrustFiles With(NativeTrustFiles files, bool authorities, string? value) =>
        authorities ? files with { CaFile = value } : files with { CrlFile = value };

    private (CheckBox, TextBox, Button, Button, TextBlock) Field(string id, string title, string overrideKey, string chooseKey, string noneKey, bool authorities)
    {
        var toggle = new CheckBox { Content = Strings.Get(overrideKey) };
        AutomationProperties.SetAutomationId(toggle, "trustFiles.override." + id);
        toggle.Click += (_, _) =>
        {
            if (!updating) set(With(get(), authorities, toggle.IsChecked == true ? Value(inherited, authorities) ?? "" : null));
        };
        var path = new TextBox { IsSpellCheckEnabled = false };
        AutomationProperties.SetAutomationId(path, "trustFiles.path." + id);
        AutomationProperties.SetName(path, Strings.Get(title));
        path.TextChanged += (_, _) => { if (!updating && Value(get(), authorities) is not null) set(With(get(), authorities, path.Text)); };
        var choose = Ui.Button(Strings.Get("settings.trustFiles.choose"), (_, _) =>
        {
            var submitted = get();
            var window = owner();
            if (window is null) return;
            string? selected;
            try
            {
                selected = NativeFileDialogs.Show(WinRT.Interop.WindowNative.GetWindowHandle(window), NativeFileDialogKind.OpenCertificate,
                    new NativeFileDialogText(Strings.Get(title), CertificateFiles: Strings.Get("document.files.certificates"), AllFiles: Strings.Get("document.files.all")));
            }
            catch (InvalidOperationException) { return; }
            // Apply only to the unchanged draft that asked (the macOS fileImporter context rule).
            if (selected is not null && NativeTrustFiles.IsValidPath(selected) && Equals(get(), submitted)) set(With(get(), authorities, selected));
        });
        AutomationProperties.SetName(choose, Strings.Get(chooseKey));
        var none = Ui.Button(Strings.Get("settings.trustFiles.none"), (_, _) => set(With(get(), authorities, "")));
        AutomationProperties.SetName(none, Strings.Get(noneKey));
        var status = Ui.Caption("");
        return (toggle, path, choose, none, status);
    }

    public void Refresh(NativeTrustFiles inheritedFiles, string inheritanceLabel, bool enabled)
    {
        updating = true;
        try
        {
            inherited = inheritedFiles; inheritance = inheritanceLabel;
            var files = get();
            foreach (var (field, authorities) in new[] { (ca, true), (crl, false) })
            {
                var value = Value(files, authorities);
                field.Override.IsChecked = value is not null;
                field.Override.IsEnabled = enabled;
                var text = value ?? Value(inherited, authorities) ?? "";
                if (field.Path.Text != text) field.Path.Text = text;
                field.Path.IsEnabled = field.Choose.IsEnabled = field.None.IsEnabled = enabled && value is not null;
                if (value is not null && !NativeTrustFiles.IsValidPath(value))
                {
                    field.Status.Text = Strings.Get("settings.trustFiles.enter.a.valid.full.file.path.or.leave.it.empty.for.no");
                    field.Status.Foreground = Ui.Error;
                }
                else
                {
                    field.Status.Foreground = Ui.Secondary;
                    field.Status.Text = value is null
                        ? Strings.Format("settings.trustFiles.inherited.status", inheritance, Strings.Get(string.IsNullOrEmpty(Value(inherited, authorities))
                            ? "settings.trustFiles.no.additional.file" : "settings.trustFiles.selected.file"))
                        : Strings.Get(value.Length == 0 ? "settings.trustFiles.no.additional.file.title" : "settings.trustFiles.selected.file.title");
                }
            }
        }
        finally { updating = false; }
    }
}

/// <summary>Security for the next connection (macOS SessionSecuritySheet; PARITY S06-S07).</summary>
internal static class SecurityDialog
{
    public static NativeText Message(NativeSecurityDraftError error) => new(error switch
    {
        NativeSecurityDraftError.Unavailable => "settings.security.security.settings.are.unavailable.disconnect.then.reload",
        NativeSecurityDraftError.InvalidPriority => "settings.security.the.tls.priority.expression.is.invalid.correct.it.or.use.the.library",
        NativeSecurityDraftError.InvalidValue => "settings.security.a.security.setting.is.invalid.or.unavailable.in.this.build",
        NativeSecurityDraftError.UnsupportedValue => "settings.security.a.security.setting.is.unavailable.in.this.build.correct.it.before.applying",
        NativeSecurityDraftError.Cancelled => "settings.security.applying.security.settings.was.cancelled",
        NativeSecurityDraftError.ConnectionChanged => "settings.security.the.connection.changed.reload.security.settings.before.applying",
        _ => "settings.security.the.connection.or.security.settings.changed.reload.before.applying",
    });

    public static string SourceLabel(NativeOptionSource source) => Strings.Get(source switch
    {
        NativeOptionSource.Compiled => "settings.connection.built.in.default",
        NativeOptionSource.AppDefaults => "settings.connection.app.default",
        NativeOptionSource.Profile => "settings.connection.profile",
        NativeOptionSource.Session => "settings.connection.connection.override",
        NativeOptionSource.Document => "settings.connection.connection.file",
        _ => "settings.connection.command.line",
    });

    public static ContentDialog Create(NativeSessionSecurityDraft draft, Window owner)
    {
        var inheritance = Strings.Get("settings.security.use.this.window.s.initial.settings");
        var security = new SecurityFields(() => draft.Preferences, value => draft.Preferences = value,
            Strings.Get("settings.security.allow.the.methods.the.server.may.negotiate.on.the.next.connection.the"));
        var files = new TrustFileFields(() => draft.TrustFiles, value => draft.TrustFiles = value, () => owner,
            Strings.Get("settings.security.changes.apply.when.this.window.connects.again"));
        var filesGroup = new Expander { Header = Strings.Get("settings.section.certificateFiles"), Content = files, IsExpanded = true,
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var sources = Ui.Caption("");
        var error = Ui.Text("", "security.error");
        error.Foreground = Ui.Error;
        var applied = Ui.Caption(Strings.Get("settings.security.applied.for.the.next.connection.in.this.window"));
        var busy = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        busy.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        busy.Children.Add(Ui.Caption(Strings.Get("settings.security.checking.security.settings")));
        busy.Children.Add(Ui.Button(Strings.Get("settings.encoding.session.cancel.apply"), (_, _) => draft.CancelApply(), "security.cancelApply"));
        var reload = Ui.Button(Strings.Get("action.discard.edits.reload"), (_, _) => draft.Reload(), "security.reload");
        var panel = Ui.Stack(12,
            Ui.Caption(Strings.Get("settings.security.apply.while.disconnected.then.connect.again.changes.stay.in.this.window.and")),
            sources, security, filesGroup, error, applied, busy, reload);
        var dialog = Ui.Dialog(Strings.Get("settings.security.connection.security"), panel, 560);
        dialog.PrimaryButtonText = Strings.Get("action.apply");
        AutomationProperties.SetAutomationId(dialog, "security.dialog");

        void Refresh()
        {
            var enabled = !draft.IsBusy && !draft.NeedsReload;
            security.Refresh(draft.Inherited, draft.Choices, inheritance, draft.InheritedPriority, enabled);
            files.Refresh(draft.InheritedFiles, inheritance, enabled);
            sources.Text = draft.Sources is { } value
                ? value.Methods == NativeOptionSource.Session ? Strings.Get("settings.security.current.source.connection.override")
                  : Strings.Format("settings.security.sources", SourceLabel(value.Methods), SourceLabel(value.Priority))
                : "";
            error.Text = draft.Error is { } failure ? Strings.Resolve(Message(failure)) : "";
            error.Visibility = draft.Error is null ? Visibility.Collapsed : Visibility.Visible;
            applied.Visibility = draft.DidApply ? Visibility.Visible : Visibility.Collapsed;
            busy.Visibility = draft.IsBusy ? Visibility.Visible : Visibility.Collapsed;
            reload.Visibility = draft.NeedsReload ? Visibility.Visible : Visibility.Collapsed;
            reload.IsEnabled = draft.CanReload;
            dialog.IsPrimaryButtonEnabled = draft.CanApply;
            dialog.CloseButtonText = Strings.Get(draft.HasChanges ? "action.cancel" : "action.done");
            dialog.DefaultButton = draft.CanApply ? ContentDialogButton.Primary : ContentDialogButton.Close;
        }
        draft.PropertyChanged += (_, _) => Refresh();
        Refresh();
        dialog.PrimaryButtonClick += (_, args) => { args.Cancel = true; draft.Apply(); };
        dialog.Closing += (sender, args) =>
        {
            if (draft.IsBusy && !DialogPresenter.IsWithdrawn(sender)) args.Cancel = true;
            else draft.CancelEdits();
        };
        return dialog;
    }
}
