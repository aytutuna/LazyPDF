// The pending stamp drawn on the pages in view, until the user changes the form again or writes it.

using System.Windows;

namespace LazyPDF.App.Tools.Stamps;

public sealed partial class StampsPanel
{
    private readonly Dictionary<int, UIElement> _previews = [];
    private bool _previewOn = true;

    private void Viewer_ViewChanged(object? sender, EventArgs e) => UpdatePreview();

    private void UpdatePreview()
    {
        if (!_ready || Viewer is not { } viewer || Tab is not { } tab) return;
        var draft = _previewOn ? ReadDraft(out _) : null;
        var visible = viewer.VisiblePages.ToHashSet();
        foreach (int page in _previews.Keys.Where(p => !visible.Contains(p) || draft is null).ToList()) Clear(page);
        if (draft is null) return;

        var (pages, _) = PageChoice.Resolve((PageSet)PagesBox.SelectedIndex, PagesText.Text, tab.PageCount);
        var targets = PageChoice.Targets(pages, tab.PageCount);
        foreach (int page in visible)
        {
            Clear(page);
            int ordinal = targets.ToList().IndexOf(page);
            if (ordinal < 0) continue;
            var element = StampPreview.Build(draft, _pictureImage, page, tab.PageCount, ordinal, viewer.PageSize(page), tab.Title, DateTimeOffset.Now);
            if (element is null) continue;
            viewer.Overlay(page).Children.Add(element);
            _previews[page] = element;
        }
    }

    private void ClearPreviews()
    {
        foreach (int page in _previews.Keys.ToList()) Clear(page);
    }

    private void Clear(int page)
    {
        if (_previews.Remove(page, out var element)) Viewer?.Overlay(page).Children.Remove(element);
    }
}
