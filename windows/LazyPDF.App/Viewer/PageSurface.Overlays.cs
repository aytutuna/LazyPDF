using System.Windows;
using System.Windows.Media;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

// The things kept per page for tools: overlay layers and the page geometry that turns page space into PDF user space.
internal sealed partial class PageSurface
{
    private readonly Dictionary<int, PageOverlay> _overlays = [];
    private readonly Dictionary<int, PageGeometry> _geometry = [];

    /// <summary>The engine's geometry of a page (user space to page space and back), valid for this revision of the file.</summary>
    public PageGeometry Geometry(int page)
    {
        if (!_geometry.TryGetValue(page, out var geometry)) _geometry[page] = geometry = new PageGeometry(_tab!.Document.Pages[Math.Min(page, _tab.Document.Pages.Count - 1)]);
        return geometry;
    }

    public PageOverlay Overlay(int page)
    {
        if (!_overlays.TryGetValue(page, out var overlay)) _overlays[page] = overlay = new PageOverlay(page, PageSize(page));
        PlaceOverlays();
        return overlay;
    }

    private void ClearOverlays()
    {
        foreach (var overlay in _overlays.Values) InternalChildren.Remove(overlay);
        _overlays.Clear();
    }

    // After a reload the pages may have other sizes, or be gone.
    private void SyncOverlays()
    {
        foreach (var (page, overlay) in _overlays.ToList())
        {
            if (page >= _sizes.Length)
            {
                InternalChildren.Remove(overlay);
                _overlays.Remove(page);
                continue;
            }
            overlay.Width = _sizes[page].Width;
            overlay.Height = _sizes[page].Height;
        }
    }

    private void PlaceOverlays()
    {
        if (_overlays.Count == 0) return;
        var near = Rect.Inflate(ViewRect, ViewRect.Width, ViewRect.Height);
        foreach (var (page, overlay) in _overlays)
        {
            bool show = _layout.Contains(page) && _layout.PageRect(page).IntersectsWith(near);
            if (!show)
            {
                InternalChildren.Remove(overlay);
                continue;
            }
            if (!InternalChildren.Contains(overlay)) InternalChildren.Add(overlay);
            overlay.RenderTransform = new MatrixTransform(PageMatrix(page)!.Value);
        }
    }
}
