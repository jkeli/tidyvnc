// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TidyVNC.Native;
using TidyVNC.Native.Documents;

namespace TidyVNC;

/// <summary>
/// Save connection file as (F05-F06), in the editor slot: a snapshot taken
/// before any UI appears, the monitor-number mapping when a selected display
/// has no current number, then the review of what the file cannot preserve.
/// <see cref="Approved"/> is set only by "Continue to save…".
/// </summary>
internal sealed class ExportRequest(NativeExportSource source, IReadOnlyList<string> legacyDisplays)
{
    public NativeExportSource Source { get; } = source;
    public IReadOnlyList<string> LegacyDisplays { get; } = legacyDisplays;
    public NativeDocumentExport? Export { get; set; }
    public NativeExportMapping? Mapping { get; set; }
    public NativeDocumentExport? Approved { get; set; }

    /// <summary>The first step, or the problem that refuses the export.</summary>
    public NativeExportProblem? Begin()
    {
        try
        {
            Export = NativeDocumentExport.Create(Source, LegacyDisplays);
            return null;
        }
        catch (NativeExportFailure failure) when (failure.Problem == NativeExportProblem.DisplayMapping)
        {
            // Validate everything else with temporary numbers before offering the mapping.
            var temporary = Source.Fullscreen.SelectedDisplays.Select((id, i) => (id, i)).ToDictionary(p => p.id, p => p.i + 1);
            try { NativeDocumentExport.Create(Source, LegacyDisplays, temporary); }
            catch (NativeExportFailure other) { return other.Problem; }
            Mapping = new NativeExportMapping(Source.Fullscreen, LegacyDisplays);
            return null;
        }
        catch (NativeExportFailure failure) { return failure.Problem; }
    }

    public static string Text(NativeExportProblem problem) => Strings.Get(problem switch
    {
        NativeExportProblem.SecurityPolicy => "document.this.file.format.cannot.preserve.the.custom.tls.priority.policy.use.a",
        NativeExportProblem.DisplayMapping => "document.the.selected.displays.cannot.be.mapped.to.current.monitor.numbers.resolve.the",
        NativeExportProblem.ReviewRequired => "document.review.the.settings.that.cannot.be.preserved.before.exporting",
        _ => "document.a.connection.setting.cannot.be.represented.in.this.file.correct.it.before",
    });

    public static string Text(NativeExportLoss loss) => Strings.Get(loss switch
    {
        NativeExportLoss.FailureAlerts => "document.failure.alerts.omitted",
        NativeExportLoss.RemoteResize => "document.remote.resize.settings.are.not.supported.by.this.connection.file.format.the",
        NativeExportLoss.NetworkFamilies => "document.ipv4.and.ipv6.settings.are.not.supported.by.this.connection.file.format",
        NativeExportLoss.PointerTiming => "document.pointer.event.timing.is.not.supported.by.this.connection.file.format.the",
        NativeExportLoss.ClipboardLimit => "document.the.incoming.clipboard.size.limit.is.not.supported.by.this.connection.file",
        NativeExportLoss.WindowPlacement => "document.initial.window.size.position.and.maximization.are.not.supported.by.this.connection",
        NativeExportLoss.DisplayIdentity => "document.stable.display.identities.become.the.monitor.numbers.listed.in.this.review.the",
        NativeExportLoss.SshGateway => "document.the.ssh.gateway.cannot.be.saved.in.this.connection.file.format.opening",
        _ => "document.fields.ignored.when.opening.the.original.file.will.not.be.copied.to",
    });

    public static string Text(NativeDocumentSaveError error) => Strings.Get(error switch
    {
        NativeDocumentSaveError.InvalidDestination => "document.choose.a.regular.tidyvnc.file.in.an.existing.folder.symbolic.links.and",
        NativeDocumentSaveError.Denied => "document.the.connection.file.cannot.be.written.here.check.access.or.choose.another",
        NativeDocumentSaveError.Changed => "document.the.destination.changed.after.selection.choose.it.again.before.saving",
        NativeDocumentSaveError.OverwriteRequired => "document.confirm.replacement.of.the.existing.connection.file.before.saving",
        NativeDocumentSaveError.Busy => "document.another.save.is.using.this.folder.try.again.when.it.finishes",
        NativeDocumentSaveError.CommittedUncertain => "document.the.file.was.replaced.but.the.final.save.check.failed.inspect.the",
        _ => "document.the.connection.file.could.not.be.saved.the.destination.was.not.replaced",
    });
}

internal static class ExportDialog
{
    private static string DisplayName(string id) =>
        App.Current.Displays.Snapshot.Find(id)?.Name ?? Strings.Get("document.saved.display");

