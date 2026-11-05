using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Compare;

/// <summary>One file of a comparison as bytes, so the open document can go on changing while the comparison runs.</summary>
internal sealed record Side(byte[] Bytes, string Name, string? Password, X509Certificate2? Certificate)
{
    public static Side Of(DocumentTab tab) => new(tab.Session.Current.ToArray(), tab.Title, tab.Password, tab.Certificate);

    public static Side Of(DocumentTab tab, PdfVersion version) =>
        new(tab.Session.ExtractVersion(version), Loc.T("{0}, version {1}", tab.Title, version.Number), tab.Password, tab.Certificate);

    public static Side Of(string path, string? password, X509Certificate2? certificate) => new(File.ReadAllBytes(path), Path.GetFileName(path), password, certificate);
}

/// <summary>
/// Two files opened as documents of their own, the result of comparing them, and the rows that show it. The tabs
/// are for the side by side window and the renderers; nothing here touches the document the person has open.
/// </summary>
internal sealed class CompareSession : IDisposable
{
    public const int MaxPixelRows = 1000;

    private const double PixelDpi = 96;
    private const int RowsPerPage = 50;
    private const int ReportMarks = 5001;

    private readonly Side _before;
    private readonly Side _after;
    private List<(Parts Part, ChangeRow Row)> _rows = [];
    private List<ChangeRow> _pixelRows = [];
    private ComparisonResult? _pixelResult;

    public CompareSession(Side before, Side after, Func<IDocumentRenderer> renderers)
    {
        _before = before;
        _after = after;
        Old = Open(before, renderers);
        try
        {
            New = Open(after, renderers);
        }
        catch
        {
            Old.Dispose();
            throw;
        }
    }

    public DocumentTab Old { get; }

    public DocumentTab New { get; }

    /// <summary>What the content comparison found; the pages of a pixel comparison are paired from it as well.</summary>
    public ComparisonResult? Result { get; private set; }

    public bool ByPixels { get; private set; }

    /// <summary>Pairs of pages a pixel comparison looked at, and those it could not because one of them cannot be drawn.</summary>
    public int Looked { get; private set; }

    public int Undrawn { get; private set; }

    /// <summary>A pixel comparison found more areas than it lists.</summary>
    public bool PixelCapped { get; private set; }

    /// <summary>The report is a copy of the new file; a file that limits what readers may do can only be copied by its owner.</summary>
    public bool CanReport => New.Document.Security is not { OpenedAsOwner: false, Permissions: not PdfPermissions.All };

    public void Compare(CompareOptions options, bool byPixels, CancellationToken token)
    {
        var result = PdfComparer.Compare(Old.Document, New.Document, options, token);
        _rows = [.. result.Changes.Select(c => (ChangeParts.Of(c), ChangeRow.Of(c, Old.Document, New.Document)))];
        _pixelRows = [];
        _pixelResult = null;
        Looked = 0;
        Undrawn = 0;
        PixelCapped = false;
        if (byPixels) ComparePixels(result, token);
        ByPixels = byPixels;
        Result = result;
    }

    public IReadOnlyList<ChangeRow> Rows(Parts parts) =>
        ByPixels ? _pixelRows : [.. _rows.Where(r => parts.HasFlag(r.Part)).Select(r => r.Row)];

    /// <summary>The new page drawn with ink only it has in green and ink only the old page has in red; null when the page has no partner or cannot be drawn.</summary>
    public PdfRgbaImage? Overlay(int newPage)
    {
        var pair = Result?.Pages.FirstOrDefault(p => p.NewIndex == newPage && !p.IsAdded);
        return pair is null ? null : PixelComparer.Compare(Old.Renderer, pair.OldIndex, New.Renderer, newPage, PixelDpi)?.Overlay;
    }

