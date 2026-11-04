using System.Globalization;

namespace LazyPDF.Core;

/// <summary>Registering fonts, images and graphics states a new piece of content refers to by name.</summary>
public static class ContentResources
{
    /// <summary>
    /// The page's own /Resources dictionary, made if the page has none: an inherited one is copied
    /// onto the page first (ISO 32000-1 7.8.3), so adding to it leaves the other pages alone.
    /// </summary>
    public static PdfDictionary ForEdit(PdfDocument document, PdfPage page)
    {
        if (document.Dict(page.Dictionary, "Resources") is { } own) return own;
        var resources = page.Resources?.Copy() ?? new PdfDictionary();
        page.Dictionary["Resources"] = resources;
        return resources;
    }

    /// <summary>Puts <paramref name="value"/> in the <paramref name="category"/> (Font, XObject, ExtGState...) under a name starting with <paramref name="prefix"/> that is not in use, and returns the name.</summary>
    public static string Add(PdfDocument document, PdfDictionary resources, string category, PdfObject value, string prefix)
    {
        var entries = document.Dict(resources, category);
        if (entries is null)
        {
            entries = new PdfDictionary();
            resources[category] = entries;
        }
        for (int n = 1; ; n++)
        {
            string name = prefix + n.ToString(CultureInfo.InvariantCulture);
            if (entries.ContainsKey(name)) continue;
            entries[name] = value;
            return name;
        }
    }
}
