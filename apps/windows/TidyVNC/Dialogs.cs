// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.ComponentModel;
using System.Globalization;
using System.Text;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TidyVNC.Native;
using TidyVNC.Native.Credentials;
using TidyVNC.Native.Trust;
using TidyVNC.Native.Tunnel;

namespace TidyVNC;

/// <summary>Small builders shared by the code-built dialogs and pages.</summary>
internal static class Ui
{
    public static Brush Brush(string key) => (Brush)Application.Current.Resources[key];
    public static Brush Secondary => Brush("TextFillColorSecondaryBrush");
    public static Brush Warning => Brush("SystemFillColorCautionBrush");
    public static Brush Error => Brush("SystemFillColorCriticalBrush");

    public static TextBlock Text(string text, string? automationId = null, bool selectable = false)
    {
        var block = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = selectable };
        if (automationId is not null) AutomationProperties.SetAutomationId(block, automationId);
        return block;
    }

    public static TextBlock Text(NativeText text, string? automationId = null) => Text(Strings.Resolve(text), automationId);

    public static TextBlock Caption(string text, Brush? foreground = null)
    {
        var block = Text(text);
        block.Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"];
        block.Foreground = foreground ?? Secondary;
        return block;
    }

    public static TextBlock Heading(string text)
    {
        var block = Text(text);
        block.Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"];
        return block;
    }

    public static TextBlock Title(string text, string? automationId = null)
    {
        var block = Text(text, automationId);
        block.Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"];
        AutomationProperties.SetHeadingLevel(block, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        return block;
    }

    public static TextBlock Monospace(string text, string? automationId = null)
    {
        var block = Text(text, automationId, selectable: true);
        block.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        block.Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"];
        return block;
    }

    /// <summary>A label with a selectable value (macOS LabeledContent).</summary>
    public static StackPanel Labeled(string label, string value, bool monospace = false)
    {
        var panel = new StackPanel { Spacing = 2 };
        panel.Children.Add(Caption(label));
        panel.Children.Add(monospace ? Monospace(value) : Text(value, selectable: true));
        return panel;
    }

    public static Button Button(string text, RoutedEventHandler click, string? automationId = null, bool accent = false)
    {
        var button = new Button { Content = text };
        button.Click += click;
        if (accent) button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        if (automationId is not null) AutomationProperties.SetAutomationId(button, automationId);
        return button;
    }

    public static StackPanel Stack(double spacing = 12, params UIElement[] children)
    {
        var panel = new StackPanel { Spacing = spacing };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    public static ContentDialog Dialog(string title, UIElement content, double width = 440)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled },
            Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
        };
        // The macOS sheet width (UX.md section 5): lift the 548 epx default limit where needed.
        dialog.Resources["ContentDialogMaxWidth"] = Math.Max(548, width + 48);
        dialog.Resources["ContentDialogMinWidth"] = width;
        return dialog;
    }
}

