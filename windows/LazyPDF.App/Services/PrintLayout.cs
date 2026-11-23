using System.Printing;
using LazyPDF.Core;

namespace LazyPDF.App.Services;

public enum PrintParity { All, Odd, Even }

/// <summary>What the print flow does to the pages before the system dialog's paper takes them.</summary>
/// <param name="PerSheet">1, 2, 4, 6, 9 or 16.</param>
/// <param name="Booklet">Two pages on each side of a landscape sheet, folded in order; <paramref name="PerSheet"/> is then ignored.</param>
/// <param name="Parity">Odd means sides 1, 3, 5 of the layout, the fronts of a two-sided run; with no layout a side is a page.</param>
/// <param name="Gap">Points between pages and from the pages to the sheet edge.</param>
public sealed record PrintLayout(int PerSheet = 1, bool Booklet = false, PrintParity Parity = PrintParity.All, bool Reverse = false,
    bool RightToLeft = false, double Gap = 0, bool Border = false)
{
    public static readonly IReadOnlyList<int> PerSheetChoices = [1, 2, 4, 6, 9, 16];

    public bool IsPlain => PerSheet == 1 && !Booklet && Parity == PrintParity.All && !Reverse;

    /// <summary>Whether the pages go through <see cref="PageOperations.Impose"/> before they are drawn.</summary>
    public bool Imposes => Booklet || PerSheet > 1;

    /// <summary>
    /// The pages to print: the chosen range (null for all). Without a layout it is cut down to the odd or even
    /// pages by page number and reversed, and -1 stands for the blank that keeps the backs of a manual two-sided
    /// run on the right paper. With a layout the range is returned as it is, since odd, even and reverse then act on the sides.
    /// </summary>
    public List<int> Pages(IReadOnlyList<int>? range, int count)
    {
        var pages = range ?? Enumerable.Range(0, count).ToList();
        if (Imposes) return [.. pages];
        var kept = pages.Where(i => Parity switch
        {
            PrintParity.Odd => i % 2 == 0,
            PrintParity.Even => i % 2 == 1,
            _ => true,
        }).ToList();
        return Arrange(kept, Parity == PrintParity.Even && kept.Count > 0 && pages.Count(i => i % 2 == 0) > kept.Count);
    }

    /// <summary>How many sides the layout makes of this many pages.</summary>
    public int SideCount(int pageCount) => pageCount <= 0 ? 0
        : Booklet ? (pageCount + 3) / 4 * 2
        : (pageCount + PerSheet - 1) / PerSheet;

    /// <summary>The zero-based sides to print, in order; -1 is a blank page. Empty when nothing is left.</summary>
    public List<int> SheetsToPrint(int sideCount)
    {
        var kept = Enumerable.Range(0, sideCount).Where(i => Parity switch
        {
            PrintParity.Odd => i % 2 == 0,
            PrintParity.Even => i % 2 == 1,
            _ => true,
        }).ToList();
        return Arrange(kept, Parity == PrintParity.Even && kept.Count > 0 && sideCount % 2 == 1);
    }

    // The unpaired last front has no back: the blank ends the even run, or starts it when it is fed in reverse.
    private List<int> Arrange(List<int> kept, bool pad)
    {
        if (Reverse) kept.Reverse();
        if (pad) kept.Insert(Reverse ? 0 : kept.Count, -1);
        return kept;
    }

    /// <summary>The note for annotations the sheets could not take, or null when none was left off.</summary>
    public static string? DroppedNote(int dropped) => dropped == 0 ? null
        : Loc.Plural(dropped, "{0} link or note without a picture was left off the sheets.", "{0} links and notes without a picture were left off the sheets.");

    public ImposeOptions Options(double sheetWidth, double sheetHeight) =>
        new(Booklet ? ImposeMode.Booklet : ImposeMode.NUp, sheetWidth, sheetHeight, PerSheet, Gap, Border, RightToLeft);

    /// <summary>A message when the gap leaves no room for the pages on a sheet of this size in points, else null.</summary>
    public string? Validate(double sheetWidth, double sheetHeight)
    {
        if (!Imposes) return null;
        var (columns, rows) = Booklet ? (2, 1) : PerSheet switch { 2 => (2, 1), 4 => (2, 2), 6 => (3, 2), 9 => (3, 3), _ => (4, 4) };
        double width = Booklet ? Math.Max(sheetWidth, sheetHeight) : sheetWidth;
        double height = Booklet ? Math.Min(sheetWidth, sheetHeight) : sheetHeight;
        return width - Gap * (columns + 1) > 0 && height - Gap * (rows + 1) > 0 ? null
            : Loc.T("The gap leaves no room for the pages on this paper.");
    }

    /// <summary>
    /// The ticket's duplex setting for this layout, or null to leave it alone: one-sided when only odd or even
    /// sides go, so the printer does not duplex half a job, and short edge for a booklet when the printer offers it.
    /// </summary>
    public Duplexing? Duplex(IReadOnlyCollection<Duplexing> offered)
    {
        if (Parity != PrintParity.All) return Duplexing.OneSided;
        return Booklet && offered.Contains(Duplexing.TwoSidedShortEdge) ? Duplexing.TwoSidedShortEdge : null;
    }

    /// <summary>The pages laid out on sheets of this size in points, saved and ready to open for drawing.</summary>
    public PrintSheets Sheets(PdfDocument source, IReadOnlyList<int> pages, double sheetWidth, double sheetHeight, CancellationToken cancel = default)
    {
        var result = PageOperations.Impose(source, pages, Options(sheetWidth, sheetHeight), cancel);
        return new PrintSheets(result.Document.SaveRewrite(cancel: cancel), result.Sheets, result.AnnotationsDropped);
    }
}

/// <param name="Dropped">Annotations that could not be placed on the sheets.</param>
public sealed record PrintSheets(byte[] Bytes, int Count, int Dropped);
