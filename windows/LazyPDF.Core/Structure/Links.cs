namespace LazyPDF.Core;

/// <summary>
/// A Link annotation (ISO 32000-1 12.5.6.5): its rectangle in user space, and where it goes.
/// <see cref="Destination"/> is set for /Dest and for a GoTo action; <see cref="Action"/> holds the
/// action when there is one, a URI included. <see cref="Reference"/> names the annotation.
/// </summary>
public sealed record PdfLink(PdfRect Rect, PdfDestination? Destination, PdfAction? Action, PdfReference? Reference)
{
    public string? Uri => (Action as UriAction)?.Uri;
}

public static class PdfLinks
{
    private const int MaxLinks = 50_000;

    /// <summary>The Link annotations of the page that have a rectangle, in page order (at most 50000).</summary>
    public static IReadOnlyList<PdfLink> Read(PdfDocument document, PdfPage page)
    {
        var links = new List<PdfLink>();
        if (document.Array(page.Dictionary, "Annots") is not { } annots) return links;
        var context = new DestContext(document);
        foreach (var item in annots.Items)
        {
            if (links.Count >= MaxLinks) break;
            if (document.Resolve(item) is not PdfDictionary annot || document.Name(annot, "Subtype") != "Link") continue;
            if (document.Rect(annot, "Rect") is not { } rect) continue;
            var action = PdfActions.Read(document, annot["A"], context);
            var destination = annot.ContainsKey("Dest") ? PdfDestinations.Parse(document, annot["Dest"], context) : (action as GoToAction)?.Destination;
            links.Add(new PdfLink(rect, destination, action, item as PdfReference));
        }
        return links;
    }

    /// <summary>Adds an invisible link to a place in the document. Returns the annotation's reference.</summary>
    public static PdfReference Add(PdfDocument document, PdfPage page, PdfRect rect, PdfDestination destination)
    {
        var value = PdfDestinations.ToObject(document, destination) ?? throw new ArgumentException("The destination has no page in the document.", nameof(destination));
        return AddAnnotation(document, page, rect, "Dest", value);
    }

    /// <summary>Adds an invisible link that runs <paramref name="action"/>.</summary>
    public static PdfReference Add(PdfDocument document, PdfPage page, PdfRect rect, PdfAction action) =>
        AddAnnotation(document, page, rect, "A", PdfActions.ToObject(document, action));

    public static PdfReference AddUri(PdfDocument document, PdfPage page, PdfRect rect, string uri) =>
        Add(document, page, rect, new UriAction(uri));

    /// <summary>Takes the annotation out of the page and frees it; false when the page does not list it.</summary>
    public static bool Remove(PdfDocument document, PdfPage page, PdfReference link)
    {
        if (document.Array(page.Dictionary, "Annots") is not { } annots) return false;
        if (annots.Items.RemoveAll(i => i is PdfReference r && r.Number == link.Number) == 0) return false;
        document.Delete(link.Number);
        return true;
    }

    private static PdfReference AddAnnotation(PdfDocument document, PdfPage page, PdfRect rect, string key, PdfObject target)
    {
        var annot = new PdfDictionary
        {
            ["Type"] = new PdfName("Annot"),
            ["Subtype"] = new PdfName("Link"),
            ["Rect"] = rect.ToArray(),
            ["Border"] = new PdfArray([new PdfNumber(0), new PdfNumber(0), new PdfNumber(0)]),
            [key] = target,
        };
        var reference = document.Add(annot);
        if (document.Array(page.Dictionary, "Annots") is { } annots) annots.Items.Add(reference);
        else page.Dictionary["Annots"] = new PdfArray([reference]);
        return reference;
    }
}
