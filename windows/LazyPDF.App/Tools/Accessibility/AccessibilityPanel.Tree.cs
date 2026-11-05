using LazyPDF.App.Tools.Standards;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Accessibility;

// The tag tree of the file, read from a copy off the UI thread; the tags and figures views both show it.
public partial class AccessibilityPanel
{
    private StructureTree? _tree;
    private PdfDocument? _treeCopy;
    private IReadOnlyList<FigureRow> _figures = [];
    private int _treeCount;
    private bool _treeFailed;
    private int _treeTicket;

    private async Task LoadTreeAsync()
    {
        int ticket = ++_treeTicket;
        _treeStale = false;
        DropTree();
        TagTree.Items.Clear();
        FigureList.ItemsSource = null;
        TagsNote.Text = FiguresNote.Text = Loc.T("Reading the tags");
        var open = OpenCopy.Of(Tab!);
        try
        {
            var (copy, tree, figures, count) = await Task.Run(() =>
            {
                var copy = open();
                var tree = StructureTree.Read(copy);
                return (copy, tree, tree is null ? Array.Empty<FigureRow>() : FigureFinder.List(tree), tree?.Elements.Count() ?? 0);
            });
            if (ticket != _treeTicket) return;
            (_treeCopy, _tree, _figures, _treeCount) = (copy, tree, figures, count);
        }
        catch (Exception error) when (error is PdfReadException or InvalidOperationException)
        {
            if (ticket != _treeTicket) return;
            _treeFailed = true;
        }
        RenderTags();
        RenderFigures();
    }

    // The copy is let go, not disposed: a picture being found may still be reading it.
    private void DropTree() => (_tree, _treeCopy, _figures, _treeCount, _treeFailed) = (null, null, [], 0, false);
}
