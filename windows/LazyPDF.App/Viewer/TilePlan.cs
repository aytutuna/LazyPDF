using System.Windows;

namespace LazyPDF.App.Viewer;

/// <summary>
/// One picture of a page. <paramref name="Scale"/> is device pixels per point. A tile is square-ish piece of the
/// page at that scale, in a fixed grid; a preview (<paramref name="Column"/> = -1) is the whole page at a low scale.
/// <paramref name="Version"/> changes when the page's own content changes, so a page an edit did not touch keeps its pictures.
/// </summary>
public readonly record struct TileKey(int Page, int Version, double Scale, int Column, int Row, PageTint Tint)
{
    public bool IsPreview => Column < 0;
}

/// <summary>A tile and the pixels of the page it covers, in the pixels of the page at the tile's scale.</summary>
public readonly record struct TileSpec(TileKey Key, int X, int Y, int Width, int Height);

/// <summary>Cuts a page into the tiles that are drawn through the renderer.</summary>
public static class TilePlan
{
    public const int TileSize = 512;

    /// <summary>The longest side, in pixels, of the picture of a whole page that stands in while the tiles come.</summary>
    public const int PreviewSide = 640;

    /// <param name="area">The part of the page that is wanted, in pixels of the page at <paramref name="scale"/>.</param>
    /// <param name="reachable">The size nearest a given one that the renderer can make.</param>
    public static List<TileSpec> Cover(int page, int version, PageTint tint, Size pagePoints, double scale, Rect area, Func<int, int> reachable)
    {
        var tiles = new List<TileSpec>();
        int step = reachable(TileSize);
        int width = (int)Math.Ceiling(pagePoints.Width * scale), height = (int)Math.Ceiling(pagePoints.Height * scale);
        area = Rect.Intersect(area, new Rect(0, 0, width, height));
        if (area.IsEmpty || step <= 0) return tiles;
        int c0 = (int)(area.Left / step), c1 = (int)Math.Ceiling(area.Right / step) - 1;
        int r0 = (int)(area.Top / step), r1 = (int)Math.Ceiling(area.Bottom / step) - 1;
        for (int r = r0; r <= r1; r++)
        {
            for (int c = c0; c <= c1; c++)
            {
                int x = c * step, y = r * step;
                tiles.Add(new TileSpec(new TileKey(page, version, scale, c, r, tint), x, y, Fit(width - x, step, reachable), Fit(height - y, step, reachable)));
            }
        }
        return tiles;
    }

    /// <summary>The scale of the preview of a page, in pixels per point.</summary>
    public static double PreviewScale(Size pagePoints) => PreviewSide / Math.Max(Math.Max(pagePoints.Width, pagePoints.Height), 1);

    public static TileSpec Preview(int page, int version, PageTint tint, Size pagePoints)
    {
        double scale = PreviewScale(pagePoints);
        return new TileSpec(new TileKey(page, version, scale, -1, -1, tint), 0, 0, (int)Math.Ceiling(pagePoints.Width * scale), (int)Math.Ceiling(pagePoints.Height * scale));
    }

    /// <summary>Where a tile lies on the page, in points; <paramref name="width"/> and <paramref name="height"/> are the size of the picture that came back.</summary>
    public static Rect PointsRect(TileSpec tile, int width, int height) =>
        new(tile.X / tile.Key.Scale, tile.Y / tile.Key.Scale, width / tile.Key.Scale, height / tile.Key.Scale);

    // The renderer cannot make every size; the last tile of a row takes the smallest it can make that still reaches the edge.
    private static int Fit(int remaining, int step, Func<int, int> reachable)
    {
        if (remaining >= step) return step;
        for (int size = remaining; size < remaining + 8; size++)
        {
            if (reachable(size) >= remaining) return size;
        }
        return remaining;
    }
}
