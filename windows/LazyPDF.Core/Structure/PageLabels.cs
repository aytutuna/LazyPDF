using System.Globalization;
using System.Text;

namespace LazyPDF.Core;

public enum PageLabelStyle { None, Decimal, UpperRoman, LowerRoman, UpperLetters, LowerLetters }

/// <summary>
/// A run of pages numbered alike (ISO 32000-1 12.4.2): from page <see cref="StartPage"/> (0-based)
/// to the next range, each labelled <see cref="Prefix"/> and a number in <see cref="Style"/>
/// counting up from <see cref="FirstNumber"/>.
/// </summary>
public sealed record PageLabelRange(int StartPage, PageLabelStyle Style = PageLabelStyle.Decimal, string Prefix = "", int FirstNumber = 1);

public static class PdfPageLabels
{
    private const int MaxRanges = 100_000;
    private static readonly (int Value, string Text)[] Romans =
        [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")];

    /// <summary>The ranges in page order; empty when the document has none (its pages are then 1, 2, 3...).</summary>
    public static IReadOnlyList<PageLabelRange> Read(PdfDocument document)
    {
        var ranges = new List<PageLabelRange>();
        foreach (var (key, value) in PdfNumberTree.Read(document, document.Dict(document.Catalog, "PageLabels")))
        {
            if (key is < 0 or > int.MaxValue || document.Resolve(value) is not PdfDictionary d || ranges.Count >= MaxRanges) continue;
            var style = document.Name(d, "S") switch
            {
                "D" => PageLabelStyle.Decimal,
                "R" => PageLabelStyle.UpperRoman,
                "r" => PageLabelStyle.LowerRoman,
                "A" => PageLabelStyle.UpperLetters,
                "a" => PageLabelStyle.LowerLetters,
                _ => PageLabelStyle.None,
            };
            long first = document.Integer(d, "St") ?? 1;
            ranges.Add(new PageLabelRange((int)key, style, PdfText.Read(document, d, "P") ?? "", (int)Math.Clamp(first, 1, int.MaxValue)));
        }
        return ranges;
    }

    /// <summary>Stores the ranges, sorted by start page. The first must start at page 0 (12.4.2); one for decimal numbers is put there when it is missing. No ranges removes the labels.</summary>
    public static void Write(PdfDocument document, IEnumerable<PageLabelRange> ranges)
    {
        var sorted = ranges.GroupBy(r => r.StartPage).Select(g => g.Last()).OrderBy(r => r.StartPage).ToList();
        if (sorted.Count == 0)
        {
            document.Catalog.Remove("PageLabels");
            return;
        }
        if (sorted[0].StartPage != 0) sorted.Insert(0, new PageLabelRange(0));
        var entries = sorted.Select(r =>
        {
            var d = new PdfDictionary();
            if (r.Style != PageLabelStyle.None) d["S"] = new PdfName(r.Style switch { PageLabelStyle.Decimal => "D", PageLabelStyle.UpperRoman => "R", PageLabelStyle.LowerRoman => "r", PageLabelStyle.UpperLetters => "A", _ => "a" });
            if (r.Prefix.Length > 0) d["P"] = PdfText.ToObject(r.Prefix);
            if (r.FirstNumber != 1) d["St"] = new PdfNumber(r.FirstNumber);
            return new KeyValuePair<long, PdfObject>(r.StartPage, d);
        });
        var existing = document.Dict(document.Catalog, "PageLabels");
        var root = PdfNumberTree.Write(document, existing, entries);
        if (existing is null) document.Catalog["PageLabels"] = root;
    }

    /// <summary>The label of one page: the last range that starts at or before it, plain decimal numbers before the first.</summary>
    public static string Label(IReadOnlyList<PageLabelRange> ranges, int pageIndex)
    {
        PageLabelRange? range = null;
        foreach (var r in ranges)
        {
            if (r.StartPage <= pageIndex && (range is null || r.StartPage >= range.StartPage)) range = r;
        }
        if (range is null) return (pageIndex + 1).ToString(CultureInfo.InvariantCulture);
        long number = (long)range.FirstNumber + (pageIndex - range.StartPage);
        return range.Prefix + Number(number, range.Style);
    }

    /// <summary>The labels of all the pages.</summary>
    public static IReadOnlyList<string> Labels(PdfDocument document)
    {
        var ranges = Read(document);
        return [.. Enumerable.Range(0, document.Pages.Count).Select(i => Label(ranges, i))];
    }

    /// <summary>The first page with this label, matched exactly and then ignoring case; null when none.</summary>
    public static int? Find(PdfDocument document, string label)
    {
        var labels = Labels(document);
        int exact = labels.ToList().IndexOf(label);
        if (exact >= 0) return exact;
        for (int i = 0; i < labels.Count; i++)
        {
            if (string.Equals(labels[i], label, StringComparison.OrdinalIgnoreCase)) return i;
        }
        return null;
    }

    private static string Number(long n, PageLabelStyle style) => style switch
    {
        PageLabelStyle.None => "",
        PageLabelStyle.UpperRoman => Roman(n).ToUpperInvariant(),
        PageLabelStyle.LowerRoman => Roman(n),
        PageLabelStyle.UpperLetters => Letters(n).ToUpperInvariant(),
        PageLabelStyle.LowerLetters => Letters(n),
        _ => n.ToString(CultureInfo.InvariantCulture),
    };

    private static string Roman(long n)
    {
        if (n < 1) return n.ToString(CultureInfo.InvariantCulture);
        var sb = new StringBuilder();
        foreach (var (value, text) in Romans)
        {
            // Past 3999 the thousands just repeat; a document does not get there.
            while (n >= value && sb.Length < 4096)
            {
                sb.Append(text);
                n -= value;
            }
        }
        return sb.ToString();
    }

    // a to z, then aa to zz, then aaa (12.4.2).
    private static string Letters(long n)
    {
        if (n < 1) return n.ToString(CultureInfo.InvariantCulture);
        char letter = (char)('a' + (n - 1) % 26);
        return new string(letter, (int)Math.Min((n - 1) / 26 + 1, 4096));
    }
}