    /// <summary>
    /// The new file with the differences marked. It works on documents read again from the bytes, since the tabs' own
    /// belong to the UI thread, and gives a protected file back with the protection it had.
    /// </summary>
    public byte[] Report(Parts parts, IFontSource fonts)
    {
        using var before = Reopen(_before);
        using var after = Reopen(_after);
        var result = ByPixels ? _pixelResult! : ChangeParts.Only(Result!, parts);
        string name = ByPixels || parts == Parts.All ? New.Title : Loc.T("{0} (filtered)", New.Title);
        byte[] report = ComparisonReport.Write(before, after, result, Old.Title, name, fonts);
        if (after.Security is not { } security) return report;
        using var plain = PdfDocument.Open(report);
        return plain.SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: after.FirstId));
    }

    public void Dispose()
    {
        Old.Dispose();
        New.Dispose();
    }

    private void ComparePixels(ComparisonResult result, CancellationToken token)
    {
        var rows = new List<ChangeRow>();
        var changes = new List<CompareChange>();
        int added = 0, removed = 0, areas = 0;
        foreach (var pair in result.Pages)
        {
            token.ThrowIfCancellationRequested();
            if (pair.IsAdded || pair.IsRemoved)
            {
                var change = new CompareChange(pair.IsAdded ? ChangeKind.Added : ChangeKind.Removed, ChangeArea.Page, pair.OldIndex, pair.NewIndex, "", "", [], [],
                    pair.IsAdded ? CompareText.PageAdded : CompareText.PageRemoved);
                changes.Add(change);
                rows.Add(ChangeRow.Of(change, Old.Document, New.Document));
                if (pair.IsAdded) added++;
                else removed++;
                continue;
            }
            if (PixelComparer.Compare(Old.Renderer, pair.OldIndex, New.Renderer, pair.NewIndex, PixelDpi) is not { } found)
            {
                Undrawn++;
                continue;
            }
            Looked++;
            var oldPage = new PageGeometry(Old.Document.Pages[pair.OldIndex]);
            var newPage = new PageGeometry(New.Document.Pages[pair.NewIndex]);
            areas += found.Differences.Count;
            // A page of scanner noise must not use up the list, so each page gives its largest areas.
            foreach (var difference in found.Differences.OrderByDescending(d => d.Pixels).Take(RowsPerPage).OrderBy(d => d.Region.Y).ThenBy(d => d.Region.X))
                rows.Add(ChangeRow.Of(pair, difference, found.Alignment, PixelDpi, oldPage, newPage));
            foreach (var difference in found.Differences.Take(ReportMarks - changes.Count))
                changes.Add(PixelChange(pair, difference, newPage));
        }
        PixelCapped = rows.Count > MaxPixelRows;
        _pixelRows = [.. rows.Take(MaxPixelRows)];
        var summary = new ComparisonSummary(added, removed, areas, 0, 0, 0, areas, 0, added + removed, 0, 0, 0);
        _pixelResult = new ComparisonResult(result.Pages, changes, summary, result.OldPageCount, result.NewPageCount);
    }

    private static CompareChange PixelChange(PagePair pair, PixelDifference difference, PageGeometry page)
    {
        var r = difference.Region;
        var (x0, y0) = page.ToUser(r.X, r.Y + r.Height);
        var (x1, y1) = page.ToUser(r.X + r.Width, r.Y + r.Height);
        var (x2, y2) = page.ToUser(r.X + r.Width, r.Y);
        var (x3, y3) = page.ToUser(r.X, r.Y);
        return new CompareChange(ChangeKind.Changed, ChangeArea.Image, pair.OldIndex, pair.NewIndex, "", "", [], [new TextQuad(x0, y0, x1, y1, x2, y2, x3, y3)], Loc.T("Looks different"));
    }

    private static PdfDocument Reopen(Side side) =>
        side.Certificate is { } certificate ? PdfDocument.Open(side.Bytes, certificate) : PdfDocument.Open(side.Bytes, side.Password);

    private static DocumentTab Open(Side side, Func<IDocumentRenderer> renderers)
    {
        var session = side.Certificate is { } certificate ? PdfEditSession.Open(side.Bytes, certificate) : PdfEditSession.Open(side.Bytes, side.Password);
        return new DocumentTab(session, renderers(), null, side.Name, side.Password, certificate: side.Certificate);
    }
}
