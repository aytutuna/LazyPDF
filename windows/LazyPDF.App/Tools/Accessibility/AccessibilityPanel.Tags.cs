using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Accessibility;

// The tag tree, and tagging a file that has none.
public partial class AccessibilityPanel
{
    // Children are put in the tree when their parent opens, so a large tree costs only what is looked at.
    private const int ChildrenShown = 200;

    private void RenderTags()
    {
        TagTree.Items.Clear();
        bool tagged = _tree is { Roots.Count: > 0 };
        TagTree.Visibility = tagged ? Visibility.Visible : Visibility.Collapsed;
        if (!tagged)
        {
            TagsNote.Text = _treeFailed ? Loc.T("The tags could not be read.")
                : _untagged ? Loc.T("The file has no tags. Add them so a screen reader can read it in order.")
                : Loc.T("The file says it is tagged but holds no tags. Lazy PDF cannot add them to it.");
            return;
        }
        TagsNote.Text = _tree!.IsTruncated
            ? Loc.T("The tree is too large to show whole. Pick a tag to go to its page.")
            : Loc.T("{0} tags. Pick one to go to its page.", _treeCount);
        foreach (var root in _tree.Roots.Take(ChildrenShown)) TagTree.Items.Add(Node(root));
    }

    private TreeViewItem Node(StructElement element)
    {
        string label = TagLabels.Of(element, _tree!);
        var item = new TreeViewItem { Header = label, Tag = element };
        AutomationProperties.SetName(item, label);
        if (element.Children.Any())
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
        var children = ((StructElement)item.Tag).Children.ToList();
        foreach (var child in children.Take(ChildrenShown)) item.Items.Add(Node(child));
        if (children.Count > ChildrenShown)
        {
            string more = Loc.T("{0} more", children.Count - ChildrenShown);
            var rest = new TreeViewItem { Header = more, IsEnabled = false };
            AutomationProperties.SetName(rest, more);
            item.Items.Add(rest);
        }
    }

    private void TagTree_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
    {
        if (e.NewValue is TreeViewItem { Tag: StructElement element } && FigureFinder.PageOf(element) is >= 0 and var page) Viewer?.GoToPage(page);
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
