import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfPage.cs: one page of the tree. It reads its dictionary as it is now,
// so a change to the dictionary shows at once; what a page inherits from its ancestors (ISO 32000-1 7.7.3.4)
// was taken when the tree was walked.
//
// A page holds its document, as in the C#. The document keeps `PageNode`s, not pages, so there is no cycle.

/// What a page takes from the nodes above it when it has no value of its own.
struct PageInheritance {
    var resources: PdfObject?
    var mediaBox: PdfObject?
    var cropBox: PdfObject?
    var rotate: PdfObject?

    init(resources: PdfObject? = nil, mediaBox: PdfObject? = nil, cropBox: PdfObject? = nil, rotate: PdfObject? = nil) {
        self.resources = resources
        self.mediaBox = mediaBox
        self.cropBox = cropBox
        self.rotate = rotate
    }
}

/// What the document keeps of a page between walks of the tree.
struct PageNode {
    let dictionary: PdfDictionary
    let reference: PdfReference
    let index: Int
    let inherited: PageInheritance

    init(_ dictionary: PdfDictionary, _ reference: PdfReference, _ index: Int, _ inherited: PageInheritance) {
        self.dictionary = dictionary
        self.reference = reference
        self.index = index
        self.inherited = inherited
    }
}

public final class PdfPage {
    /// US Letter, what a viewer shows for a page without a usable /MediaBox.
    private static let defaultBox = PdfRect(0, 0, 612, 792)

    // No page has more content than this; the limit is shared by all of its streams.
    private static let maxContentSize = 256 << 20

    private let document: PdfDocument
    private let inherited: PageInheritance

    init(_ document: PdfDocument, _ node: PageNode) {
        self.document = document
        self.dictionary = node.dictionary
        self.reference = node.reference
        self.index = node.index
        self.inherited = node.inherited
    }

    public let dictionary: PdfDictionary
    public let reference: PdfReference

    /// Position in reading order, from 0.
    public let index: Int

    public var resources: PdfDictionary? {
        document.dict(dictionary, "Resources") ?? document.resolve(inherited.resources) as? PdfDictionary
    }

    /// The paper: /MediaBox, or US Letter when it is missing or has no area.
    public var mediaBox: PdfRect { box("MediaBox", inherited.mediaBox) ?? Self.defaultBox }

    /// What is shown: /CropBox clipped to the media box; the media box without one.
    public var cropBox: PdfRect {
        let media = mediaBox
        guard let crop = box("CropBox", inherited.cropBox) else { return media }
        let clipped = crop.intersect(media)
        return clipped.isEmpty ? media : clipped
    }

    public var trimBox: PdfRect { box("TrimBox", nil) ?? cropBox }
    public var bleedBox: PdfRect { box("BleedBox", nil) ?? cropBox }
    public var artBox: PdfRect { box("ArtBox", nil) ?? cropBox }

    /// Clockwise degrees the page is turned when shown: 0, 90, 180 or 270 (anything else rounds to the nearest).
    public var rotate: Int {
        let value = document.resolve(dictionary["Rotate"]) ?? document.resolve(inherited.rotate)
        guard let number = value as? PdfNumber else { return 0 }
        // A NaN would have no quarter turns; the clamp keeps the rounded value far inside an Int.
        let clamped = Swift.min(Swift.max(number.value, -1e6), 1e6)
        let quarters = clamped.isNaN ? 0 : Int((clamped / 90).rounded(.toNearestOrEven))
        return (quarters % 4 + 4) % 4 * 90
    }

    /// User space units per point (ISO 32000-1 14.11.2.3); 1 unless /UserUnit is a positive number.
    public var userUnit: Double {
        if let unit = document.number(dictionary, "UserUnit"), unit > 0, unit.isFinite { return unit }
        return 1
    }

    /// The page's content streams, decoded and joined with a newline so that no token runs into the next stream
    /// (7.8.2). A stream that cannot be read is left out and noted in the document's repairs.
    public func contents() -> [UInt8] {
        var parts: [[UInt8]] = []
        var room = Self.maxContentSize
        let contents = document.resolve(dictionary["Contents"])
        let streams: [PdfObject] = (contents as? PdfArray)?.items ?? [contents ?? PdfNull.instance]
        for item in streams {
            guard let stream = document.resolve(item) as? PdfStream else { continue }
            do {
                let part = try document.data(stream, room)
                room = Swift.max(0, room - part.count - 1)
                parts.append(part)
            } catch {
                document.addRepair("Page \(index + 1): a content stream could not be read (\(error))")
            }
        }
        var result: [UInt8] = []
        for (i, part) in parts.enumerated() {
            if i > 0 { result.append(UInt8(ascii: "\n")) }
            result.append(contentsOf: part)
        }
        return result
    }

    private func box(_ key: String, _ inherited: PdfObject?) -> PdfRect? {
        document.rect(dictionary[key]) ?? document.rect(inherited)
    }
}
