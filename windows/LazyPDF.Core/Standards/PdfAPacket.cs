using System.Text;
using System.Xml;

namespace LazyPDF.Core;

// From Lazy Scan's PdfA.cs (Xmp, CleanTitle): the packet is built as text; the part and level are the caller's and
// more of the document's own properties go in.
internal static class PdfAPacket
{
    public static byte[] Xmp(PdfALevel level, DocumentMetadata meta, DateTimeOffset metadataDate)
    {
        var sb = new StringBuilder();
        sb.Append("<?xpacket begin=\"\uFEFF\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n");
        sb.Append("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n");
        sb.Append(" <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n");
        sb.Append("  <rdf:Description rdf:about=\"\"\n");
        sb.Append("    xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\"\n");
        sb.Append("    xmlns:dc=\"http://purl.org/dc/elements/1.1/\"\n");
        sb.Append("    xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"\n");
        sb.Append("    xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\">\n");
        sb.Append("   <pdfaid:part>").Append(level.Part()).Append("</pdfaid:part>\n");
        if (level.Conformance() is { } conformance) sb.Append("   <pdfaid:conformance>").Append(conformance).Append("</pdfaid:conformance>\n");
        else sb.Append("   <pdfaid:rev>2020</pdfaid:rev>\n");
        sb.Append("   <dc:format>application/pdf</dc:format>\n");
        if (Clean(meta.Title) is { } title)
            sb.Append("   <dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">").Append(title).Append("</rdf:li></rdf:Alt></dc:title>\n");
        if (Clean(meta.Author) is { } author)
            sb.Append("   <dc:creator><rdf:Seq><rdf:li>").Append(author).Append("</rdf:li></rdf:Seq></dc:creator>\n");
        if (Clean(meta.Subject) is { } subject)
            sb.Append("   <dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">").Append(subject).Append("</rdf:li></rdf:Alt></dc:description>\n");
        if (meta.Created is { } created) sb.Append("   <xmp:CreateDate>").Append(PdfDate.FormatXmp(created)).Append("</xmp:CreateDate>\n");
        if (meta.Modified is { } modified) sb.Append("   <xmp:ModifyDate>").Append(PdfDate.FormatXmp(modified)).Append("</xmp:ModifyDate>\n");
        sb.Append("   <xmp:MetadataDate>").Append(PdfDate.FormatXmp(metadataDate)).Append("</xmp:MetadataDate>\n");
        if (Clean(meta.Creator) is { } tool) sb.Append("   <xmp:CreatorTool>").Append(tool).Append("</xmp:CreatorTool>\n");
        if (Clean(meta.Producer) is { } producer) sb.Append("   <pdf:Producer>").Append(producer).Append("</pdf:Producer>\n");
        if (Clean(meta.Keywords) is { } keywords) sb.Append("   <pdf:Keywords>").Append(keywords).Append("</pdf:Keywords>\n");
        sb.Append("  </rdf:Description>\n");
        sb.Append(" </rdf:RDF>\n");
        sb.Append("</x:xmpmeta>\n");
        sb.Append("<?xpacket end=\"w\"?>");
        return new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(sb.ToString());
    }

    /// <summary>The text with what XML cannot hold removed, line breaks as one LF and the ends trimmed, so that /Info and the XMP read the same; null when nothing is left.</summary>
    public static string? Strip(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        var sb = new StringBuilder(text.Length);
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
            {
                sb.Append(c).Append(text[++i]);
            }
            else if (XmlConvert.IsXmlChar(c))
            {
                sb.Append(c);
            }
        }
        string clean = sb.ToString().Replace("\r\n", "\n").Replace('\r', '\n').Trim();
        return clean.Length == 0 ? null : clean;
    }

    private static string? Clean(string? text) =>
        Strip(text)?.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");

    /// <summary>The catalog's /OutputIntents entry, its profile in object <paramref name="profile"/>.</summary>
    public static PdfDictionary OutputIntent(PdfReference profile)
    {
        var intent = new PdfDictionary();
        intent["Type"] = new PdfName("OutputIntent");
        intent["S"] = new PdfName("GTS_PDFA1");
        intent["OutputConditionIdentifier"] = new PdfString(Encoding.ASCII.GetBytes(PdfASrgb.OutputConditionIdentifier), isHex: false);
        intent["Info"] = new PdfString(Encoding.ASCII.GetBytes(PdfASrgb.OutputConditionIdentifier), isHex: false);
        intent["DestOutputProfile"] = profile;
        return intent;
    }
}