/// <summary>The credentials dialog (macOS AuthenticationSheet; PARITY A01-A08).</summary>
internal static class AuthenticationDialog
{
    public static ContentDialog Create(NativeConnectionController controller, NativePrompt prompt)
    {
        var credentials = controller.Credentials;
        var panel = new StackPanel { Spacing = 12, MaxWidth = 440 };
        var server = Ui.Text(prompt.ServerName, "authentication.server", selectable: true);
        server.Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"];
        server.MaxLines = 3;
        server.TextTrimming = TextTrimming.CharacterEllipsis;
        ToolTipService.SetToolTip(server, prompt.ServerName);
        panel.Children.Add(server);
        var protection = Ui.Text(Strings.Get(prompt.Secure ? "authentication.protection.protected" : "authentication.protection.unassured"),
            "authentication.credentialProtection");
        protection.Foreground = prompt.Secure ? Ui.Secondary : Ui.Warning;
        panel.Children.Add(protection);
        panel.Children.Add(Ui.Caption(Strings.Get("authentication.this.assessment.describes.credential.protection.not.encryption")));

        var username = new TextBox { Header = Strings.Get("authentication.username"), IsSpellCheckEnabled = false };
        AutomationProperties.SetAutomationId(username, "authentication.username");
        if (prompt.UsernameRequired) panel.Children.Add(username);
        var password = new PasswordBox { Header = Strings.Get("authentication.password") };
        AutomationProperties.SetAutomationId(password, "authentication.password");
        panel.Children.Add(password);

        var retention = new RadioButtons { Header = Strings.Get("authentication.password.lifetime") };
        AutomationProperties.SetAutomationId(retention, "authentication.retention");
        retention.Items.Add(Strings.Get("authentication.use.once"));
        retention.Items.Add(Strings.Get("authentication.retain.for.this.session.s.reconnect"));
        if (credentials.SupportsRemembering) retention.Items.Add(Strings.Get("authentication.remember.on.this.mac"));
        retention.SelectedIndex = 0;
        var replace = new CheckBox { Content = Strings.Get("authentication.replace.an.existing.saved.password"), Visibility = Visibility.Collapsed };
        AutomationProperties.SetAutomationId(replace, "authentication.replace");
        var replaceHelp = Ui.Caption(Strings.Get("authentication.save.only.after.successful.authentication.replacement.must"));
        replaceHelp.Visibility = Visibility.Collapsed;
        retention.SelectionChanged += (_, _) =>
        {
            var remember = retention.SelectedIndex == 2;
            replace.Visibility = replaceHelp.Visibility = remember ? Visibility.Visible : Visibility.Collapsed;
        };
        if (!controller.IsReverse)
        {
            panel.Children.Add(retention);
            panel.Children.Add(replace);
            panel.Children.Add(replaceHelp);
        }
        else panel.Children.Add(Ui.Caption(Strings.Get("authentication.this.incoming.connection.uses.the.password.once")));

        var useSession = Ui.Button(Strings.Get("authentication.use.session.password"), (_, _) => { }, "authentication.useSession");
        var useSaved = Ui.Button(Strings.Get("authentication.use.saved.password"), (_, _) => { }, "authentication.useSaved");
        var forgetSaved = Ui.Button(Strings.Get("authentication.forget.saved.password"), (_, _) => { }, "authentication.forgetSaved");
        var savedActions = new StackPanel { Spacing = 8 };
        savedActions.Children.Add(useSession);
        if (credentials.SupportsRemembering) { savedActions.Children.Add(useSaved); savedActions.Children.Add(forgetSaved); }
        panel.Children.Add(savedActions);
        var working = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        working.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        working.Children.Add(Ui.Caption(Strings.Get("authentication.preparing.credentials")));
        panel.Children.Add(working);
        var notice = Ui.Caption("");
        panel.Children.Add(notice);
        var problem = Ui.Text("", "authentication.error");
        problem.Foreground = Ui.Error;
        problem.Visibility = Visibility.Collapsed;
        panel.Children.Add(problem);

        var dialog = Ui.Dialog(Strings.Get("authentication.authentication.required"), panel);
        dialog.PrimaryButtonText = Strings.Get("authentication.authenticate");
        dialog.CloseButtonText = Strings.Get("action.cancel");
        dialog.DefaultButton = ContentDialogButton.Primary;
        AutomationProperties.SetAutomationId(dialog, "authentication.dialog");

        void Refresh()
        {
            useSession.Visibility = credentials.HasSessionCredential ? Visibility.Visible : Visibility.Collapsed;
            useSession.IsEnabled = !credentials.IsWorking && credentials.CanUseSession(prompt, username.Text);
            useSaved.IsEnabled = forgetSaved.IsEnabled = !credentials.IsWorking;
            working.Visibility = credentials.IsWorking ? Visibility.Visible : Visibility.Collapsed;
            retention.IsEnabled = !credentials.IsWorking;
            dialog.IsPrimaryButtonEnabled = !credentials.IsWorking;
            notice.Text = credentials.Notice is { } value ? Strings.Resolve(NativeTexts.Credential(value)) : "";
            notice.Visibility = notice.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        void Show(string text) { problem.Text = text; problem.Visibility = Visibility.Visible; }
        PropertyChangedEventHandler changed = (_, _) => Refresh();
        credentials.PropertyChanged += changed;
        username.TextChanged += (_, _) => Refresh();
        Refresh();

        NativeCredentialRetention Retention() => controller.IsReverse ? NativeCredentialRetention.UseOnce : retention.SelectedIndex switch
        {
            1 => NativeCredentialRetention.Session,
            2 => replace.IsChecked == true ? NativeCredentialRetention.ReplaceRemembered : NativeCredentialRetention.Remember,
            _ => NativeCredentialRetention.UseOnce,
        };
        useSession.Click += (_, _) =>
        {
            password.Password = "";
            try { credentials.UseSession(prompt, username.Text); }
            catch (Exception error) when (error is NativeError or NativeCredentialException or NativeIdentityFailure)
            {
                Show(Strings.Get("authentication.the.session.password.is.no.longer.available"));
            }
        };
        useSaved.Click += (_, _) => { password.Password = ""; credentials.UseSaved(prompt, username.Text, Retention()); };
        forgetSaved.Click += (_, _) => credentials.ForgetSaved(prompt, username.Text);
        dialog.PrimaryButtonClick += (_, args) =>
        {
            var user = Encoding.UTF8.GetBytes(username.Text);
            var secret = Encoding.UTF8.GetBytes(password.Password);
            password.Password = "";
            try { credentials.Submit(prompt, user, secret, Retention()); }
            catch (Exception error) when (error is NativeError or NativeCredentialException or NativeIdentityFailure)
            {
                args.Cancel = true;
                Show(NativeConnectionIssues.From(error) is { } issue ? Strings.Resolve(issue.Message())
                    : Strings.Get("authentication.this.authentication.request.is.no.longer.active"));
            }
            finally
            {
                System.Security.Cryptography.CryptographicOperations.ZeroMemory(user);
                System.Security.Cryptography.CryptographicOperations.ZeroMemory(secret);
            }
        };
        password.KeyDown += (_, e) =>
        {
            // Enter submits once (A05); the dialog's default button does the rest.
            if (e.Key == Windows.System.VirtualKey.Enter && e.KeyStatus.RepeatCount > 1) e.Handled = true;
        };
        dialog.Opened += (_, _) => (prompt.UsernameRequired ? (Control)username : password).Focus(FocusState.Programmatic);
        dialog.Closed += (_, _) =>
        {
            credentials.PropertyChanged -= changed;
            password.Password = ""; username.Text = "";
        };
        return dialog;
    }
}

/// <summary>The server identity dialog (macOS AuthenticationSheet trust branch and TrustDetailsView; PARITY T01-T06, T08).</summary>
internal static class TrustDialog
{
    public static ContentDialog Create(NativeConnectionController controller, NativePrompt prompt)
    {
        var trust = controller.Trust;
        var presentation = new NativeTrustPresentation(prompt);
        var destination = controller.AttemptEndpoint ?? controller.Endpoint;
        var panel = new StackPanel { Spacing = 12, MaxWidth = 460 };
        var server = Ui.Text(prompt.ServerName, "trust.server", selectable: true);
        server.Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"];
        panel.Children.Add(server);
        var details = new StackPanel { Spacing = 10 };
        var detailsScroll = new ScrollViewer { Content = details, MaxHeight = 390, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        AutomationProperties.SetAutomationId(detailsScroll, "trust.details");
        panel.Children.Add(detailsScroll);
        var notice = Ui.Caption("", Ui.Brush("TextFillColorPrimaryBrush"));
        panel.Children.Add(notice);
        var saveHelp = Ui.Caption(Strings.Get("authentication.a.saved.identity.applies.only.to.this"));
        panel.Children.Add(saveHelp);
        var saveButton = new DropDownButton();
        AutomationProperties.SetAutomationId(saveButton, "authentication.saveTrust");
        panel.Children.Add(saveButton);
        var reload = Ui.Button(Strings.Get("authentication.reload.saved.decisions"), (_, _) => trust.Reload(), "authentication.reloadTrust");
        panel.Children.Add(reload);
        var problem = Ui.Text("", "authentication.error");
        problem.Foreground = Ui.Error;
        problem.Visibility = Visibility.Collapsed;
        panel.Children.Add(problem);

        var dialog = Ui.Dialog(Strings.Get("authentication.verify.server.identity"), panel, 460);
        dialog.PrimaryButtonText = Strings.Get("authentication.connect.once");
        dialog.CloseButtonText = Strings.Get("action.cancel");
        dialog.DefaultButton = ContentDialogButton.Close; // T03: Cancel is the default.
        AutomationProperties.SetAutomationId(dialog, "trust.dialog");

        // The confirmation is a step inside the dialog, a flyout on the button (UX.md section 5).
        var confirmTitle = Ui.Heading("");
        var confirmText = Ui.Text("");
        var confirm = Ui.Button("", (_, _) => { }, "authentication.confirmSave", accent: true);
        var flyout = new Flyout { Content = Ui.Stack(12, confirmTitle, confirmText, confirm) };
        saveButton.Flyout = flyout;
        confirm.Click += (_, _) => { flyout.Hide(); trust.SaveAndConnect(prompt); };

        void Refresh()
        {
            Details(details, prompt, presentation, destination, trust);
            notice.Text = trust.Notice is { } value ? Strings.Resolve(NativeTrustTexts.Notice(value)) : "";
            notice.Visibility = notice.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            var canSave = trust.CanSave(prompt);
            saveHelp.Visibility = saveButton.Visibility = canSave ? Visibility.Visible : Visibility.Collapsed;
            saveButton.Content = Strings.Get(trust.ReplacesSavedKey ? "authentication.replace.saved.key.and.connect"
                : prompt.Kind == NativePrompt.PromptKind.HostKey ? "authentication.save.server.key.and.connect" : "authentication.save.exception.and.connect");
            confirmTitle.Text = Strings.Get(trust.ReplacesSavedKey ? "authentication.replace.the.saved.key"
                : prompt.Kind == NativePrompt.PromptKind.HostKey ? "authentication.save.this.server.key" : "authentication.save.this.certificate.exception");
            confirmText.Text = Strings.Format(prompt.Kind == NativePrompt.PromptKind.HostKey ? "authentication.confirm.key.scope" : "authentication.confirm.certificate.scope",
                destination);
            confirm.Content = Strings.Get(trust.ReplacesSavedKey ? "authentication.replace.and.connect" : "authentication.save.and.connect");
            saveButton.IsEnabled = !trust.IsWorking;
            reload.Visibility = trust.NeedsReload ? Visibility.Visible : Visibility.Collapsed;
            reload.IsEnabled = !trust.IsWorking;
            dialog.IsPrimaryButtonEnabled = !trust.IsWorking && presentation.MayConnectOnce;
        }
        PropertyChangedEventHandler changed = (_, _) => Refresh();
        trust.PropertyChanged += changed;
        Refresh();
        dialog.PrimaryButtonClick += (_, args) =>
        {
            try { trust.ConnectOnce(prompt); }
            catch (Exception error) when (error is NativeError or InvalidOperationException)
            {
                args.Cancel = true;
                problem.Text = NativeConnectionIssues.From(error) is { } issue ? Strings.Resolve(issue.Message())
                    : Strings.Get("authentication.this.authentication.request.is.no.longer.active");
                problem.Visibility = Visibility.Visible;
            }
        };
        dialog.Closed += (_, _) => trust.PropertyChanged -= changed;
        return dialog;
    }

    /// <summary>TrustDetailsView: the fingerprint and its guidance stay first; secondary details follow.</summary>
    private static void Details(StackPanel panel, NativePrompt prompt, NativeTrustPresentation details, string destination, NativeCertificateTrust trust)
    {
        panel.Children.Clear();
        var hostKey = prompt.Kind == NativePrompt.PromptKind.HostKey;
        if (destination.Length != 0 && destination != prompt.ServerName)
            panel.Children.Add(Ui.Labeled(Strings.Get("trust.destination"), destination));
        if (trust.IsWorking)
        {
            var working = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            working.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            working.Children.Add(Ui.Caption(Strings.Get("trust.checking.saved.certificate.exceptions")));
            panel.Children.Add(working);
        }
        if (NativeTrustTexts.Issue(trust.Issue, trust.SavedIssue) is { } issue)
        {
            var text = Ui.Text(issue);
            text.Foreground = Ui.Warning;
            panel.Children.Add(text);
        }
        if (trust.SavedInspection is { State: not NativeSavedTrustState.Absent } saved)
        {
            if (saved.State == NativeSavedTrustState.Changed)
            {
                var changed = Ui.Text(Strings.Get("trust.the.server.public.key.differs.from.the.key.saved.for.this.destination"), "trust.changedScopedKey");
                changed.Foreground = Ui.Error;
                panel.Children.Add(changed);
                panel.Children.Add(Ui.Monospace(Strings.Format(hostKey ? "trust.expected.serverKey" : "trust.expected.spki", saved.SavedFingerprint ?? "")));
                panel.Children.Add(Ui.Monospace(Strings.Format(hostKey ? "trust.received.serverKey" : "trust.received.spki", saved.ReceivedFingerprint)));
            }
            else if (saved.State == NativeSavedTrustState.Forgotten)
            {
                panel.Children.Add(Ui.Caption(Strings.Get(hostKey ? "trust.the.server.key.was.forgotten.for.this.destination.compare.its.fingerprint.again"
                    : "trust.the.saved.key.was.forgotten.for.this.destination.older.host.wide.exceptions"), Ui.Brush("TextFillColorPrimaryBrush")));
            }
            panel.Children.Add(Ui.Caption(Strings.Get("trust.this.decision.is.scoped.to.the.destination.s.address.port.and.route")));
        }
        if (trust.Inspection is { } inspection)
        {
            if (inspection.State == NativeKnownHostsState.Changed)
            {
                var changed = Ui.Text(Strings.Get("trust.the.server.public.key.differs.from.the.saved.certificate.exception"), "trust.changedKey");
                changed.Foreground = Ui.Error;
                panel.Children.Add(changed);
                foreach (var identity in inspection.Expected) panel.Children.Add(Ui.Monospace(Strings.Resolve(NativeTrustTexts.Expected(identity))));
                panel.Children.Add(Ui.Monospace(Strings.Format("trust.received.spki", inspection.ReceivedFingerprint)));
                if (inspection.HasMore) panel.Children.Add(Ui.Caption(Strings.Get("trust.additional.saved.identities.are.not.shown")));
            }
            else if (inspection.State == NativeKnownHostsState.Missing)
                panel.Children.Add(Ui.Caption(Strings.Get("trust.no.active.saved.certificate.exception.matches.this.server"), Ui.Brush("TextFillColorPrimaryBrush")));
            panel.Children.Add(Ui.Caption(Strings.Get(inspection.IncludesWildcardHost ? "trust.the.existing.exception.file.includes.a.wildcard.host.rule"
                : "trust.existing.certificate.exceptions.are.scoped.to.the.server.name.across.ports.and")));
        }
        foreach (var problem in NativeTrustTexts.Problems(details, prompt.Kind)) panel.Children.Add(Ui.Text(problem));
        if (hostKey)
        {
            try { panel.Children.Add(Ui.Caption(Strings.Format("trust.rsa.bits", new NativeHostKey(prompt.Identity).Bits))); }
            catch (Exception error) when (error is NativeError or ArgumentException) { }
        }
        if (details.Subject is { } subject) panel.Children.Add(Ui.Labeled(Strings.Get("trust.certificate.subject"), subject));
        if (details.Sha256Fingerprint is { } fingerprint)
        {
            panel.Children.Add(Ui.Caption(Strings.Get(prompt.Kind == NativePrompt.PromptKind.Certificate
                ? "trust.certificate.sha.256.fingerprint" : "trust.server.key.sha.256.fingerprint")));
            panel.Children.Add(Ui.Monospace(fingerprint, "trust.sha256"));
        }
        if (details.CompatibilityFingerprint is { } compatibility)
        {
            panel.Children.Add(Ui.Caption(Strings.Get("trust.server.compatibility.fingerprint.truncated.sha.1")));
            panel.Children.Add(Ui.Monospace(compatibility, "trust.compatibilityFingerprint"));
        }
        if (details.MayConnectOnce)
        {
            if (prompt.Kind == NativePrompt.PromptKind.Certificate)
                panel.Children.Add(Ui.Text(Strings.Get("trust.verify.this.fingerprint.with.the.server.administrator.before.continuing")));
            panel.Children.Add(Ui.Caption(Strings.Get("trust.connect.once.applies.only.to.this.connection.attempt.it.does.not.save")));
        }
        else
        {
            var refused = Ui.Text(Strings.Get("trust.this.identity.cannot.be.accepted.cancel.and.contact.the.server.administrator"), "trust.cannotOverride");
            refused.Foreground = Ui.Error;
            panel.Children.Add(refused);
        }
        if (details.Certificate is { } certificate)
        {
            if (certificate.Issuer is { } issuer) panel.Children.Add(Ui.Labeled(Strings.Get("trust.certificate.issuer"), issuer));
            if (certificate.SerialNumber is { } serial) panel.Children.Add(Ui.Labeled(Strings.Get("trust.certificate.serial"), serial, monospace: true));
            if (certificate.ValidFrom is { } from) panel.Children.Add(Ui.Labeled(Strings.Get("trust.certificate.valid.from"), from.LocalDateTime.ToString("g", CultureInfo.CurrentCulture)));
            if (certificate.ValidUntil is { } until) panel.Children.Add(Ui.Labeled(Strings.Get("trust.certificate.valid.until"), until.LocalDateTime.ToString("g", CultureInfo.CurrentCulture)));
            if (certificate.KeyAlgorithm is { } algorithm && certificate.KeyBits is { } bits)
                panel.Children.Add(Ui.Labeled(Strings.Get("trust.certificate.public.key"), Strings.Format("trust.certificate.public.key.value", algorithm, bits)));
            if (certificate.SignatureAlgorithm is { } signature) panel.Children.Add(Ui.Labeled(Strings.Get("trust.certificate.signature"), signature));
        }
    }
}

/// <summary>SSH gateway questions (macOS SSHAuthenticationSheet; PARITY A09, T08).</summary>
internal static class SshDialog
{
    public static ContentDialog Create(NativeSshInteraction interaction, NativeSshQuestion question)
    {
        var prompt = question.Prompt;
        var panel = new StackPanel { Spacing = 12, MaxWidth = 460 };
        panel.Children.Add(Ui.Labeled(Strings.Get("ssh.gateway"), question.Gateway.CanonicalUri));
        panel.Children.Add(Ui.Labeled(Strings.Get("ssh.remote.desktop"), question.Endpoint));
        if (prompt.HostKey is { } key)
        {
            panel.Children.Add(Ui.Labeled(Strings.Get("ssh.key.type"), key.Algorithm));
            panel.Children.Add(Ui.Monospace(key.Fingerprint, "ssh.fingerprint"));
            panel.Children.Add(Ui.Caption(Strings.Get("ssh.verify.this.fingerprint.with.the.gateway.administrator")));
        }
        panel.Children.Add(Ui.Heading(Strings.Get("ssh.request.from.ssh")));
        panel.Children.Add(Ui.Text(prompt.Text, "ssh.prompt", selectable: true));
        var response = new PasswordBox { Header = Strings.Get("ssh.response") };
        AutomationProperties.SetAutomationId(response, "ssh.response");
        if (prompt.Kind == NativeSshPromptKind.Secret)
        {
            panel.Children.Add(response);
            panel.Children.Add(Ui.Caption(Strings.Get("ssh.used.once.for.this.ssh.request.it")));
        }
        var problem = Ui.Text("", "ssh.error");
        problem.Foreground = Ui.Error;
        problem.Visibility = Visibility.Collapsed;
        panel.Children.Add(problem);

        var dialog = Ui.Dialog(Strings.Get(prompt.Kind == NativeSshPromptKind.HostKey ? "ssh.verify.ssh.gateway.identity" : "ssh.ssh.gateway.authentication"), panel, 460);
        dialog.CloseButtonText = Strings.Get("action.cancel");
        dialog.PrimaryButtonText = Strings.Get(prompt.Kind switch
        {
            NativeSshPromptKind.Secret => "ssh.continue",
            NativeSshPromptKind.HostKey => "ssh.trust.and.save",
            _ => "ssh.allow.once",
        });
        // A secret is submitted with Enter; a host key or permission defaults to Cancel.
        dialog.DefaultButton = prompt.Kind == NativeSshPromptKind.Secret ? ContentDialogButton.Primary : ContentDialogButton.Close;
        AutomationProperties.SetAutomationId(dialog, "ssh.dialog");
        dialog.PrimaryButtonClick += (_, args) =>
        {
            var answer = prompt.Kind switch
            {
                NativeSshPromptKind.Secret => response.Password,
                NativeSshPromptKind.HostKey => prompt.HostKey?.Fingerprint ?? "",
                _ => "yes",
            };
            response.Password = "";
            if (!interaction.Respond(question.Id, answer))
            {
                args.Cancel = true;
                problem.Text = Strings.Get("ssh.the.response.could.not.be.submitted.use");
                problem.Visibility = Visibility.Visible;
            }
        };
        dialog.Opened += (_, _) => { if (prompt.Kind == NativeSshPromptKind.Secret) response.Focus(FocusState.Programmatic); };
        dialog.Closed += (_, _) => response.Password = "";
        return dialog;
    }
}

/// <summary>Connection problems and fatal messages (macOS connection alert; PARITY E01-E06).</summary>
internal static class ProblemDialog
{
    public static ContentDialog Create(NativeConnectionController controller, NativeConnectionProblem problem)
    {
        var dialog = Ui.Dialog(Strings.Resolve(problem.Issue.Title()), Ui.Text(problem.Issue.Message(), "connection.problem.message"), 400);
        dialog.CloseButtonText = Strings.Get("action.cancel");
        dialog.DefaultButton = ContentDialogButton.Close;
        if (controller.OffersRetry(problem))
        {
            dialog.PrimaryButtonText = Strings.Get("app.retry");
            dialog.IsPrimaryButtonEnabled = controller.CanRetry(problem);
        }
        AutomationProperties.SetAutomationId(dialog, "connection.problem");
        return dialog;
    }

    public static ContentDialog Create(NativeText message)
    {
        var dialog = Ui.Dialog(Strings.Get("app.connection.problem"), Ui.Text(message, "connection.message"), 400);
        dialog.CloseButtonText = Strings.Get("app.ok");
        dialog.DefaultButton = ContentDialogButton.Close;
        AutomationProperties.SetAutomationId(dialog, "connection.message.dialog");
        return dialog;
    }
}
