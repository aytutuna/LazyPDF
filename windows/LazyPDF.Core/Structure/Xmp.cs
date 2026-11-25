using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace LazyPDF.Core;

// The XMP packet of a document (ISO 16684-1) as far as the Info dictionary has a counterpart. The
// metadata is the file's, so no DTD and no entity expansion, as in PdfDocument.Facts.cs.
internal sealed class XmpPacket
{
    public static readonly XNamespace Rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
    public static readonly XNamespace Dc = "http://purl.org/dc/elements/1.1/";
    public static readonly XNamespace Xmp = "http://ns.adobe.com/xap/1.0/";
    public static readonly XNamespace Pdf = "http://ns.adobe.com/pdf/1.3/";
    public static readonly XNamespace Pdfx = "http://ns.adobe.com/pdfx/1.3/";
    public static readonly XNamespace PdfAId = "http://www.aiim.org/pdfa/ns/id/";
    public static readonly XNamespace PdfUAId = "http://www.aiim.org/pdfua/ns/id/";
    private static readonly XNamespace Extension = "http://www.aiim.org/pdfa/ns/extension/";
    private static readonly XNamespace Schema = "http://www.aiim.org/pdfa/ns/schema#";
    private static readonly XNamespace Property = "http://www.aiim.org/pdfa/ns/property#";

    private const int MaxSize = 1 << 24;

    private readonly XDocument _document;
    private readonly XElement _rdf;

    private XmpPacket(XDocument document, XElement rdf)
    {
        _document = document;
        _rdf = rdf;
    }

    public static bool IsPresent(PdfDocument document) => document.Stream(document.Catalog, "Metadata") is not null;

