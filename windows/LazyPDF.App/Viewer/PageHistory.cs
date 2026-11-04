namespace LazyPDF.App.Viewer;

/// <summary>The pages the reader jumped from, for Back and Forward. Scrolling is not a jump; a link, a bookmark or Go to page is.</summary>
public sealed class PageHistory
{
    private const int Limit = 100;

    private readonly List<int> _back = [];
    private readonly List<int> _forward = [];

    public bool CanGoBack => _back.Count > 0;

    public bool CanGoForward => _forward.Count > 0;

    /// <summary>Notes a jump from <paramref name="from"/> to <paramref name="to"/>; a jump to the same page, or the forward list, is forgotten.</summary>
    public void Jump(int from, int to)
    {
        if (from == to) return;
        if (_back.Count == 0 || _back[^1] != from) _back.Add(from);
        if (_back.Count > Limit) _back.RemoveAt(0);
        _forward.Clear();
    }

    /// <summary>The page to go back to from <paramref name="current"/>, or null.</summary>
    public int? Back(int current)
    {
        if (_back.Count == 0) return null;
        int page = _back[^1];
        _back.RemoveAt(_back.Count - 1);
        _forward.Add(current);
        return page;
    }

    public int? Forward(int current)
    {
        if (_forward.Count == 0) return null;
        int page = _forward[^1];
        _forward.RemoveAt(_forward.Count - 1);
        _back.Add(current);
        return page;
    }

    public void Clear()
    {
        _back.Clear();
        _forward.Clear();
    }
}
