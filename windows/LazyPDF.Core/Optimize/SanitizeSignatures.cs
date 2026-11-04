namespace LazyPDF.Core;

// A rewrite breaks every signature (the byte ranges no longer match), and what stays behind still
// names the signer: the CMS blob with the certificate chain, the reason and place, the
// appearance, the validation data of /DSS and the permissions of /Perms.
internal static class SanitizeSignatures
{
    /// <summary>Takes signature values, their appearances, /DSS, /Perms and /SigFlags out of <paramref name="document"/>; returns how many signatures there were.</summary>
    public static int Strip(PdfDocument document)
    {
        int count = 0;
        foreach (var field in PdfGraph.AllDictionaries(document))
        {
            if (!IsSignature(document, field)) continue;
            field.Remove("V");
            field.Remove("AP");
            if (document.Array(field, "Kids") is { } kids)
            {
                foreach (var kid in kids.Items)
                {
                    if (document.Resolve(kid) is PdfDictionary widget) widget.Remove("AP");
                }
            }
            count++;
        }
        var form = document.Dict(document.Catalog, "AcroForm");
        bool left = document.Catalog.ContainsKey("Perms") || document.Catalog.ContainsKey("DSS") || form?.ContainsKey("SigFlags") == true;
        document.Catalog.Remove("Perms");
        document.Catalog.Remove("DSS");
        form?.Remove("SigFlags");
        return count == 0 && left ? 1 : count;
    }

    // /Type of the value is optional (12.8.1), so a signature field is also known by its inherited /FT.
    private static bool IsSignature(PdfDocument document, PdfDictionary field)
    {
        if (document.Dict(field, "V") is not { } value) return false;
        if (document.Name(value, "Type") is "Sig" or "DocTimeStamp" || value.ContainsKey("ByteRange")) return true;
        var node = field;
        for (int depth = 0; node is not null && depth < 16; depth++, node = document.Dict(node, "Parent"))
        {
            if (document.Name(node, "FT") is { } type) return type == "Sig";
        }
        return false;
    }
}
