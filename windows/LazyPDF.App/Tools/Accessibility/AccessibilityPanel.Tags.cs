using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Certificates;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Accessibility;

// The tag tree, and tagging a file that has none.
public partial class AccessibilityPanel
{
    // Children are put in the tree when their parent opens, so a large tree costs only what is looked at.
    private const int ChildrenShown = 200;

    private static readonly Brush MarkFill = Frozen(Color.FromArgb(56, 0, 120, 215));

    private static Brush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    private TagFilter? _filter;
    private TagView? _view;
    private bool _restoring;
    private string? _keepFields;
    private int _boxTicket;
    private readonly List<(Canvas Overlay, Rectangle Mark)> _marks = [];

    // What the tree gives back after it is built again: the node picked, the nodes opened and where the keyboard was.
    private sealed record TagView(string? Selected, HashSet<string> Open, bool InTree, FrameworkElement? Focus);

    private StructKid? SelectedKid => (TagTree.SelectedItem as TreeViewItem)?.Tag as StructKid;

    private void RenderTags()
    {
        TagTree.Items.Clear();
        bool tagged = _tree is { Roots.Count: > 0 };
        TagTree.Visibility = tagged ? Visibility.Visible : Visibility.Collapsed;
        TagsTools.Visibility = tagged ? Visibility.Visible : Visibility.Collapsed;
        TagSelectionTools.Visibility = tagged ? Visibility.Visible : Visibility.Collapsed;
        if (!tagged)
        {
            TagsNote.Text = _treeFailed ? Loc.T("The tags could not be read.")
                : _untagged ? Loc.T("The file has no tags. Add them so a screen reader can read it in order.")
                : Loc.T("The file says it is tagged but holds no tags. Lazy PDF cannot add them to it.");
            _tagReadOnly = null;
            TagsReadOnlyRow.Visibility = Visibility.Collapsed;
            ShowTagEditor(null);
            _view = null;
            return;
        }
        _tagReadOnly = TagEdits.ReadOnlyReason(Tab!.Document, _tree);
        TagsReadOnlyRow.Visibility = _tagReadOnly is null ? Visibility.Collapsed : Visibility.Visible;
        TagsReadOnly.Text = _tagReadOnly ?? "";
        string tagAs = TagAs.Text;
        TagType.ItemsSource = TagAs.ItemsSource = TagEdits.Types(_tree!);
        TagAs.Text = tagAs.Length > 0 ? tagAs : "P";
        if (TagScope.Items.Count == 0) TagScope.ItemsSource = new[] { Loc.T("Not set"), Loc.T("Row"), Loc.T("Column"), Loc.T("Both") };
        _filter = TagFilter.Of(_tree!, TagFilterBox.Text);
        TagsNote.Text = _filter is not null
            ? _filter.IsCapped ? Loc.T("The first {0} matches are shown.", TagFilter.Limit) : Loc.T("{0} tags match.", _filter.Matches)
            : _tree!.IsTruncated ? Loc.T("The tree is too large to show whole. Pick a tag to go to its page.")
            : Loc.T("{0} tags. Pick one to go to its page.", _treeCount);
        foreach (var root in _tree.Roots.Where(r => _filter is null || _filter.Shown.Contains(r)).Take(ChildrenShown)) TagTree.Items.Add(Node(root));
        if (_keepFields is null) ShowTagEditor(null);
        if (_view is not { } view) return;
        _view = null;
        _restoring = true;
        Restore(TagTree, view);
        _restoring = false;
        Refocus(view);
    }

    private TreeViewItem Node(StructKid kid)
    {
        string label = TagLabels.Of(kid, _tree!);
        var item = new TreeViewItem { Header = label, Tag = kid };
        AutomationProperties.SetName(item, label);
        if (kid is not StructElement element) return item;
        if (_filter is { } filter)
        {
            foreach (var child in element.Children.Where(filter.Shown.Contains).Take(ChildrenShown)) item.Items.Add(Node(child));
            item.IsExpanded = item.Items.Count > 0;
        }
        else if (element.Kids.Count > 0)
        {
            item.Items.Add(new TreeViewItem());
            item.Expanded += Node_Expanded;
        }
        return item;
    }

