using System.Windows.Media.Imaging;

namespace LazyPDF.App.Viewer;

/// <summary>
/// The pictures drawn so far, least recently used out first once their pixels pass a budget. Used from the
/// UI thread only; the bitmaps are frozen and may be made anywhere.
/// </summary>
public sealed class TileCache(long budget)
{
    private readonly Dictionary<TileKey, LinkedListNode<(TileKey Key, BitmapSource Bitmap)>> _nodes = [];
    private readonly Dictionary<int, HashSet<TileKey>> _byPage = [];
    private readonly LinkedList<(TileKey Key, BitmapSource Bitmap)> _order = new();

    /// <summary>Bytes of pixels held.</summary>
    public long Bytes { get; private set; }

    public int Count => _nodes.Count;

    public long Budget { get; } = budget;

    public bool Contains(TileKey key) => _nodes.ContainsKey(key);

    /// <summary>The picture, counted as just used.</summary>
    public BitmapSource? Get(TileKey key)
    {
        if (!_nodes.TryGetValue(key, out var node)) return null;
        _order.Remove(node);
        _order.AddFirst(node);
        return node.Value.Bitmap;
    }

    /// <summary>Adds a picture and lets go of the least recently used until the budget holds; the one just added stays.</summary>
    public void Add(TileKey key, BitmapSource bitmap)
    {
        Remove(key);
        _nodes[key] = _order.AddFirst((key, bitmap));
        if (!_byPage.TryGetValue(key.Page, out var keys)) _byPage[key.Page] = keys = [];
        keys.Add(key);
        Bytes += Size(bitmap);
        while (Bytes > Budget && _order.Count > 1) Remove(_order.Last!.Value.Key);
    }

    /// <summary>The keys held for a page, without counting them as used.</summary>
    public IReadOnlyCollection<TileKey> Keys(int page) => _byPage.TryGetValue(page, out var keys) ? keys : [];

    /// <summary>The picture, not counted as used: the drawing reads many and marks only the ones it shows.</summary>
    public BitmapSource? Peek(TileKey key) => _nodes.TryGetValue(key, out var node) ? node.Value.Bitmap : null;

    public void Remove(TileKey key)
    {
        if (!_nodes.Remove(key, out var node)) return;
        _order.Remove(node);
        Bytes -= Size(node.Value.Bitmap);
        if (_byPage.TryGetValue(key.Page, out var keys) && keys.Remove(key) && keys.Count == 0) _byPage.Remove(key.Page);
    }

    public void RemoveWhere(int page, Func<TileKey, bool> match)
    {
        foreach (var key in Keys(page).Where(match).ToList()) Remove(key);
    }

    public void Clear()
    {
        _nodes.Clear();
        _byPage.Clear();
        _order.Clear();
        Bytes = 0;
    }

    private static long Size(BitmapSource bitmap) => (long)bitmap.PixelWidth * bitmap.PixelHeight * 4;
}
