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
    /// pages by place in the range and reversed, and -1 stands for the blank that keeps the backs of a manual two-sided
    /// run on the right paper. With a layout the range is returned as it is, since odd, even and reverse then act on the sides.
    /// </summary>
    public List<int> Pages(IReadOnlyList<int>? range, int count)
    {
        var pages = range ?? Enumerable.Range(0, count).ToList();
        if (Imposes) return [.. pages];
        var kept = pages.Where((_, position) => Parity switch
        {
            PrintParity.Odd => position % 2 == 0,
            PrintParity.Even => position % 2 == 1,
            _ => true,
        }).ToList();
        return Arrange(kept, Parity == PrintParity.Even && kept.Count > 0 && pages.Count % 2 == 1);
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

    /// <summary>What the layout will print, for the window: the counts of pages, sides and papers, which sides go and the blank.</summary>
    public string Summary(IReadOnlyList<int>? range, int documentPages)
    {
        int pages = range?.Count ?? documentPages;
        int sides = Imposes ? SideCount(pages) : pages;
        var sent = Imposes ? SheetsToPrint(sides) : Pages(range, documentPages);
        int real = sent.Count(i => i >= 0);
        string pagesText = Loc.Plural(pages, "{0} page", "{0} pages");
        var parts = new List<string> { Imposes
            ? Loc.T("{0}: {1} on {2}.", pagesText, Loc.Plural(sides, "{0} side", "{0} sides"), Loc.Plural((sides + 1) / 2, "{0} piece of paper", "{0} pieces of paper"))
            : pagesText + "." };
        if (real == 0) parts.Add(Loc.T("No sides are left to print."));
        else
        {
            // Without a layout odd and even count the pages from the first one printed.
            if (Parity == PrintParity.Odd) parts.Add(Imposes ? Loc.T("Odd sides (fronts): {0} of {1}.", real, sides) : Loc.T("Odd pages: {0} of {1}.", real, sides));
            if (Parity == PrintParity.Even) parts.Add(Imposes ? Loc.T("Even sides (backs): {0} of {1}.", real, sides) : Loc.T("Even pages: {0} of {1}.", real, sides));
            if (sent.Contains(-1))
                parts.Add(Reverse ? Loc.T("{0} sides: a blank is added at the start of the even run so each back meets its front.", sides)
                    : Loc.T("{0} sides: a blank is added at the end of the even run so each back meets its front.", sides));
            if (Reverse) parts.Add(Loc.T("In reverse order."));
        }
        return string.Join(" ", parts);
    }

    /// <summary>The layout choices kept between prints: not the sides, the order or the binding, which a person picks for each job.</summary>
    public static PrintLayout Remembered(AppPreferences preferences) => new(
        PerSheetChoices.Contains(preferences.PrintPerSheet) ? preferences.PrintPerSheet : 1, preferences.PrintBooklet,
        Gap: Math.Clamp(preferences.PrintGap, 0, MaxGap), Border: preferences.PrintBorder);

    public void Remember(AppPreferences preferences)
    {
        preferences.PrintPerSheet = PerSheet;
        preferences.PrintBooklet = Booklet;
        if (Imposes) preferences.PrintGap = Gap; // a plain job has no gap to offer, so it must not wipe the kept one
        preferences.PrintBorder = Border;
    }

    /// <summary>The widest gap the window offers, in points (25 mm).</summary>
    public const double MaxGap = 72;

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
    /// sides go or the order is reversed, so the printer does not duplex half a job or swap fronts and backs, and
    /// short edge for a booklet when the printer offers it.
    /// </summary>
    public Duplexing? Duplex(IReadOnlyCollection<Duplexing> offered)
    {
        if (Parity != PrintParity.All || Reverse) return Duplexing.OneSided;
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
