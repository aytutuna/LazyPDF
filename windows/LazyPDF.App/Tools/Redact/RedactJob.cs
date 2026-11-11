using System.Security.Cryptography.X509Certificates;
using System.Text.RegularExpressions;
using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Redact;

/// <summary>A colour the marked places are covered with.</summary>
public sealed record Cover(string Name, double[] Fill)
{
    public static IReadOnlyList<Cover> All { get; } =
    [
        new(Loc.T("Black"), [0]),
        new(Loc.T("White"), [1]),
        new(Loc.T("Grey"), [0.5]),
    ];
}

/// <summary>A kind of data the finders know by its shape.</summary>
public sealed record DataKind(string Name, RedactionKind Kind)
{
    public static IReadOnlyList<DataKind> All { get; } =
    [
        new(Loc.T("Email addresses"), RedactionKind.Email),
        new(Loc.T("Phone numbers"), RedactionKind.Phone),
        new(Loc.T("US Social Security numbers"), RedactionKind.UsSocialSecurity),
        new(Loc.T("Turkish ID numbers"), RedactionKind.TurkishId),
        new(Loc.T("IBANs"), RedactionKind.Iban),
        new(Loc.T("Card numbers"), RedactionKind.PaymentCard),
        new(Loc.T("Dates"), RedactionKind.Date),
    ];
}

/// <param name="OverlayText">Printed on every marked place; null for none.</param>
/// <param name="FlattenAll">Every marked page becomes a picture, not only the ones Core cannot follow.</param>
public sealed record RedactSettings(Cover Cover, string? OverlayText, bool FlattenAll);

/// <param name="Items">What was found, to be marked.</param>
/// <param name="Pictures">Pages with no text to search: scans and drawings, where the finders see nothing.</param>
public sealed record Found(IReadOnlyList<MarkItem> Items, int Pictures);

/// <summary>The work behind the panel's buttons, on bytes so that it can run off the UI thread.</summary>
public static class RedactJob
{
    public static PdfDocument Open(byte[] bytes, string? password, X509Certificate2? certificate) =>
        certificate is null ? PdfDocument.Open(bytes, password) : PdfDocument.Open(bytes, certificate);

    public static Found Find(PdfDocument document, DataKind kind, CancellationToken cancel)
    {
        var cache = new TextCache(document);
        return Gather(document, cache, RedactionFinder.Find(cache, kind.Kind, cancel));
    }

    public static Found Find(PdfDocument document, IReadOnlyList<string> terms, bool matchCase, bool wholeWord, CancellationToken cancel)
    {
        var cache = new TextCache(document);
        var options = new TextSearchOptions(MatchCase: matchCase, WholeWord: wholeWord);
        var words = terms.Where(t => t.Length > 0).Distinct().ToList();
        var hits = new List<SearchMatch>();
        // Pages first, so that each page is read once however many terms there are.
        for (int p = 0; p < cache.PageCount; p++)
        {
            cancel.ThrowIfCancellationRequested();
            var page = cache.Get(p);
            foreach (var word in words) hits.AddRange(TextSearch.Find(page, word, options, cancel));
        }
        var matches = hits.OrderBy(h => h.Page).ThenBy(h => h.Range.Start)
            .Select(h => new RedactionMatch(RedactionMark.FromMatch(h), h.Text, RedactionKind.Word)).ToList();
        return Gather(document, cache, matches);
    }

    /// <summary>One mark over the whole /MediaBox of each page, so content outside a CropBox is covered too.</summary>
    public static IReadOnlyList<MarkItem> WholePages(PdfDocument document, IReadOnlyList<int> pages) =>
        [.. pages.Distinct().Select(page => new MarkItem(RedactionMark.FromRect(page, document.Pages[page].MediaBox), Loc.T("Whole page")))];

