using System.Text.RegularExpressions;

namespace LazyPDF.Core;

// Page thumbnails and the data other applications keep in a file for their own use.
internal static class OptimizeStrip
{
    // Second-class names (ISO 32000-1 Annex E) start with a registered prefix and a separator.
    private static readonly Regex PrivateName = new("^[A-Za-z][A-Za-z0-9]{1,9}[_:]", RegexOptions.Compiled);

    public static int Thumbnails(PdfDocument document)
    {
        int count = 0;
        foreach (var page in document.Pages)
        {
            if (page.Dictionary.Remove("Thumb")) count++;
        }
        return count;
    }

    public static int PieceInfo(PdfDocument document)
    {
        int count = 0;
        foreach (var dictionary in PdfGraph.AllDictionaries(document))
        {
            if (dictionary.Remove("PieceInfo")) count++;
        }
        return count;
    }

    /// <summary>Removes /LastModified and the keys with second-class names from the catalog, the pages and the streams that are forms or images.</summary>
    public static int PrivateData(PdfDocument document)
    {
        int count = 0;
        foreach (var (_, value) in PdfGraph.Objects(document))
        {
            var dictionary = value as PdfDictionary ?? (value as PdfStream)?.Dictionary;
            if (dictionary is null || !(IsCarrier(document, dictionary) || ReferenceEquals(dictionary, document.Catalog))) continue;
            foreach (var (key, _) in dictionary.Entries.ToArray())
            {
                if (key == "LastModified" || (PrivateName.IsMatch(key) && !key.StartsWith("GTS_", StringComparison.Ordinal)))
                {
                    dictionary.Remove(key);
                    count++;
                }
            }
        }
        return count;
    }

    private static bool IsCarrier(PdfDocument document, PdfDictionary dictionary) =>
        document.Name(dictionary, "Type") == "Page" || document.Name(dictionary, "Subtype") is "Form" or "Image";
}