    public static ContentDialog Create(ExportRequest request)
    {
        var body = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var dialog = Ui.Dialog("", body, 520);
        dialog.CloseButtonText = Strings.Get("action.cancel");
        dialog.DefaultButton = ContentDialogButton.Primary;
        AutomationProperties.SetAutomationId(dialog, "document.export.dialog");
        var texts = new Dictionary<string, string>(StringComparer.Ordinal);
        string? issue = null;

        void Render()
        {
            if (request.Mapping is { } mapping) RenderMapping(mapping);
            else if (request.Export is { } export) RenderReview(export);
        }

        void RenderMapping(NativeExportMapping mapping)
        {
            dialog.Title = Strings.Get("document.choose.exported.monitor.numbers");
            dialog.PrimaryButtonText = Strings.Get("document.review.export");
            var panel = Ui.Stack(12, Ui.Text(Strings.Get("document.the.file.format.uses.monitor.numbers.instead.of.saved.display.identities.assign")));
            foreach (var id in mapping.SelectedDisplays)
            {
                if (!texts.TryGetValue(id, out var current))
                    texts[id] = current = mapping.Suggested.TryGetValue(id, out var number) ? number.ToString(System.Globalization.CultureInfo.InvariantCulture) : "";
                var name = DisplayName(id);
                var box = new TextBox { Header = name, Text = current, IsSpellCheckEnabled = false, MaxLength = 10,
                                   InputScope = new Microsoft.UI.Xaml.Input.InputScope { Names = { new Microsoft.UI.Xaml.Input.InputScopeName(Microsoft.UI.Xaml.Input.InputScopeNameValue.Number) } } };
                AutomationProperties.SetAutomationId(box, "document.export.mapping." + id);
                AutomationProperties.SetName(box, name);
                box.TextChanged += (_, _) => { texts[id] = box.Text; dialog.IsPrimaryButtonEnabled = mapping.Indices(texts) is not null; };
                panel.Children.Add(box);
                if (App.Current.Displays.Snapshot.Find(id) is null) panel.Children.Add(Ui.Caption(id));
            }
            panel.Children.Add(Ui.Caption(Strings.Get("document.use.a.different.positive.whole.number.for.each.display.these.choices.affect")));
            if (issue is not null)
            {
                var text = Ui.Text(issue, "document.export.mapping.issue");
                text.Foreground = Ui.Error;
                panel.Children.Add(text);
            }
            body.Content = panel;
            dialog.IsPrimaryButtonEnabled = mapping.Indices(texts) is not null;
        }

        void RenderReview(NativeDocumentExport export)
        {
            dialog.Title = Strings.Get("document.review.connection.export");
            dialog.PrimaryButtonText = Strings.Get("document.continue.to.save");
            dialog.IsPrimaryButtonEnabled = true;
            var panel = Ui.Stack(12,
                Ui.Text(export.Endpoint.Length == 0 ? Strings.Get("document.this.file.will.contain.settings.without.a.server.address")
                    : Strings.Format("document.server", export.Endpoint), "document.export.server", selectable: true),
                Ui.Text(Strings.Get("document.the.file.will.contain.a.snapshot.of.this.connection.s.settings.passwords")));
            if (export.MonitorIndices.Count != 0)
            {
                panel.Children.Add(Ui.Heading(Strings.Get("document.display.numbers.in.the.exported.file")));
                foreach (var (id, number) in export.MonitorIndices.OrderBy(p => p.Value))
                    panel.Children.Add(Ui.Text(Strings.Format("document.export.monitor.assignment", DisplayName(id), number)));
                panel.Children.Add(Ui.Button(Strings.Get("document.change.exported.monitor.numbers"), (_, _) =>
                {
                    request.Mapping = new NativeExportMapping(request.Source.Fullscreen, request.LegacyDisplays, export.MonitorIndices);
                    texts.Clear();
                    issue = null;
                    Render();
                }, "document.export.editMapping"));
            }
            if (export.Losses != NativeExportLoss.None)
            {
                panel.Children.Add(Ui.Heading(Strings.Get("document.settings.the.file.cannot.preserve")));
                var list = Ui.Stack(8);
                AutomationProperties.SetAutomationId(list, "document.export.losses");
                foreach (var loss in Enum.GetValues<NativeExportLoss>())
                    if (loss != NativeExportLoss.None && (export.Losses & loss) == loss) list.Children.Add(Ui.Text(ExportRequest.Text(loss)));
                panel.Children.Add(list);
            }
            body.Content = panel;
        }

        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (request.Mapping is { } mapping)
            {
                // The mapping step stays in this dialog; only the review closes it.
                args.Cancel = true;
                if (mapping.Indices(texts) is not { } indices) return;
                try
                {
                    request.Export = NativeDocumentExport.Create(request.Source, request.LegacyDisplays, indices);
                    request.Mapping = null;
                    issue = null;
                }
                catch (NativeExportFailure)
                {
                    issue = Strings.Get("document.assign.a.different.positive.monitor.number.to.every.saved.display.before.continuing");
                }
                Render();
                return;
            }
            request.Approved = request.Export;
        };
        Render();
        return dialog;
    }
}
