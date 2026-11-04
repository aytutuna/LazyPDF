namespace LazyPDF.Core;

// Which page a destination points at, and taking named destinations out when pages go. The tables
// themselves are read and written by Structure.
internal static class PageDestinations
{
    /// <summary>The page an explicit destination (an array, or a dictionary with /D) points at; null for anything else, including a page number of a remote file.</summary>
    public static PdfReference? PageOf(PdfDocument document, PdfObject? destination)
    {
        var value = document.Resolve(destination);
        if (value is PdfDictionary dictionary) value = document.Resolve(dictionary["D"]);
        return value is PdfArray { Items.Count: > 0 } array && array.Items[0] is PdfReference page ? page : null;
    }

    /// <summary>The destination a name or string stands for, from the catalog's /Dests or the /Names tree; null when there is none.</summary>
    public static PdfObject? Lookup(PdfDocument document, DestContext names, PdfObject? key) =>
        document.Resolve(key) switch
        {
            PdfName name => names.LookUp(name.Value),
            PdfString text => names.LookUp(System.Text.Encoding.Latin1.GetString(text.Bytes)),
            _ => null,
        };

    /// <summary>The page a /Dest value points at, a name resolved through the document's tables.</summary>
    public static PdfReference? PageOfAny(PdfDocument document, DestContext names, PdfObject? destination) =>
        document.Resolve(destination) is PdfName or PdfString ? PageOf(document, Lookup(document, names, destination)) : PageOf(document, destination);

    /// <summary>Takes out every named destination whose value <paramref name="dead"/> says is gone.</summary>
    public static void RemoveWhere(PdfDocument document, Func<PdfObject?, bool> dead)
    {
        if (document.Dict(document.Catalog, "Dests") is { } dictionary)
        {
            foreach (string key in dictionary.Entries.Select(e => e.Key).Distinct().ToList())
            {
                if (dead(dictionary[key])) dictionary.Remove(key);
            }
        }
        if (document.Dict(document.Dict(document.Catalog, "Names"), "Dests") is not { } root) return;
        var entries = PdfNameTree.Read(document, root);
        var kept = entries.Where(e => !dead(e.Value)).ToList();
        if (kept.Count != entries.Count) PdfNameTree.Write(document, root, kept);
    }
}