    /// <summary>The packet in the catalog's /Metadata, or null when there is none, it is not well-formed, or it has no rdf:RDF.</summary>
    public static XmpPacket? Load(PdfDocument document)
    {
        if (document.Stream(document.Catalog, "Metadata") is not { } stream) return null;
        try
        {
            byte[] bytes = document.Data(stream);
            if (bytes.Length > MaxSize) return null;
            var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = MaxSize };
            using var reader = XmlReader.Create(new MemoryStream(bytes), settings);
            var xml = XDocument.Load(reader);
            return xml.Descendants(Rdf + "RDF").FirstOrDefault() is { } rdf ? new XmpPacket(xml, rdf) : null;
        }
        catch (Exception e) when (e is XmlException or PdfReadException)
        {
            return null;
        }
    }

    /// <summary>The text of a property written as an attribute, an element, or the first item of a language alternative or a list.</summary>
    public string? Get(XNamespace ns, string name)
    {
        foreach (var description in Descriptions())
        {
            if (description.Attribute(ns + name) is { } attribute) return attribute.Value;
            if (description.Element(ns + name) is { } element)
            {
                string? text = (element.Descendants(Rdf + "li").FirstOrDefault() ?? element).Value;
                return string.IsNullOrWhiteSpace(text) ? null : text.Trim();
            }
        }
        return null;
    }

    public bool Has(XNamespace ns, string name) => Descriptions().Any(d => d.Attribute(ns + name) is not null || d.Element(ns + name) is not null);

    /// <summary>Sets a simple property, or takes it out when <paramref name="value"/> is null.</summary>
    public void Set(XNamespace ns, string prefix, string name, string? value) =>
        Put(ns, prefix, name, value is null ? null : new XElement(ns + name, Clean(value)));

    /// <summary>A language alternative with one item, x-default.</summary>
    public void SetAlt(XNamespace ns, string prefix, string name, string? value) =>
        Put(ns, prefix, name, value is null ? null : new XElement(ns + name,
            new XElement(Rdf + "Alt", new XElement(Rdf + "li", new XAttribute(XNamespace.Xml + "lang", "x-default"), Clean(value)))));

    /// <summary>An ordered list with one item.</summary>
    public void SetSeq(XNamespace ns, string prefix, string name, string? value) =>
        Put(ns, prefix, name, value is null ? null : new XElement(ns + name, new XElement(Rdf + "Seq", new XElement(Rdf + "li", Clean(value)))));

    /// <summary>An unordered list, or nothing when there are no values.</summary>
    public void SetBag(XNamespace ns, string prefix, string name, IReadOnlyList<string> values) =>
        Put(ns, prefix, name, values.Count == 0 ? null : new XElement(ns + name, new XElement(Rdf + "Bag", values.Select(v => new XElement(Rdf + "li", Clean(v))))));

    /// <summary>Takes out every property of a namespace, as attribute or element; whether there was one.</summary>
    public bool RemoveProperties(XNamespace ns)
    {
        bool found = false;
        foreach (var description in Descriptions())
        {
            var attributes = description.Attributes().Where(a => a.Name.Namespace == ns).ToList();
            var elements = description.Elements().Where(e => e.Name.Namespace == ns).ToList();
            attributes.ForEach(a => a.Remove());
            elements.ForEach(e => e.Remove());
            found |= attributes.Count + elements.Count > 0;
        }
        return found;
    }

    /// <summary>
    /// The extension schema PDF/A asks for the pdfuaid namespace. It joins the file's own list of schemas when there is one,
    /// and is not added twice.
    /// </summary>
    public void DeclarePdfUaSchema()
    {
        if (Descriptions().SelectMany(d => d.Descendants(Schema + "namespaceURI")).Any(e => e.Value.Trim() == PdfUAId.NamespaceName)) return;
        var entry = new XElement(Rdf + "li", new XAttribute(Rdf + "parseType", "Resource"),
            new XElement(Schema + "schema", "PDF/UA identification schema"),
            new XElement(Schema + "namespaceURI", PdfUAId.NamespaceName),
            new XElement(Schema + "prefix", "pdfuaid"),
            new XElement(Schema + "property", new XElement(Rdf + "Seq", new XElement(Rdf + "li", new XAttribute(Rdf + "parseType", "Resource"),
                new XElement(Property + "name", "part"),
                new XElement(Property + "valueType", "Integer"),
                new XElement(Property + "category", "internal"),
                new XElement(Property + "description", "Indicates which part of ISO 14289 the file follows")))));
        var bag = Descriptions().SelectMany(d => d.Elements(Extension + "schemas")).Select(e => e.Element(Rdf + "Bag")).FirstOrDefault(b => b is not null);
        if (bag is not null)
        {
            bag.Add(entry);
            return;
        }
        _rdf.Add(new XElement(Rdf + "Description", new XAttribute(Rdf + "about", ""),
            new XAttribute(XNamespace.Xmlns + "pdfaExtension", Extension.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "pdfaSchema", Schema.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "pdfaProperty", Property.NamespaceName),
            new XElement(Extension + "schemas", new XElement(Rdf + "Bag", entry))));
    }

    public byte[] ToBytes()
    {
        var settings = new XmlWriterSettings { Encoding = new UTF8Encoding(false), OmitXmlDeclaration = true, Indent = false };
        using var output = new MemoryStream();
        using (var writer = XmlWriter.Create(output, settings)) _document.Save(writer);
        return output.ToArray();
    }

    // XML has no place for most control characters, U+FFFE or U+FFFF, and XmlWriter refuses them; a title that holds one
    // would stop the whole write. They are left out of the packet, and /Info keeps the text as it is.
    private static string Clean(string value) =>
        string.Concat(value.Where(c => XmlConvert.IsXmlChar(c) || char.IsSurrogate(c)));

    private IEnumerable<XElement> Descriptions() => _rdf.Elements(Rdf + "Description");

    private void Put(XNamespace ns, string prefix, string name, XElement? element)
    {
        foreach (var description in Descriptions())
        {
            description.Attribute(ns + name)?.Remove();
            description.Element(ns + name)?.Remove();
        }
        if (element is null) return;
        var target = Descriptions().FirstOrDefault();
        if (target is null)
        {
            target = new XElement(Rdf + "Description", new XAttribute(Rdf + "about", ""));
            _rdf.Add(target);
        }
        if (target.GetPrefixOfNamespace(ns) is null) target.SetAttributeValue(XNamespace.Xmlns + prefix, ns.NamespaceName);
        target.Add(element);
    }
}
