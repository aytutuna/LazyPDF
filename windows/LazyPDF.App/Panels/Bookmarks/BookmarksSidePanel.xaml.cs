using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Tools.EditContent;
using LazyPDF.Core;

namespace LazyPDF.App.Panels.Bookmarks;

/// <summary>An outline entry in the tree. Whether it is open is remembered by the panel, by the entry's place in the outline.</summary>
public sealed class BookmarkNode(OutlineItem item, string path, Dictionary<string, bool> opened) : INotifyPropertyChanged
{
    private bool _editing;
    private bool _selected;

    public event PropertyChangedEventHandler? PropertyChanged;

    public OutlineItem Item { get; } = item;

    public string Path { get; } = path;

    public string Title => Item.Title;

    public string EditText { get; set; } = item.Title;

    public FontWeight Weight => Item.Bold ? FontWeights.SemiBold : FontWeights.Normal;

    public FontStyle Style => Item.Italic ? System.Windows.FontStyles.Italic : System.Windows.FontStyles.Normal;

    public List<BookmarkNode> Children { get; } = [.. item.Children.Select((child, i) => new BookmarkNode(child, path + "." + i, opened))];

    public bool IsExpanded
    {
        get => opened.TryGetValue(path, out bool open) ? open : Item.IsOpen;
        set => opened[path] = value;
    }

