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

/// <summary>
/// About TidyVNC (UX.md section 2, PARITY C08 and H01): a small window that cannot be resized, with the
/// icon, name, version and processor architecture, copyright, credits and links. Its text is
/// selectable, and Esc or Done closes it. It is one window for the app, so any connection window can
/// open it whatever that window is doing.
/// </summary>
internal sealed partial class AboutWindow : Window
{
    public static string Version =>
        typeof(AboutWindow).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? typeof(AboutWindow).Assembly.GetName().Version?.ToString(3) ?? "";

    public static string Architecture => RuntimeInformation.ProcessArchitecture switch
    {
        System.Runtime.InteropServices.Architecture.Arm64 => "ARM64",
        System.Runtime.InteropServices.Architecture.X64 => "x64",
        var other => other.ToString(),
    };

    public AboutWindow()
    {
        Title = Strings.Get("about.title");
        SystemBackdrop = new MicaBackdrop();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "tidyvnc.ico"));
        WindowSizes.Apply(AppWindow, 480, 560, 480, 560);
        if (AppWindow.Overlapped() is { } presenter)
        {
            presenter.IsResizable = false; presenter.IsMaximizable = false; presenter.IsMinimizable = false;
        }

        var icon = new Image
        {
            Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "tidyvnc_128.png"))),
            Width = 96, Height = 96, HorizontalAlignment = HorizontalAlignment.Center,
        };
        AutomationProperties.SetAccessibilityView(icon, AccessibilityView.Raw);
        var name = Ui.Title("TidyVNC", "about.name");
        name.HorizontalAlignment = HorizontalAlignment.Center;
        AutomationProperties.SetHeadingLevel(name, AutomationHeadingLevel.Level1);
        var version = Ui.Text(Strings.Format("about.version", Version, Architecture), "about.version", selectable: true);
        var copyright = Ui.Text(Strings.Get("about.copyright"), "about.copyright", selectable: true);
        var summary = Ui.Text(Strings.Get("about.summary"), "about.summary", selectable: true);
        var credits = Ui.Text(Strings.Get("about.credits"), "about.credits", selectable: true);
        foreach (var text in new[] { version, copyright, summary, credits })
        {
            text.TextWrapping = TextWrapping.Wrap;
            text.HorizontalAlignment = HorizontalAlignment.Center;
            text.TextAlignment = TextAlignment.Center;
        }

        HyperlinkButton Link(string key, string id, Action open)
        {
            var link = new HyperlinkButton { Content = Strings.Get(key), HorizontalAlignment = HorizontalAlignment.Center };
            AutomationProperties.SetAutomationId(link, id);
            link.Click += (_, _) => open();
            return link;
        }
        var links = Ui.Stack(0,
            Link("about.acknowledgements", "about.acknowledgements", () => App.Current.OpenHelp("acknowledgements")),
            Link("about.licences", "about.licences", () => App.Current.OpenHelp("licence")),
            Link("help.project", "about.project", () => App.OpenLink(NativeHelpLink.Project)),
            Link("help.issue", "about.issue", () => App.OpenLink(NativeHelpLink.Issues)));

        var done = Ui.Button(Strings.Get("action.done"), (_, _) => Close(), "about.done", accent: true);
        done.HorizontalAlignment = HorizontalAlignment.Right;
        var body = Ui.Stack(12, icon, name, version, copyright, summary, credits, links);
        var root = new Grid { Padding = new Thickness(24), RowSpacing = 12 };
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        Grid.SetRow(done, 1);
        root.Children.Add(scroll); root.Children.Add(done);
        var escape = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = Windows.System.VirtualKey.Escape };
        escape.Invoked += (_, e) => { e.Handled = true; Close(); };
        root.KeyboardAccelerators.Add(escape);
        AutomationProperties.SetAutomationId(root, "about.window");
        Content = root;
        root.Loaded += (_, _) => done.Focus(FocusState.Programmatic);
    }
}
