using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools;
using LazyPDF.Core;

namespace LazyPDF.App.Panels.Bookmarks;

/// <summary>An outline entry in the tree. Whether it is open is remembered by the panel, by the entry's place in the outline.</summary>
public sealed class BookmarkNode(OutlineItem item, string path, Dictionary<string, bool> opened)
{
    public OutlineItem Item { get; } = item;

    public string Title => Item.Title;

    public FontWeight Weight => Item.Bold ? FontWeights.SemiBold : FontWeights.Normal;

    public FontStyle Style => Item.Italic ? System.Windows.FontStyles.Italic : System.Windows.FontStyles.Normal;

    public List<BookmarkNode> Children { get; } = [.. item.Children.Select((child, i) => new BookmarkNode(child, path + "." + i, opened))];

    public bool IsExpanded
    {
        get => opened.TryGetValue(path, out bool open) ? open : Item.IsOpen;
        set => opened[path] = value;
    }
}

/// <summary>The file's outline as a tree; a click goes to what the entry points at.</summary>
public partial class BookmarksSidePanel : ToolPanel
{
    // Which entries the person opened or closed, kept while the file is edited and the tree is read again.
    private readonly Dictionary<string, bool> _opened = [];
    private DocumentTab? _for;

    public BookmarksSidePanel() => InitializeComponent();

    protected override void OnAttach()
    {
        if (!ReferenceEquals(_for, Tab))
        {
            _opened.Clear();
            _for = Tab;
        }
        Tab!.Changed += Tab_Changed;
        Build();
    }

    protected override void OnDetach()
    {
        Tab!.Changed -= Tab_Changed;
        Tree.ItemsSource = null;
    }

    private void Tab_Changed(object? sender, EventArgs e) => Build();

    private void Build()
    {
        var items = Outline.Read(Tab!.Document).Items;
        Tree.ItemsSource = items.Select((item, i) => new BookmarkNode(item, i.ToString(), _opened)).ToList();
        Empty.Visibility = items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Tree.Visibility = items.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Go(BookmarkNode node)
    {
        if (Viewer is not { } viewer) return;
        if (node.Item.Destination is { } destination) viewer.GoToDestination(destination);
        else viewer.FollowAction(node.Item.Action);
    }

    // A click on the entry, not on its arrow, goes there; a click on the entry that is already selected too.
    private void Tree_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        for (var at = e.OriginalSource as DependencyObject; at is not null; at = System.Windows.Media.VisualTreeHelper.GetParent(at))
        {
            if (at is ToggleButton) return;
            if (at is TreeViewItem { DataContext: BookmarkNode node })
            {
                Go(node);
                return;
            }
        }
    }

    private void Tree_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && Tree.SelectedItem is BookmarkNode node)
        {
            Go(node);
            e.Handled = true;
        }
    }
}
