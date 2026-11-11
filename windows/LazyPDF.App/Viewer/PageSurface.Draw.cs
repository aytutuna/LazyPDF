using System.Globalization;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

// Drawing: for each page in view its paper, then the best pictures there are, then what the viewer lays on top
// (the selection, the search hits). Nothing here waits for a tile; what has not come is drawn from a smaller one.
internal sealed partial class PageSurface
{
    /// <summary>Draws on top of a page's pictures; gets the page and the matrix from page space to the surface.</summary>
    public Action<DrawingContext, int, Matrix>? Decorate { get; set; }

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize));
        if (_layout.PageCount == 0) return;
        var edge = TryFindResource("DividerStrokeColorDefaultBrush") as Brush ?? Brushes.Gray;
        var paper = new SolidColorBrush(PageTints.Paper(_tint));
        paper.Freeze();
        var pen = new Pen(edge, 1);
        pen.Freeze();
        var shadow = new SolidColorBrush(Color.FromArgb(18, 0, 0, 0));
        shadow.Freeze();
        // The shadow token is taken away in the high contrast themes.
        bool shadowed = TryFindResource("PageShadow") is DropShadowEffect;
        foreach (int page in _layout.PagesIn(ViewRect))
        {
            var rect = _layout.PageRect(page);
            rect.Offset(-_offsetX, -_offsetY);
            var visible = Rect.Intersect(rect, new Rect(RenderSize));
            if (visible.IsEmpty) continue;
            if (shadowed) dc.DrawRectangle(shadow, null, new Rect(rect.X - 1.5, rect.Y - 0.5, rect.Width + 3, rect.Height + 4));
            dc.DrawRectangle(paper, pen, rect);
            var matrix = PageMatrix(page)!.Value;
            dc.PushClip(new RectangleGeometry(visible));
            DrawPictures(dc, page, matrix, rect);
            Decorate?.Invoke(dc, page, matrix);
            dc.Pop();
        }
    }

    private void DrawPictures(DrawingContext dc, int page, Matrix matrix, Rect pageRect)
    {
        double ppp = Scale * Dpi;
        int version = _versions[page];
        var preview = TilePlan.Preview(page, version, _tint, _sizes[page]);
        bool previewOnly = ppp <= preview.Key.Scale;
        var visible = Rect.Intersect(pageRect, new Rect(RenderSize));
        var content = visible;
        content.Offset(_offsetX, _offsetY);

        bool complete = previewOnly
            ? _cache.Contains(preview.Key)
            : Required(page, content).All(tile => _cache.Contains(tile.Key));
        bool sharp(TileKey key) => key.Version == version && (previewOnly ? key.IsPreview : !key.IsPreview && key.Scale == ppp);

        var keys = _cache.Keys(page).Where(key => key.Tint == _tint && (!complete || sharp(key))).ToList();
        keys.Sort((a, b) => Rank(a, version, ppp).CompareTo(Rank(b, version, ppp)));
        foreach (var key in keys)
        {
            if (_cache.Peek(key) is not { } bitmap) continue;
            var dest = Destination(key, bitmap, matrix, _sizes[page]);
            if (!dest.IntersectsWith(visible)) continue;
            _cache.Get(key);
            DrawBitmap(dc, bitmap, dest);
        }

        if (complete)
        {
            _cache.RemoveWhere(page, key => key.Tint != _tint || key.Version != version || (!sharp(key) && !key.IsPreview));
        }
        else if (_failed.Contains(preview.Key))
        {
            DrawFailure(dc, pageRect, Loc.T("This page cannot be shown."), false);
        }
        else if (NoteShown(page))
        {
            DrawFailure(dc, visible, Loc.T("Part of this page could not be drawn sharply."), true);
        }
    }

    // A tile that failed under an older version or tint says nothing about what is drawn now.
    internal bool NoteShown(int page)
    {
        double ppp = Scale * Dpi;
        int version = _versions[page];
        return _failed.Any(key => key.Page == page && !key.IsPreview && key.Scale == ppp && key.Version == version && key.Tint == _tint);
    }

    // Older pictures first, then the smaller ones, the current page's own preview, other zooms by how near they are, the sharp tiles last.
    private static double Rank(TileKey key, int version, double ppp)
    {
        double rank = key.Version == version ? 1000 : 0;
        if (key.IsPreview) return rank;
        return rank + 500 - Math.Abs(Math.Log(key.Scale / ppp)) * 10;
    }

    internal static Rect Destination(TileKey key, BitmapSource bitmap, Matrix matrix, Size page)
    {
        var points = key.IsPreview
            ? new Rect(0, 0, page.Width, page.Height)
            : TilePlan.PointsRect(new TileSpec(key, key.Column * TileStep, key.Row * TileStep, 0, 0), bitmap.PixelWidth, bitmap.PixelHeight);
        return PageSpace.Transform(matrix, points);
    }

    private static readonly int TileStep = LazyPDF.App.Services.WindowsPageRenderer.Reachable(TilePlan.TileSize);

    // Away from zero, so that the edge two neighbours share lands on the same device pixel for both.
    internal static Rect SnapRect(Rect dest, double ppd)
    {
        double snap(double v) => Math.Round(v * ppd, MidpointRounding.AwayFromZero) / ppd;
        return new Rect(new Point(snap(dest.Left), snap(dest.Top)), new Point(snap(dest.Right), snap(dest.Bottom)));
    }

    private void DrawBitmap(DrawingContext dc, BitmapSource bitmap, Rect dest)
    {
        double ppd = Dpi;
        var snapped = SnapRect(dest, ppd);
        // The picture is of the page upright; it is turned about the centre of the rectangle the matrix gave.
        var c = new Point(snapped.Left + snapped.Width / 2, snapped.Top + snapped.Height / 2);
        bool sideways = _rotation == 90 || _rotation == 270;
        var upright = sideways ? new Rect(c.X - snapped.Height / 2, c.Y - snapped.Width / 2, snapped.Height, snapped.Width) : snapped;
        // Aliased edges and an unscaled copy keep neighbouring tiles from showing a seam.
        var group = new DrawingGroup();
        RenderOptions.SetEdgeMode(group, EdgeMode.Aliased);
        if (Math.Round(upright.Width * ppd) == bitmap.PixelWidth && Math.Round(upright.Height * ppd) == bitmap.PixelHeight)
        {
            RenderOptions.SetBitmapScalingMode(group, BitmapScalingMode.NearestNeighbor);
        }
        if (_rotation != 0) group.Transform = new RotateTransform(_rotation, c.X, c.Y);
        using (var inner = group.Open())
        {
            inner.DrawImage(bitmap, upright);
        }
        group.Freeze();
        dc.DrawDrawing(group);
    }

    private void DrawFailure(DrawingContext dc, Rect pageRect, string message, bool atBottom)
    {
        var text = new FormattedText(message, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            new Typeface(TextElement.GetFontFamily(this), System.Windows.FontStyles.Normal, FontWeights.Normal, FontStretches.Normal), 14, _tint == PageTint.Dark ? Brushes.Gainsboro : Brushes.DimGray, Dpi)
        {
            MaxTextWidth = Math.Max(10, pageRect.Width - 24),
            TextAlignment = System.Windows.TextAlignment.Center,
        };
        double top = atBottom ? pageRect.Bottom - text.Height - 8 : pageRect.Top + Math.Min(pageRect.Height / 2, 120) - text.Height / 2;
        dc.DrawText(text, new Point(pageRect.Left + 12, top));
    }
}
