namespace LazyPDF.App.Viewer;

/// <summary>The places the reader jumped from, for Back and Forward. Scrolling is not a jump; a link, a bookmark or Go to page is.</summary>
public sealed class PageHistory
{
    private const int Limit = 100;
    private const double NearPoints = 50;

    private readonly List<PagePoint> _back = [];
    private readonly List<PagePoint> _forward = [];

    public bool CanGoBack => _back.Count > 0;

    public bool CanGoForward => _forward.Count > 0;

    /// <summary>Notes a jump from <paramref name="from"/> to <paramref name="to"/>; a jump within the same page's 50 points, or the forward list, is forgotten.</summary>
    public void Jump(PagePoint from, PagePoint to)
    {
        if (from.Page == to.Page && Math.Abs(from.Point.Y - to.Point.Y) < NearPoints) return;
        _back.Add(from);
        if (_back.Count > Limit) _back.RemoveAt(0);
        _forward.Clear();
    }

    /// <summary>The place to go back to from <paramref name="current"/>, or null.</summary>
    public PagePoint? Back(PagePoint current)
    {
        if (_back.Count == 0) return null;
        var place = _back[^1];
        _back.RemoveAt(_back.Count - 1);
        _forward.Add(current);
        return place;
    }

    public PagePoint? Forward(PagePoint current)
    {
        if (_forward.Count == 0) return null;
        var place = _forward[^1];
        _forward.RemoveAt(_forward.Count - 1);
        _back.Add(current);
        return place;
    }

    public void Clear()
    {
        _back.Clear();
        _forward.Clear();
    }
}