    private void Node_Expanded(object sender, RoutedEventArgs e)
    {
        var item = (TreeViewItem)sender;
        item.Expanded -= Node_Expanded;
        e.Handled = true;
        item.Items.Clear();
        var kids = ((StructElement)item.Tag).Kids;
        foreach (var kid in kids.Take(ChildrenShown)) item.Items.Add(Node(kid));
        if (kids.Count > ChildrenShown)
        {
            string more = Loc.T("{0} more", kids.Count - ChildrenShown);
            var rest = new TreeViewItem { Header = more, IsEnabled = false };
            AutomationProperties.SetName(rest, more);
            item.Items.Add(rest);
        }
    }

    private TagView CaptureTags()
    {
        var open = new HashSet<string>();
        void Walk(ItemsControl parent)
        {
            foreach (var item in parent.Items.OfType<TreeViewItem>())
            {
                if (item.Tag is not StructKid kid || !item.IsExpanded) continue;
                open.Add(TagPath.KeyOf(kid));
                Walk(item);
            }
        }
        Walk(TagTree);
        var focus = Keyboard.FocusedElement as FrameworkElement;
        bool inTree = focus is not null && (ReferenceEquals(focus, TagTree) || TagTree.IsAncestorOf(focus));
        return new TagView(SelectedKid is { } kid ? TagPath.KeyOf(kid) : null, open, inTree, !inTree && focus is not null && TagsView.IsAncestorOf(focus) ? focus : null);
    }

    private void Restore(ItemsControl parent, TagView view)
    {
        foreach (var item in parent.Items.OfType<TreeViewItem>().ToList())
        {
            if (item.Tag is not StructKid kid) continue;
            string key = TagPath.KeyOf(kid);
            if (key == view.Selected) item.IsSelected = true;
            if (view.Open.Contains(key) && item.Items.Count > 0)
            {
                item.IsExpanded = true;
                Restore(item, view);
            }
            else if (item.IsExpanded)
            {
                Restore(item, view);
            }
        }
    }

