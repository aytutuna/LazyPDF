using LazyPDF.Core;

namespace LazyPDF.App.Services;

public enum PrintParity { All, Odd, Even }

/// <summary>What the print flow does to the pages before the system dialog's paper takes them.</summary>
/// <param name="PerSheet">1, 2, 4, 6, 9 or 16.</param>
/// <param name="Booklet">Two pages on each side of a landscape sheet, folded in order; <paramref name="PerSheet"/> is then ignored.</param>
public sealed record PrintLayout(int PerSheet = 1, bool Booklet = false, PrintParity Parity = PrintParity.All)
{
    public static readonly IReadOnlyList<int> PerSheetChoices = [1, 2, 4, 6, 9, 16];

    public bool IsPlain => PerSheet == 1 && !Booklet && Parity == PrintParity.All;

    /// <summary>Whether the pages go through <see cref="PageOperations.Impose"/> before they are drawn.</summary>
    public bool Imposes => Booklet || PerSheet > 1;

    /// <summary>The pages to print: the chosen range (null for all) cut down to the odd or even ones, by page number.</summary>
    public List<int> Pages(IReadOnlyList<int>? range, int count)
    {
        var pages = range ?? Enumerable.Range(0, count).ToList();
        return [.. pages.Where(i => Parity switch
        {
            PrintParity.Odd => i % 2 == 0,
            PrintParity.Even => i % 2 == 1,
            _ => true,
        })];
    }

    /// <summary>The note for annotations the sheets could not take, or null when none was left off.</summary>
    public static string? DroppedNote(int dropped) => dropped == 0 ? null
        : Loc.Plural(dropped, "{0} link or note without a picture was left off the sheets.", "{0} links and notes without a picture were left off the sheets.");

    public ImposeOptions Options(double sheetWidth, double sheetHeight) =>
        new(Booklet ? ImposeMode.Booklet : ImposeMode.NUp, sheetWidth, sheetHeight, PerSheet);

    /// <summary>The pages laid out on sheets of this size in points, saved and ready to open for drawing.</summary>
    public PrintSheets Sheets(PdfDocument source, IReadOnlyList<int> pages, double sheetWidth, double sheetHeight, CancellationToken cancel = default)
    {
        var result = PageOperations.Impose(source, pages, Options(sheetWidth, sheetHeight), cancel);
        return new PrintSheets(result.Document.SaveRewrite(cancel: cancel), result.Sheets, result.AnnotationsDropped);
    }
}

/// <param name="Dropped">Annotations that could not be placed on the sheets.</param>
public sealed record PrintSheets(byte[] Bytes, int Count, int Dropped);
