using LazyPDF.Core;

namespace LazyPDF.App.Tools.Measure;

/// <summary>What identifies a page and its shape: a page that was turned, cropped or rescaled is not the one a measurement was taken on.</summary>
internal sealed record PageKey(int Number, int Rotate, PdfRect Box, double Unit)
{
    public static PageKey Of(PdfPage page) => new(page.Reference.Number, page.Rotate, page.CropBox, page.UserUnit);
}

/// <summary>A measurement waiting to be written, with the page it was taken on.</summary>
internal sealed record Pending(MeasureItem Item, PageKey Key)
{
    /// <summary>The ones whose page is still in the file as it was, moved to where that page is now.</summary>
    public static List<Pending> Keep(IEnumerable<Pending> pending, PdfDocument document)
    {
        var where = new Dictionary<int, (int Index, PageKey Key)>();
        for (int i = 0; i < document.Pages.Count; i++) where[document.Pages[i].Reference.Number] = (i, PageKey.Of(document.Pages[i]));
        return [.. pending.Where(p => where.TryGetValue(p.Key.Number, out var now) && now.Key == p.Key)
                          .Select(p => p with { Item = p.Item with { Page = where[p.Key.Number].Index } })];
    }
}