    public static Found FindPatterns(PdfDocument document, IReadOnlyList<string> patterns, bool matchCase, CancellationToken cancel)
    {
        var cache = new TextCache(document);
        var matches = patterns.SelectMany(p => RedactionFinder.FindRegex(cache, p, matchCase, cancel)).ToList();
        return Gather(document, cache, matches);
    }

    /// <summary>The lines of the search box to run. Patterns keep their spaces, but a line of only spaces is no pattern.</summary>
    public static List<string> Terms(string text, bool regex)
    {
        var lines = text.ReplaceLineEndings("\n").Split('\n');
        var terms = regex ? lines.Where(l => !string.IsNullOrWhiteSpace(l)) : lines.Select(l => l.Trim()).Where(l => l.Length > 0);
        return [.. terms.Distinct(StringComparer.Ordinal)];
    }

    /// <summary>What is wrong with the first bad pattern among the lines of the box, or null when all can run. Blank lines are skipped but counted.</summary>
    public static string? CheckPatterns(IReadOnlyList<string> lines)
    {
        for (int i = 0; i < lines.Count; i++)
        {
            if (string.IsNullOrWhiteSpace(lines[i])) continue;
            try
            {
                if (new Regex(lines[i], RegexOptions.CultureInvariant).IsMatch(""))
                    return Loc.T("Line {0} would match everywhere. Make it more specific.", i + 1);
            }
            catch (RegexParseException error)
            {
                return Loc.T("Line {0} is not a valid pattern. The problem is at character {1}.", i + 1, error.Offset);
            }
        }
        return null;
    }

    /// <summary>True when the file lets this opener read it but not change it, so that Core would refuse to write a copy.</summary>
    public static bool Refuses(PdfDocument document) =>
        document.Security is { OpenedAsOwner: false } security && security.Permissions != PdfPermissions.All;

    /// <summary>
    /// Redacts a copy of <paramref name="bytes"/>. <paramref name="renderer"/> must draw those same bytes: a page
    /// Core cannot follow to its end is drawn by it and put back as a picture. The copy has no password, because
    /// it opens as a new tab and the window has no password to give it.
    /// </summary>
    public static RedactionResult Apply(byte[] bytes, string? password, X509Certificate2? certificate, IReadOnlyList<RedactionMark> marks,
                                        RedactSettings settings, IPageRenderer renderer, IFontSource fonts, IImageCodec images)
    {
        using var document = Open(bytes, password, certificate);
        var options = new RedactionOptions
        {
            Fill = settings.Cover.Fill,
            OverlayText = string.IsNullOrWhiteSpace(settings.OverlayText) ? null : settings.OverlayText.Trim(),
            ChangeMetadata = true,
            Renderer = renderer,
            FlattenMarkedPages = settings.FlattenAll,
            KeepEncryption = false,
        };
        return new PdfRedactor(document, fonts, images).Apply(marks, options);
    }

    public static Problem Failed(Exception error) => error switch
    {
        UnauthorizedAccessException => new(Loc.T("Not redacted"), Loc.T("This file does not allow changes. Ask its owner for a copy without limits.")),
        PdfReadException => new(Loc.T("Not redacted"), Loc.T("The file could not be read. Close it and open it again.")),
        InvalidOperationException when error.Message == RedactionText.NoFont => new(Loc.T("Not redacted"), Loc.T("Windows has no font for the text on the boxes. Clear that text and try again.")),
        _ => new(Loc.T("Not redacted"), Loc.T("The redaction could not be finished. Mark fewer places and try again. The file was not changed.")),
    };

    public static string Clip(string text)
    {
        string one = string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return one.Length <= 40 ? one : one[..39] + "…";
    }

    private static Found Gather(PdfDocument document, TextCache cache, IReadOnlyList<RedactionMatch> matches)
    {
        int pictures = Enumerable.Range(0, document.Pages.Count).Count(i => string.IsNullOrWhiteSpace(cache.Get(i).Text));
        return new([.. matches.Select(m => new MarkItem(m.Mark, Clip(m.Text)))], pictures);
    }
}
