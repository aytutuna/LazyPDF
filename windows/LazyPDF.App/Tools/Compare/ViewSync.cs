using System.Windows;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Compare;

/// <summary>
/// Makes two viewers of the two files scroll and zoom together. The one under the pointer (else the one with the
/// keyboard) leads; the other is moved so that the same place of the paired page sits at the same place of its view.
/// </summary>
internal sealed class ViewSync
{
    // Reveal only moves when the area is outside the middle of the view, and then centres it; an area this big never fits.
    private const double Reach = 100000;

    private readonly IDocumentViewer _old;
    private readonly IDocumentViewer _new;
    private readonly IReadOnlyList<PagePair> _pairs;
    private bool _following;

    public ViewSync(IDocumentViewer old, IDocumentViewer @new, IReadOnlyList<PagePair> pairs)
    {
        _old = old;
        _new = @new;
        _pairs = pairs;
        _old.ViewChanged += Old_ViewChanged;
        _new.ViewChanged += New_ViewChanged;
    }

    public bool Enabled { get; set; } = true;

    public void Detach()
    {
        _old.ViewChanged -= Old_ViewChanged;
        _new.ViewChanged -= New_ViewChanged;
    }

    /// <summary>The page of the other file that stands for <paramref name="page"/>; a page without a partner takes its neighbour's.</summary>
    public static int Partner(IReadOnlyList<PagePair> pairs, int page, bool fromOld)
    {
        int at = pairs.ToList().FindIndex(p => (fromOld ? p.OldIndex : p.NewIndex) == page);
        if (at < 0) return -1;
        int Other(PagePair p) => fromOld ? p.NewIndex : p.OldIndex;
        for (int i = at; i < pairs.Count; i++)
        {
            if (Other(pairs[i]) >= 0) return Other(pairs[i]);
        }
        for (int i = at - 1; i >= 0; i--)
        {
            if (Other(pairs[i]) >= 0) return Other(pairs[i]);
        }
        return -1;
    }

    private void Old_ViewChanged(object? sender, EventArgs e) => Follow(_old, _new, fromOld: true);

    private void New_ViewChanged(object? sender, EventArgs e) => Follow(_new, _old, fromOld: false);

    private void Follow(IDocumentViewer leader, IDocumentViewer follower, bool fromOld)
    {
        if (!Enabled || _following || !Leads(leader.View, follower.View)) return;
        _following = true;
        try
        {
            if (follower.Fit != leader.Fit) follower.Fit = leader.Fit;
            if (leader.Fit == FitMode.None && Math.Abs(follower.Zoom - leader.Zoom) > 1e-6) follower.Zoom = leader.Zoom;
            var middle = new Point(leader.View.ActualWidth / 2, leader.View.ActualHeight / 2);
            if (leader.ViewToPage(middle, nearest: true) is not { } at) return;
            int page = Partner(_pairs, at.Page, fromOld);
            if (page < 0 || page >= follower.PageCount) return;
            Show(follower, page, at.Point, middle);
        }
        finally
        {
            _following = false;
        }
    }

    // The second reveal corrects for the bar above the pages, which the first one does not know about.
    private static void Show(IDocumentViewer viewer, int page, Point point, Point wanted)
    {
        viewer.Reveal(page, Around(point));
        if (viewer.PageToView(page) is not { } matrix || !matrix.HasInverse) return;
        matrix.Invert();
        var shown = matrix.Transform(wanted);
        var shift = point - shown;
        if (Math.Abs(shift.X) + Math.Abs(shift.Y) > 0.5) viewer.Reveal(page, Around(point + shift));
    }

    private static Rect Around(Point point) => new(point.X - Reach, point.Y - Reach, 2 * Reach, 2 * Reach);

    private static bool Leads(FrameworkElement view, FrameworkElement other) =>
        view.IsMouseOver || (!other.IsMouseOver && view.IsKeyboardFocusWithin);
}
