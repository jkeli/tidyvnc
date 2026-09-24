// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TidyVNC.Native;

namespace TidyVNC;

/// <summary>
/// TidyVNC help (macOS ApplicationHelpView; PARITY H02-H04): the getting
/// started guide in Windows terms, the bundled acknowledgements, licence and
/// Windows third-party notices, and the project and issue links.
/// </summary>
internal sealed partial class HelpWindow : Window
{
    private static readonly (string Tag, string Key)[] Topics =
    [
        ("guide", "help.topic.guide"), ("acknowledgements", "help.topic.acknowledgements"), ("licence", "help.topic.licence"),
        ("thirdParty", "help.topic.thirdParty"),
    ];

    private static readonly (string Title, string Body)[] Guide =
    [
        ("help.guide.connect.title", "help.guide.connect.body"), ("help.guide.ssh.title", "help.guide.ssh.body"),
        ("help.guide.identity.title", "help.guide.identity.body"), ("help.guide.profiles.title", "help.guide.profiles.body"),
        ("help.guide.input.title", "help.guide.input.body"), ("help.guide.listen.title", "help.guide.listen.body"),
        ("help.guide.failure.title", "help.guide.failure.body"), ("help.guide.install.title", "help.guide.install.body"),
    ];

    private readonly SelectorBar topics = new();
    private readonly ContentControl page = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private int load;

    public HelpWindow(string? topic = null)
    {
        Title = Strings.Get("help.title");
        SystemBackdrop = new MicaBackdrop();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "tidyvnc.ico"));
        WindowSizes.Apply(AppWindow, 720, 640, 560, 440);
        foreach (var (tag, key) in Topics)
        {
            var item = new SelectorBarItem { Text = Strings.Get(key), Tag = tag };
            AutomationProperties.SetAutomationId(item, "help.topic." + tag);
            topics.Items.Add(item);
        }
        AutomationProperties.SetName(topics, Strings.Get("help.topic.label"));
        AutomationProperties.SetAutomationId(topics, "help.topic");
        topics.SelectionChanged += (_, _) => { if (topics.SelectedItem is { Tag: string tag }) Show(tag); };

        var title = Ui.Title(Strings.Get("help.title"), "help.title");
        AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level1);
        var project = new HyperlinkButton { Content = Strings.Get("help.project") };
        project.Click += (_, _) => App.OpenLink(NativeHelpLink.Project);
        var issue = new HyperlinkButton { Content = Strings.Get("help.issue") };
        issue.Click += (_, _) => App.OpenLink(NativeHelpLink.Issues);
        AutomationProperties.SetAutomationId(project, "help.project");
        AutomationProperties.SetAutomationId(issue, "help.issue");
        var links = new Grid();
        links.ColumnDefinitions.Add(new ColumnDefinition());
        links.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(issue, 1);
        links.Children.Add(project); links.Children.Add(issue);

        var scroll = new ScrollViewer { Content = page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        var root = new Grid { Padding = new Thickness(24), RowSpacing = 12 };
        foreach (var height in new[] { GridLength.Auto, GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto })
            root.RowDefinitions.Add(new RowDefinition { Height = height });
        var privacy = Ui.Caption(Strings.Get("help.privacy"));
        Grid.SetRow(topics, 1); Grid.SetRow(scroll, 2); Grid.SetRow(links, 3); Grid.SetRow(privacy, 4);
        foreach (var child in new UIElement[] { title, topics, scroll, links, privacy }) root.Children.Add(child);
        Content = root;
        Strings.Localize(this);
        topics.SelectedItem = topics.Items.FirstOrDefault(i => (string)i.Tag == (topic ?? "guide")) ?? topics.Items[0];
    }

    public void ShowTopic(string topic)
    {
        topics.SelectedItem = topics.Items.FirstOrDefault(i => (string)i.Tag == topic) ?? topics.SelectedItem;
        Activate();
    }

    private void Show(string tag)
    {
        var ticket = ++load;
        if (tag == "guide")
        {
            var sections = new StackPanel { Spacing = 16 };
            foreach (var (titleKey, bodyKey) in Guide)
            {
                var heading = Ui.Heading(Strings.Get(titleKey));
                AutomationProperties.SetHeadingLevel(heading, AutomationHeadingLevel.Level2);
                sections.Children.Add(Ui.Stack(5, heading, new TextBlock { Text = Strings.Get(bodyKey), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }));
            }
            page.Content = sections;
            return;
        }
        page.Content = Ui.Caption(Strings.Get("help.loading"));
        var file = tag switch { "licence" => "LICENCE.TXT", "thirdParty" => "ThirdParty.md", _ => "README.rst" };
        _ = LoadAsync(ticket, tag, Path.Combine(AppContext.BaseDirectory, "Documents", file));
    }

    /// <summary>Bundled documents are read off the UI thread, at most 1 MiB.</summary>
    private async Task LoadAsync(int ticket, string tag, string path)
    {
        string? text = await Task.Run(() =>
        {
            try
            {
                var info = new FileInfo(path);
                return info.Exists && info.Length <= 1 << 20 ? File.ReadAllText(path) : null;
            }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
        });
        if (ticket != load) return;
        var document = new TextBlock
        {
            Text = text ?? Strings.Get("help.document.unavailable"), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
        };
        AutomationProperties.SetAutomationId(document, "help.document");
        page.Content = tag == "acknowledgements" ? Ui.Stack(12, Ui.Caption(Strings.Get("help.acknowledgements.note")), document) : document;
    }
}

/// <summary>The editor-slot request for About TidyVNC.</summary>
internal sealed record AboutRequest(Guid Id);

/// <summary>About TidyVNC (PARITY H01): the version and the processor architecture of this build.</summary>
internal static class AboutDialog
{
    public static string Version =>
        typeof(AboutDialog).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? typeof(AboutDialog).Assembly.GetName().Version?.ToString(3) ?? "";

    public static ContentDialog Create(Action openLicence)
    {
        var architecture = RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.Arm64 => "ARM64",
            Architecture.X64 => "x64",
            var other => other.ToString(),
        };
        var version = Ui.Text(Strings.Format("about.version", Version, architecture), "about.version");
        var licences = new HyperlinkButton { Content = Strings.Get("about.licences") };
        AutomationProperties.SetAutomationId(licences, "about.licences");
        var dialog = Ui.Dialog(Strings.Get("about.title"), Ui.Stack(12, version, Ui.Caption(Strings.Get("about.summary")), licences), 440);
        licences.Click += (_, _) => { dialog.Hide(); openLicence(); };
        dialog.CloseButtonText = Strings.Get("action.done");
        AutomationProperties.SetAutomationId(dialog, "about.dialog");
        return dialog;
    }
}
