import Foundation

// Twin of windows/LazyPDF.Core/Structure/Links.cs: Link annotations (ISO 32000-1 12.5.6.5).

/// A Link annotation: its rectangle in user space, and where it goes. `destination` is set for /Dest and for a GoTo
/// action; `action` holds the action when there is one, a URI included. `reference` names the annotation.
public struct PdfLink {
    public let rect: PdfRect
    public let destination: PdfDestination?
    public let action: PdfAction?
    public let reference: PdfReference?

    public init(_ rect: PdfRect, _ destination: PdfDestination?, _ action: PdfAction?, _ reference: PdfReference?) {
        self.rect = rect
        self.destination = destination
        self.action = action
        self.reference = reference
    }

    public var uri: String? { (action as? UriAction)?.uri }
}

public enum PdfLinks {
    private static let maxLinks = 50_000

    /// The Link annotations of the page that have a rectangle, in page order (at most 50000).
    public static func read(_ document: PdfDocument, _ page: PdfPage) -> [PdfLink] {
        var links: [PdfLink] = []
        guard let annots = document.array(page.dictionary, "Annots") else { return links }
        let context = DestContext(document)
        for item in annots.items {
            if links.count >= maxLinks { break }
            guard let annot = document.resolve(item) as? PdfDictionary, document.name(annot, "Subtype") == "Link" else { continue }
            guard let rect = document.rect(annot, "Rect") else { continue }
            let action = PdfActions.read(document, annot["A"], context)
            let destination = annot.containsKey("Dest") ? PdfDestinations.parse(document, annot["Dest"], context) : (action as? GoToAction)?.destination
            links.append(PdfLink(rect, destination, action, item as? PdfReference))
        }
        return links
    }

    /// Adds an invisible link to a place in the document. Returns the annotation's reference.
    @discardableResult
    public static func add(_ document: PdfDocument, _ page: PdfPage, _ rect: PdfRect, _ destination: PdfDestination) throws -> PdfReference {
        guard let value = PdfDestinations.toObject(document, destination) else {
            throw ArgumentException("The destination has no page in the document.")
        }
        return try addAnnotation(document, page, rect, "Dest", value)
    }

    /// Adds an invisible link that runs `action`.
    @discardableResult
    public static func add(_ document: PdfDocument, _ page: PdfPage, _ rect: PdfRect, _ action: PdfAction) throws -> PdfReference {
        try addAnnotation(document, page, rect, "A", PdfActions.toObject(document, action))
    }

    @discardableResult
    public static func addUri(_ document: PdfDocument, _ page: PdfPage, _ rect: PdfRect, _ uri: String) throws -> PdfReference {
        try add(document, page, rect, UriAction(uri))
    }

    /// Takes the annotation out of the page and frees it; false when the page does not list it.
    public static func remove(_ document: PdfDocument, _ page: PdfPage, _ link: PdfReference) -> Bool {
        guard let annots = document.array(page.dictionary, "Annots") else { return false }
        let before = annots.items.count
        annots.items.removeAll { ($0 as? PdfReference)?.number == link.number }
        if annots.items.count == before { return false }
        document.delete(link.number)
        return true
    }

    private static func addAnnotation(_ document: PdfDocument, _ page: PdfPage, _ rect: PdfRect, _ key: String, _ target: PdfObject) throws -> PdfReference {
        let annot = PdfDictionary()
        annot["Type"] = PdfName("Annot")
        annot["Subtype"] = PdfName("Link")
        annot["Rect"] = rect.toArray()
        annot["Border"] = PdfArray([PdfNumber(0), PdfNumber(0), PdfNumber(0)])
        annot[key] = target
        let reference = try document.add(annot)
        if let annots = document.array(page.dictionary, "Annots") {
            annots.items.append(reference)
        } else {
            page.dictionary["Annots"] = PdfArray([reference])
        }
        return reference
    }
}