    public bool IsEditing
    {
        get => _editing;
        set
        {
            if (value) EditText = Title;
            _editing = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(EditText)));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsEditing)));
        }
    }

    public bool IsSelected
    {
        get => _selected;
        set
        {
            _selected = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected)));
        }
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
        ExpandAllButton.Visibility = CollapseAllButton.Visibility = Tree.Visibility;
        UpdateEnabled();
    }

    private void UpdateEnabled()
    {
        bool editable = Clearance.Refusal(Tab!.Document) is null;
        bool selected = editable && Tree.SelectedItem is BookmarkNode;
        AddButton.IsEnabled = AddItem.IsEnabled = editable;
        RenameButton.IsEnabled = RenameItem.IsEnabled = selected;
        DeleteButton.IsEnabled = DeleteItem.IsEnabled = selected;
        var (canUp, canDown, canOut, canIn) = Shifts(selected ? (BookmarkNode)Tree.SelectedItem : null);
        MoveUpItem.IsEnabled = canUp;
        MoveDownItem.IsEnabled = canDown;
        OutdentItem.IsEnabled = canOut;
        IndentItem.IsEnabled = canIn;
    }

    private (bool Up, bool Down, bool Out, bool In) Shifts(BookmarkNode? node)
    {
        if (node is null) return default;
        int dot = node.Path.LastIndexOf('.');
        int index = int.Parse(node.Path[(dot + 1)..]);
        int count = dot < 0 ? ((List<BookmarkNode>)Tree.ItemsSource).Count : NodeAt(node.Path[..dot])!.Children.Count;
        return (index > 0, index < count - 1, dot >= 0, index > 0);
    }

    private void Tree_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
    {
        if (Tab is not null) UpdateEnabled();
    }

    // Null when the file may not be changed now; a refusal is shown with its reason.
    private (DocumentTab Tab, IToolHost Host)? Editable()
    {
        if (Tab is not { } tab || Host is not { } host || MarkWork.Running) return null;
        if (Clearance.Refusal(tab.Document) is { } problem)
        {
            host.ShowProblem(problem);
            return null;
        }
        return (tab, host);
    }

    // For a change held back by the notice: the same tab and entry are still there when the answer comes.
    private bool Still(DocumentTab tab, BookmarkNode? node = null) =>
        ReferenceEquals(Tab, tab) && !MarkWork.Running && Clearance.Refusal(tab.Document) is null && (node is null || ReferenceEquals(NodeAt(node.Path), node));

    private static VirtualizingPanel? PanelOf(DependencyObject at)
    {
        for (int i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(at); i++)
        {
            var child = System.Windows.Media.VisualTreeHelper.GetChild(at, i);
            if (child is VirtualizingPanel panel) return panel;
            if (PanelOf(child) is { } inner) return inner;
        }
        return null;
    }

    // The tree is virtualized, so an entry off screen has no container until it is scrolled to.
    private void Select(BookmarkNode node)
    {
        ItemsControl level = Tree;
        string[] parts = node.Path.Split('.');
        for (int depth = 0; depth < parts.Length; depth++)
        {
            level.UpdateLayout();
            int index = int.Parse(parts[depth]);
            if (level.ItemContainerGenerator.ContainerFromIndex(index) is null && PanelOf(level) is { } panel)
            {
                panel.BringIndexIntoViewPublic(index);
                level.UpdateLayout();
            }
            if (level.ItemContainerGenerator.ContainerFromIndex(index) is not TreeViewItem item)
            {
                node.IsSelected = true;
                return;
            }
            if (depth < parts.Length - 1) item.IsExpanded = true;
            level = item;
        }
        var target = (TreeViewItem)level;
        target.BringIntoView();
        target.IsSelected = true;
    }

    // Reads the outline again for an edit, keeping the entries the person opened or closed.
    private Outline ReadForEdit(DocumentTab tab)
    {
        var outline = Outline.Read(tab.Document);
        Keep(outline.Items, "");
        _opened.Clear();
        return outline;

        void Keep(IReadOnlyList<OutlineItem> items, string prefix)
        {
            for (int i = 0; i < items.Count; i++)
            {
                string path = prefix + i;
                if (_opened.TryGetValue(path, out bool open)) items[i].IsOpen = open;
                Keep(items[i].Children, path + ".");
            }
        }
    }

    private static OutlineItem? Find(Outline outline, string path)
    {
        var at = outline.Root;
        foreach (string part in path.Split('.'))
        {
            if (!int.TryParse(part, out int i) || i >= at.Children.Count) return null;
            at = at.Children[i];
        }
        return at;
    }

    private BookmarkNode? NodeAt(string path)
    {
        BookmarkNode? at = null;
        var level = Tree.ItemsSource as List<BookmarkNode>;
        foreach (string part in path.Split('.'))
        {
            if (level is null || !int.TryParse(part, out int i) || i >= level.Count) return null;
            at = level[i];
            level = at.Children;
        }
        return at;
    }

    private static string Join(string parent, int index) => parent.Length == 0 ? index.ToString() : parent + "." + index;

    private void Add_Click(object sender, RoutedEventArgs e)
    {
        var selected = Tree.SelectedItem as BookmarkNode;
        if (Editable() is not var (tab, host) || MarkWork.Cautioned(tab, host, () => Add(tab, host, selected))) return;
        Add(tab, host, selected);
    }

    private void Add(DocumentTab tab, IToolHost host, BookmarkNode? selected)
    {
        if (Viewer is not { } viewer || !Still(tab, selected)) return;
        var outline = ReadForEdit(tab);
        var parent = outline.Root;
        string parentPath = "";
        int index = outline.Items.Count;
        if (selected is not null && Find(outline, selected.Path) is { Parent: { } up } sibling)
        {
            parent = up;
            int dot = selected.Path.LastIndexOf('.');
            parentPath = dot < 0 ? "" : selected.Path[..dot];
            index = up.Children.ToList().IndexOf(sibling) + 1;
        }
        outline.Add(new OutlineItem
        {
            Title = Loc.T("Page {0}", viewer.PageLabel(viewer.PageIndex)),
            Destination = new PdfDestination(viewer.PageIndex, DestinationFit.Xyz),
        }, ReferenceEquals(parent, outline.Root) ? null : parent, index);
        outline.Write(tab.Document);
        if (!MarkWork.Commit(tab, host, Loc.T("Add bookmark")) || NodeAt(Join(parentPath, index)) is not { } added) return;
        Select(added);
        added.IsEditing = true;
    }

    private void Rename_Click(object sender, RoutedEventArgs e)
    {
        if (RenameButton.IsEnabled && Tree.SelectedItem is BookmarkNode node) node.IsEditing = true;
    }

    private void Rename(BookmarkNode node)
    {
        node.IsEditing = false;
        string title = node.EditText.Trim();
        if (title.Length == 0 || title == node.Title || Editable() is not var (tab, host) || MarkWork.Cautioned(tab, host, () => RenameTo(tab, host, node, title))) return;
        RenameTo(tab, host, node, title);
    }

    private void RenameTo(DocumentTab tab, IToolHost host, BookmarkNode node, string title)
    {
        if (!Still(tab, node)) return;
        var outline = ReadForEdit(tab);
        if (Find(outline, node.Path) is not { } item) return;
        item.Title = title;
        outline.Write(tab.Document);
        MarkWork.Commit(tab, host, Loc.T("Rename bookmark"));
    }

    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (Tree.SelectedItem is not BookmarkNode node || Editable() is not var (tab, host) || MarkWork.Cautioned(tab, host, () => Delete(tab, host, node))) return;
        Delete(tab, host, node);
    }

    private void Delete(DocumentTab tab, IToolHost host, BookmarkNode node)
    {
        if (!Still(tab, node)) return;
        var outline = ReadForEdit(tab);
        if (Find(outline, node.Path) is not { } item) return;
        outline.Remove(item);
        outline.Write(tab.Document);
        if (!MarkWork.Commit(tab, host, Loc.T("Delete bookmark"))) return;
        host.SetStatus(Loc.T("Bookmark deleted."));
        int dot = node.Path.LastIndexOf('.');
        string parentPath = dot < 0 ? "" : node.Path[..dot];
        int index = int.Parse(node.Path[(dot + 1)..]);
        var next = NodeAt(Join(parentPath, index)) ?? (index > 0 ? NodeAt(Join(parentPath, index - 1)) : null);
        if (next is not null) Select(next);
    }

    private void MoveUp_Click(object sender, RoutedEventArgs e) => Shift(0, -1);

    private void MoveDown_Click(object sender, RoutedEventArgs e) => Shift(0, 1);

    private void Outdent_Click(object sender, RoutedEventArgs e) => Shift(-1, 0);

    private void Indent_Click(object sender, RoutedEventArgs e) => Shift(1, 0);

    // dy moves among the siblings; dx -1 makes it the next sibling of its parent, 1 the last child of the sibling before it.
    private void Shift(int dx, int dy)
    {
        var (up, down, outdent, indent) = Shifts(Tree.SelectedItem as BookmarkNode);
        if (Tree.SelectedItem is not BookmarkNode node || !(dy < 0 ? up : dy > 0 ? down : dx < 0 ? outdent : indent)) return;
        if (Editable() is not var (tab, host) || MarkWork.Cautioned(tab, host, () => Shift(tab, host, node, dx, dy))) return;
        Shift(tab, host, node, dx, dy);
    }

    private void Shift(DocumentTab tab, IToolHost host, BookmarkNode node, int dx, int dy)
    {
        if (!Still(tab, node)) return;
        var outline = ReadForEdit(tab);
        if (Find(outline, node.Path) is not { Parent: { } parent } item) return;
        int dot = node.Path.LastIndexOf('.');
        string parentPath = dot < 0 ? "" : node.Path[..dot];
        int at = parent.Children.ToList().IndexOf(item);
        string moved;
        if (dy != 0)
        {
            outline.Move(item, ReferenceEquals(parent, outline.Root) ? null : parent, at + (dy < 0 ? -1 : 2));
            moved = Join(parentPath, at + dy);
        }
        else if (dx > 0)
        {
            var previous = parent.Children[at - 1];
            moved = Join(Join(parentPath, at - 1), previous.Children.Count);
            previous.IsOpen = true;
            outline.Move(item, previous);
        }
        else
        {
            int gdot = parentPath.LastIndexOf('.');
            string grandPath = gdot < 0 ? "" : parentPath[..gdot];
            int parentIndex = int.Parse(parentPath[(gdot + 1)..]);
            outline.Move(item, ReferenceEquals(parent.Parent, outline.Root) ? null : parent.Parent, parentIndex + 1);
            moved = Join(grandPath, parentIndex + 1);
        }
        outline.Write(tab.Document);
        if (MarkWork.Commit(tab, host, Loc.T("Move bookmark")) && NodeAt(moved) is { } now) Select(now);
    }

    private void EditBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is not BookmarkNode node || e.Key is not (Key.Enter or Key.Escape)) return;
        if (e.Key == Key.Escape) node.IsEditing = false;
        else if (node.IsEditing) Rename(node);
        Tree.Focus();
        e.Handled = true;
    }

    private void EditBox_LostFocus(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is BookmarkNode { IsEditing: true } node) Rename(node);
    }

    private void EditBox_IsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (e.NewValue is not true) return;
        var box = (TextBox)sender;
        box.Dispatcher.BeginInvoke(() =>
        {
            box.Focus();
            box.SelectAll();
        }, System.Windows.Threading.DispatcherPriority.Input);
    }

    private void SetAll(IReadOnlyList<OutlineItem> items, string prefix, bool open)
    {
        for (int i = 0; i < items.Count; i++)
        {
            string path = prefix + i;
            if (items[i].Children.Count == 0) continue;
            _opened[path] = open;
            SetAll(items[i].Children, path + ".", open);
        }
    }

    private void ExpandAll_Click(object sender, RoutedEventArgs e) => Open(true);

    private void CollapseAll_Click(object sender, RoutedEventArgs e) => Open(false);

    private void Open(bool open)
    {
        SetAll(Outline.Read(Tab!.Document).Items, "", open);
        Build();
    }

    private void Go(BookmarkNode node)
    {
        if (Viewer is not { } viewer) return;
        var destination = node.Item.Destination ?? (node.Item.Action as GoToAction)?.Destination;
        if (destination is not null && PdfDestinations.Locate(Tab!.Document, destination) is null)
        {
            Host?.SetStatus(Loc.T("This bookmark points to a page that is not in the file."));
            return;
        }
        if (destination is null && node.Item.Action is null) return;
        if (destination is null && node.Item.Action is GoToRemoteAction or LaunchAction)
        {
            Host?.SetStatus(Loc.T("This bookmark goes to another file, which Lazy PDF does not open from here."));
            return;
        }
        if (destination is null && node.Item.Action is not (GoToAction or UriAction or NamedAction))
        {
            Host?.SetStatus(Loc.T("This bookmark runs a script or sends a form, which Lazy PDF does not do."));
            return;
        }
        if (node.Item.Destination is { } own) viewer.GoToDestination(own);
        else viewer.FollowAction(node.Item.Action);
    }

    // A click on the entry, not on its arrow, goes there; a click on the entry that is already selected too.
    private void Tree_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        for (var at = e.OriginalSource as DependencyObject; at is not null; at = System.Windows.Media.VisualTreeHelper.GetParent(at))
        {
            if (at is ToggleButton or TextBox) return;
            if (at is TreeViewItem { DataContext: BookmarkNode node })
            {
                Go(node);
                return;
            }
        }
    }

    // A right-click does not select in a TreeView, and the menu acts on the selection.
    private void Tree_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        for (var at = e.OriginalSource as DependencyObject; at is not null; at = System.Windows.Media.VisualTreeHelper.GetParent(at))
        {
            if (at is not TreeViewItem item) continue;
            item.IsSelected = true;
            item.Focus();
            UpdateEnabled();
            return;
        }
    }

    // A title still being typed goes into the file before it is saved, closed or undone.
    public override bool HandIn()
    {
        if (Tab is not null && Tree.ItemsSource is List<BookmarkNode> nodes)
        {
            foreach (var node in Flatten(nodes).Where(n => n.IsEditing).ToList()) Rename(node);
        }
        return true;
    }

    private static IEnumerable<BookmarkNode> Flatten(IEnumerable<BookmarkNode> nodes) => nodes.SelectMany(n => Flatten(n.Children).Prepend(n));

    private void Tree_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.OriginalSource is TextBox || Tree.SelectedItem is not BookmarkNode node) return;
        if (Keyboard.Modifiers == ModifierKeys.Alt)
        {
            Action? shift = (e.Key == Key.System ? e.SystemKey : e.Key) switch
            {
                Key.Up => () => Shift(0, -1),
                Key.Down => () => Shift(0, 1),
                Key.Left => () => Shift(-1, 0),
                Key.Right => () => Shift(1, 0),
                _ => null,
            };
            if (shift is null) return;
            shift();
            e.Handled = true;
            return;
        }
        switch (e.Key)
        {
            case Key.Enter:
                Go(node);
                break;
            case Key.F2:
                Rename_Click(sender, e);
                break;
            case Key.Delete:
                Delete_Click(sender, e);
                break;
            default:
                return;
        }
        e.Handled = true;
    }
}
