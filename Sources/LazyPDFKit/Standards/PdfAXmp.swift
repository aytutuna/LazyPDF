import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAXmp.cs: a read of the catalog's XMP packet for the PDF/A checks. The packet is
// the file's, so no DTD and no entity expansion. XmlTree.swift stands in for System.Xml.Linq; `parse` returns the problem
// beside the packet where the C# has an out parameter.

final class PdfAXmp {
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let id = "http://www.aiim.org/pdfa/ns/id/"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let xmp = "http://ns.adobe.com/xap/1.0/"
    static let pdf = "http://ns.adobe.com/pdf/1.3/"
    static let schemaNs = "http://www.aiim.org/pdfa/ns/schema#"

    private static let maxSize = 1 << 24

    private static let predefined: Set<OrdinalString> = Set([
        dc, xmp, pdf, id,
        "http://ns.adobe.com/xap/1.0/mm/", "http://ns.adobe.com/xap/1.0/rights/", "http://ns.adobe.com/photoshop/1.0/",
        "http://ns.adobe.com/tiff/1.0/", "http://ns.adobe.com/exif/1.0/", "http://ns.adobe.com/xap/1.0/t/pg/", "http://ns.adobe.com/xap/1.0/bj/",
        "http://www.aiim.org/pdfa/ns/extension/", "http://www.aiim.org/pdfa/ns/schema#", "http://www.aiim.org/pdfa/ns/property#",
        "http://www.aiim.org/pdfa/ns/type#", "http://www.aiim.org/pdfa/ns/field#",
    ].map { OrdinalString($0) })

    private let descriptions: [XmlElement]

    private init(_ descriptions: [XmlElement]) {
        self.descriptions = descriptions
    }

    /// The packet, or nil with the problem saying why not: unreadable, not well-formed, or no rdf:RDF.
    static func parse(_ bytes: [UInt8]) -> (packet: PdfAXmp?, problem: String?) {
        if bytes.count > maxSize { return (nil, PdfAText.xmpTooBig) }
        guard let document = XmlDocument.parse(bytes) else { return (nil, PdfAText.xmpNotWellFormed) }
        guard let root = document.firstDescendant(XmlName(rdf, "RDF")) else { return (nil, PdfAText.xmpNoRdf) }
        return (PdfAXmp(root.elements(XmlName(rdf, "Description"))), nil)
    }

    /// A property written as an attribute, an element, or the first item of an array or language alternative.
    func get(_ ns: String, _ name: String) -> String? {
        for description in descriptions {
            if let attribute = description.attribute(XmlName(ns, name)) { return attribute.value }
            if let element = description.element(XmlName(ns, name)) {
                return PdfDate.trimmed((element.firstDescendant(XmlName(Self.rdf, "li")) ?? element).value)
            }
        }
        return nil
    }

    /// The namespaces properties are written in that the standard does not predefine.
    func undeclaredNamespaces() -> [String] {
        var declared = Set<OrdinalString>()
        for description in descriptions {
            for element in Self.descendants(description, XmlName(Self.schemaNs, "namespaceURI")) { declared.insert(OrdinalString(PdfDate.trimmed(element.value))) }
        }
        var used: [String] = []
        for description in descriptions {
            used += description.attributes.filter { !$0.isNamespaceDeclaration }.map { $0.name.namespace }
            used += description.children.compactMap { ($0 as? XmlElement)?.name.namespace }
        }
        var seen = Set<OrdinalString>()
        var result: [String] = []
        for ns in used where !ns.isEmpty {
            let key = OrdinalString(ns)
            if XmlParser.same(ns, Self.rdf) || XmlParser.same(ns, XmlNamespaces.xml) || Self.predefined.contains(key) || declared.contains(key) { continue }
            if seen.insert(key).inserted { result.append(ns) }
        }
        return result
    }

    private static func descendants(_ element: XmlElement, _ name: XmlName) -> [XmlElement] {
        var found: [XmlElement] = []
        var work: [XmlNode] = element.children.reversed()
        while let node = work.popLast() {
            guard let child = node as? XmlElement else { continue }
            if child.name == name { found.append(child) }
            work.append(contentsOf: child.children.reversed())
        }
        return found
    }
}
