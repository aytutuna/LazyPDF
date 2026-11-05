using System.Security.Cryptography.X509Certificates;
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

    public static Found Find(PdfDocument document, string words, bool matchCase, bool wholeWord, CancellationToken cancel)
    {
        var cache = new TextCache(document);
        return Gather(document, cache, RedactionFinder.FindWords(cache, [words], wholeWord, matchCase, cancel));
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
