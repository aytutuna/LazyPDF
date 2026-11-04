using System.Xml;
using System.Xml.Linq;

namespace LazyPDF.Core;

// A read of the catalog's XMP packet for the PDF/A checks. The packet is the file's, so no DTD and no entity expansion.
internal sealed class PdfAXmp
{
    public static readonly XNamespace Rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
    public static readonly XNamespace Id = "http://www.aiim.org/pdfa/ns/id/";
    public static readonly XNamespace Dc = "http://purl.org/dc/elements/1.1/";
    public static readonly XNamespace Xmp = "http://ns.adobe.com/xap/1.0/";
    public static readonly XNamespace Pdf = "http://ns.adobe.com/pdf/1.3/";
    public static readonly XNamespace SchemaNs = "http://www.aiim.org/pdfa/ns/schema#";

    private const int MaxSize = 1 << 24;

    private static readonly HashSet<string> Predefined =
    [
        Dc.NamespaceName, Xmp.NamespaceName, Pdf.NamespaceName, Id.NamespaceName,
        "http://ns.adobe.com/xap/1.0/mm/", "http://ns.adobe.com/xap/1.0/rights/", "http://ns.adobe.com/photoshop/1.0/",
        "http://ns.adobe.com/tiff/1.0/", "http://ns.adobe.com/exif/1.0/", "http://ns.adobe.com/xap/1.0/t/pg/", "http://ns.adobe.com/xap/1.0/bj/",
        "http://www.aiim.org/pdfa/ns/extension/", "http://www.aiim.org/pdfa/ns/schema#", "http://www.aiim.org/pdfa/ns/property#",
        "http://www.aiim.org/pdfa/ns/type#", "http://www.aiim.org/pdfa/ns/field#",
    ];

    private readonly List<XElement> _descriptions;

    private PdfAXmp(List<XElement> descriptions) => _descriptions = descriptions;

    /// <summary>The packet, or null with <paramref name="problem"/> saying why not: unreadable, not well-formed, or no rdf:RDF.</summary>
    public static PdfAXmp? Parse(byte[] bytes, out string? problem)
    {
        problem = null;
        if (bytes.Length > MaxSize)
        {
            problem = PdfAText.XmpTooBig;
            return null;
        }
        try
        {
            var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = MaxSize };
            using var reader = XmlReader.Create(new MemoryStream(bytes), settings);
            var rdf = XDocument.Load(reader).Descendants(Rdf + "RDF").FirstOrDefault();
            if (rdf is not null) return new PdfAXmp([.. rdf.Elements(Rdf + "Description")]);
            problem = PdfAText.XmpNoRdf;
        }
        catch (XmlException)
        {
            problem = PdfAText.XmpNotWellFormed;
        }
        return null;
    }

    /// <summary>A property written as an attribute, an element, or the first item of an array or language alternative.</summary>
    public string? Get(XNamespace ns, string name)
    {
        foreach (var description in _descriptions)
        {
            if (description.Attribute(ns + name) is { } attribute) return attribute.Value;
            if (description.Element(ns + name) is { } element) return (element.Descendants(Rdf + "li").FirstOrDefault() ?? element).Value.Trim();
        }
        return null;
    }

    /// <summary>The namespaces properties are written in that the standard does not predefine.</summary>
    public IEnumerable<string> UndeclaredNamespaces()
    {
        var declared = _descriptions.SelectMany(d => d.Descendants(SchemaNs + "namespaceURI")).Select(e => e.Value.Trim()).ToHashSet();
        var used = _descriptions.SelectMany(d => d.Attributes().Where(a => !a.IsNamespaceDeclaration).Select(a => a.Name.NamespaceName)
            .Concat(d.Elements().Select(e => e.Name.NamespaceName)));
        return used.Where(ns => ns.Length > 0 && ns != Rdf.NamespaceName && ns != XNamespace.Xml.NamespaceName && !Predefined.Contains(ns) && !declared.Contains(ns)).Distinct();
    }
}
