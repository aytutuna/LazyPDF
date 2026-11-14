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
        var before = _state.Checked;
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
            if (Tab!.Rewrites != _state.Rewrites)
            {
                // Save compact numbers the objects again, so a draft follows its figure by place.
                _state.Rewrites = Tab.Rewrites;
                var kept = _state.Drafts.ToList();
                _state.Drafts.Clear();
                foreach (var (key, text) in kept)
                    if (before.FirstOrDefault(f => f.Key == key) is { } old && figures.FirstOrDefault(f => f.Number == old.Number && f.Page == old.Page && f.Alt == old.Alt) is { } now) _state.Drafts[now.Key] = text;
            }
            // A draft stays while its figure is still there with the description it was typed against, or the one just saved from here.
            else foreach (int key in _state.Drafts.Keys.ToList())
                if (figures.FirstOrDefault(f => f.Key == key) is not { } now
                    || (before.FirstOrDefault(f => f.Key == key)?.Alt != now.Alt && !(_state.Written.TryGetValue(key, out var written) && written == now.Alt))) _state.Drafts.Remove(key);
            _state.Written.Clear();
            _state.Checked = figures;
            SyncPending();
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
