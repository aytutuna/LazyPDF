namespace LazyPDF.Core;

internal static class PdfUaMarker
{
    /// <summary>False, with the file untouched, when the existing packet cannot be read or sits behind a Crypt filter.</summary>
    public static bool Write(PdfDocument document, DateTimeOffset date)
    {
        var meta = DocumentMetadata.Read(document);
        var existing = document.Stream(document.Catalog, "Metadata");
        if (existing is not null && (DocumentMetadata.HasCryptFilter(document, existing) || XmpPacket.Load(document) is null)) return false;

        PdfStream stream;
        if (existing is null)
        {
            var dictionary = new PdfDictionary { ["Type"] = new PdfName("Metadata"), ["Subtype"] = new PdfName("XML") };
            stream = new PdfStream(dictionary, PdfAPacket.Xmp(PdfALevel.A2b, meta, date, declare: false));
        }
        else
        {
            stream = existing;
        }

        if (existing is null) document.Catalog["Metadata"] = document.Add(stream);
        var xmp = XmpPacket.Load(document)!;
        xmp.Set(XmpPacket.PdfUAId, "pdfuaid", "part", "1");
        if (string.IsNullOrWhiteSpace(xmp.Get(XmpPacket.Dc, "title")) && !string.IsNullOrWhiteSpace(meta.Title)) xmp.SetAlt(XmpPacket.Dc, "dc", "title", meta.Title);
        if (xmp.Has(XmpPacket.PdfAId, "part")) xmp.DeclarePdfUaSchema();
        stream.Data = xmp.ToBytes();
        stream.Dictionary.Remove("Filter");
        stream.Dictionary.Remove("DecodeParms");

        (ViewerSettings.Read(document) with { DisplayDocTitle = true }).Write(document);
        return true;
    }
}