    // Items have no container until the tree is laid out, so the keyboard is given back then.
    private void Refocus(TagView view) => Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
    {
        if (view.InTree)
        {
            if (TagTree.SelectedItem is TreeViewItem selected) selected.Focus();
            else TagTree.Focus();
        }
        else if (view.Focus is { IsVisible: true, IsEnabled: true, IsKeyboardFocusWithin: false } control)
        {
            control.Focus();
        }
    });

    private void TagFilter_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_tree is null || Tab is null) return;
        _view = CaptureTags();
        // Typing in the filter builds the tree again, but what is typed in the editor and not applied yet stays.
        _keepFields = SelectedKid is StructElement picked ? TagPath.KeyOf(picked) : null;
        RenderTags();
        if (_keepFields is not null && SelectedKid is null) ShowTagEditor(null);
        _keepFields = null;
    }

    private void TagTree_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
    {
        var kid = (e.NewValue as TreeViewItem)?.Tag as StructKid;
        if (kid is null && _keepFields is not null) return;
        if (kid is not null && TagPath.KeyOf(kid) == _keepFields) UpdateTagButtons(kid);
        else ShowTagEditor(kid);
        if (kid is not null && !_restoring && PageOfKid(kid) is >= 0 and var page) Viewer?.GoToPage(page);
        _ = ShowMarksAsync(kid);
    }

    private static int PageOfKid(StructKid kid) => kid switch
    {
        StructElement element => FigureFinder.PageOf(element),
        StructContent content => content.PageIndex,
        StructObject target => target.PageIndex,
        _ => -1,
    };

    // The selected element's content, outlined on its pages; the outlines go when another node is picked or the tree is read again.
    private async Task ShowMarksAsync(StructKid? kid)
    {
        int ticket = ++_boxTicket;
        ClearMarks();
        if (kid is not StructElement element || _tree is not { } tree || _treeCopy is not { } copy || Viewer is null || ShowTags.IsChecked != true) return;
        var found = await Task.Run(() =>
        {
            lock (copy) return ticket == _boxTicket ? tree.Boxes(element) : null;
        });
        if (found is null || ticket != _boxTicket || Viewer is not { } viewer) return;
        foreach (var box in found.Boxes)
        {
            var area = viewer.Geometry(box.PageIndex).ToDisplay(box.Rect);
            var mark = new Rectangle { Fill = MarkFill, StrokeThickness = 1, IsHitTestVisible = false };
            mark.SetResourceReference(Shape.StrokeProperty, "AccentFillColorDefaultBrush");
            SignatureBoxTool.Place(mark, new Rect(area.X, area.Y, area.Width, area.Height));
            var overlay = viewer.Overlay(box.PageIndex);
            overlay.Children.Add(mark);
            _marks.Add((overlay, mark));
        }
    }

    private void ClearMarks()
    {
        foreach (var (overlay, mark) in _marks) overlay.Children.Remove(mark);
        _marks.Clear();
    }

    private async Task AddTagsAsync()
    {
        if (Tab is not { } tab || Host is not { } host) return;
        await ChangeGate.RunAsync(tab, host, _tag.Text, async () =>
        {
            if (!ReferenceEquals(tab, Tab)) return;
            var document = tab.Document;
            bool signed = document.IsSigned;
            AutoTagResult? result = null;
            var options = AccessibilityEdits.TagOptions((CheckList.ItemsSource as IEnumerable<CheckRow>)?.FirstOrDefault(r => r.Editor == RowEditor.Language)?.Value);
            IsEnabled = false;
            try
            {
                await host.RunBusyAsync(Loc.T("Adding tags"), async token =>
                {
                    try
                    {
                        result = await Task.Run(() => AutoTagger.Tag(document, options, token));
                    }
                    catch (Exception error) when (error is OperationCanceledException or PdfReadException or InvalidOperationException)
                    {
                        // Tagging edits the document as it goes, so a stop or a failure takes back what it did.
                        tab.Session.Discard();
                        if (error is OperationCanceledException) throw;
                        NotTagged(host);
                    }
                });
            }
            finally
            {
                IsEnabled = true;
            }
            if (result is not null) Report(tab, host, result, signed);
        });
    }

    private static void NotTagged(IToolHost host) =>
        host.ShowProblem(new Problem(Loc.T("Tags not added"), Loc.T("The pages could not be tagged. Save a copy of the file and try again.")));

    private void Report(DocumentTab tab, IToolHost host, AutoTagResult result, bool signed)
    {
        if (result.AlreadyTagged)
        {
            host.ShowNotice(Loc.T("Already tagged"), Loc.T("The file has tags, so none were added. Look at them in the tag tree."));
            return;
        }
        if (result.Pages == 0)
        {
            host.ShowProblem(new Problem(Loc.T("Nothing to tag"), Loc.T("No page could be tagged. Scans need text recognition first. Pages that share content cannot be tagged.")));
            return;
        }
        try
        {
            if (!tab.Commit(Loc.T("Add tags"))) return;
        }
        catch (PdfReadException)
        {
            tab.Session.Discard();
            NotTagged(host);
            return;
        }
        string counts = Loc.T("{0} pages tagged: {1} headings, {2} paragraphs, {3} lists, {4} tables, {5} figures.",
            result.Pages, result.Headings, result.Paragraphs, result.Lists, result.Tables, result.Figures);
        string skipped = result.SkippedPages > 0 ? " " + Loc.T("{0} pages were left as they were.", result.SkippedPages) : "";
        string broken = signed ? " " + Loc.T("The signatures no longer hold.") : "";
        var describe = result.FiguresWithoutAlt.Count > 0 ? new NoticeAction(Loc.T("Describe figures"), () => ShowFigures.IsChecked = true) : null;
        host.ShowNotice(Loc.T("Tags added"), counts + skipped + broken, describe);
        host.SetStatus(Loc.T("Tags added."));
    }
}
