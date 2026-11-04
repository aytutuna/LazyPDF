using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace LazyPDF.Core;

// Facts about the file. Signed, certified and PDF/A are as in Lazy Scan's PdfReaderLite.cs.
public sealed partial class PdfDocument
{
    private const int MaxMetadataSize = 1 << 24;
    private const string PdfAIdNamespace = "http://www.aiim.org/pdfa/ns/id/";

    private bool? _linearized;
    private (int? Part, string? Conformance)? _pdfA;

    /// <summary>
    /// The file is signed: its form says signatures exist (/SigFlags bit 1) or the catalog carries
    /// signature permissions (/Perms).
    /// </summary>
    public bool IsSigned =>
        Dict(Catalog, "Perms") is { Count: > 0 } || (Integer(Dict(Catalog, "AcroForm"), "SigFlags") is { } flags && (flags & 1) != 0);

    /// <summary>
    /// The file is certified: its catalog's /Perms has a /DocMDP signature. No certification
    /// allows adding pages (ISO 32000-1 12.8.2.2), so viewers show it as no longer valid after.
    /// </summary>
    public bool IsCertified => Dict(Catalog, "Perms") is { } perms && Resolve(perms["DocMDP"]) is not null;

    /// <summary>The form has XFA data. Lazy PDF shows the page content and leaves the XFA form alone.</summary>
    public bool HasXfa => Resolve(Dict(Catalog, "AcroForm")?["XFA"]) is not null;

    /// <summary>The catalog says the file is tagged (/MarkInfo /Marked true).</summary>
    public bool IsTagged => Bool(Dict(Catalog, "MarkInfo"), "Marked") == true;

    /// <summary>The first object of the file holds a /Linearized dictionary (Annex F).</summary>
    public bool IsLinearized => _linearized ??= FirstObjectIsLinearization();

    /// <summary>The PDF/A part its XMP metadata claims (1, 2, 3, 4), or null when it claims none.</summary>
    public int? PdfAPart => PdfAIdentification().Part;

    /// <summary>The PDF/A conformance level its metadata claims ("A", "B", "U"), or null.</summary>
    public string? PdfAConformance => PdfAIdentification().Conformance;

    private bool FirstObjectIsLinearization()
    {
        try
        {
            var lexer = new PdfLexer(_bytes, _headerVersionEnd);
            lexer.ReadObjectHeader();
            return lexer.ReadObject() is PdfDictionary dictionary && dictionary.ContainsKey("Linearized");
        }
        catch (PdfReadException)
        {
            return false;
        }
    }

    private (int? Part, string? Conformance) PdfAIdentification()
    {
        if (_pdfA is { } known) return known;
        (int?, string?) result = (null, null);
        try
        {
            if (Stream(Catalog, "Metadata") is { } metadata) result = ReadPdfAId(Data(metadata, MaxMetadataSize));
        }
        catch (PdfReadException)
        {
            // Metadata that cannot be read claims nothing.
        }
        _pdfA = result;
        return result;
    }

    /// <summary>pdfaid:part and pdfaid:conformance from XMP, as attributes or elements.</summary>
    internal static (int? Part, string? Conformance) ReadPdfAId(byte[] xmp)
    {
        string text = Encoding.UTF8.GetString(xmp);
        string? part = null, conformance = null;
        try
        {
            int start = text.IndexOf("<x:xmpmeta", StringComparison.Ordinal);
            if (start < 0) start = text.IndexOf("<rdf:RDF", StringComparison.Ordinal);
            int end = text.LastIndexOf("</x:xmpmeta>", StringComparison.Ordinal);
            string xml = start >= 0 && end > start ? text[start..(end + "</x:xmpmeta>".Length)] : start >= 0 ? text[start..] : text;
            // Metadata is the file's, so no DTD and no entity expansion.
            var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 1 << 24 };
            using var reader = XmlReader.Create(new StringReader(xml), settings);
            XNamespace ns = PdfAIdNamespace;
            foreach (var element in XDocument.Load(reader).Descendants())
            {
                part ??= element.Attribute(ns + "part")?.Value;
                conformance ??= element.Attribute(ns + "conformance")?.Value;
                if (element.Name == ns + "part") part ??= element.Value;
                if (element.Name == ns + "conformance") conformance ??= element.Value;
            }
        }
        catch (XmlException)
        {
            // Not well-formed: claims nothing.
        }
        int? number = int.TryParse(part?.Trim(), out int p) ? p : null;
        string? level = string.IsNullOrWhiteSpace(conformance) ? null : conformance.Trim().ToUpperInvariant();
        return (number, number is null ? null : level);
    }
}
