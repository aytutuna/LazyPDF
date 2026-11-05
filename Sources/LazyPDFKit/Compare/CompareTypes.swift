import Foundation

// Twin of windows/LazyPDF.Core/Compare/CompareTypes.cs: what a comparison reports.

public enum ChangeKind: Int {
    case added
    case removed
    case changed

    /// A block of text, equal on both sides, found in another place.
    case moved
}

public enum ChangeArea: Int {
    case text

    /// Same words, another font, size or colour.
    case format
    case image
    case annotation

    /// A page that was inserted, removed or moved, or changed size.
    case page

    /// Metadata, bookmarks, attachments and form values.
    case document
}

/// One difference. Pages count from 0, -1 where a side has none. Quads are in user space of the page on their own side.
/// The side where text was removed or added holds a quad of zero width at that spot. A picture or annotation that exists
/// on one side only has no quad on the other, and a document difference holds none. `detail` says what differs, in
/// words, for formats, images, annotations, pages and the document.
public struct CompareChange {
    public let kind: ChangeKind
    public let area: ChangeArea
    public let oldPage: Int
    public let newPage: Int
    public let oldText: String
    public let newText: String
    public let oldQuads: [TextQuad]
    public let newQuads: [TextQuad]
    public let detail: String?

    public init(_ kind: ChangeKind, _ area: ChangeArea, _ oldPage: Int, _ newPage: Int, _ oldText: String, _ newText: String,
                _ oldQuads: [TextQuad], _ newQuads: [TextQuad], _ detail: String? = nil) {
        self.kind = kind
        self.area = area
        self.oldPage = oldPage
        self.newPage = newPage
        self.oldText = oldText
        self.newText = newText
        self.oldQuads = oldQuads
        self.newQuads = newQuads
        self.detail = detail
    }
}

/// Two pages that are the same page in both files. An index is -1 for a page that has no partner. `similarity` is 0 to 1,
/// of the words (and of the pictures on a page with little text); `moved`: the pair is out of order against the other pages.
public struct PagePair: Equatable {
    public let oldIndex: Int
    public let newIndex: Int
    public let similarity: Double
    public let moved: Bool

    public init(_ oldIndex: Int, _ newIndex: Int, _ similarity: Double, _ moved: Bool) {
        self.oldIndex = oldIndex
        self.newIndex = newIndex
        self.similarity = similarity
        self.moved = moved
    }

    public var isAdded: Bool { oldIndex < 0 }
    public var isRemoved: Bool { newIndex < 0 }
}

/// `ignoreCase`: letters that differ only in case are equal. `ignoreWhiteSpace`: words split or joined differently are
/// equal ("data base" and "database"). `ignoreHeaderFooter`: text in the top and bottom 7% of a page, as shown, is left out.
public struct CompareOptions: Equatable {
    public let ignoreCase: Bool
    public let ignoreWhiteSpace: Bool
    public let ignoreHeaderFooter: Bool

    public init(ignoreCase: Bool = false, ignoreWhiteSpace: Bool = false, ignoreHeaderFooter: Bool = false) {
        self.ignoreCase = ignoreCase
        self.ignoreWhiteSpace = ignoreWhiteSpace
        self.ignoreHeaderFooter = ignoreHeaderFooter
    }
}

public struct ComparisonSummary: Equatable {
    public let added: Int
    public let removed: Int
    public let changed: Int
    public let moved: Int
    public let text: Int
    public let format: Int
    public let images: Int
    public let annotations: Int
    public let pages: Int
    public let document: Int
    public let wordsAdded: Int
    public let wordsRemoved: Int

    public init(_ added: Int, _ removed: Int, _ changed: Int, _ moved: Int,
                _ text: Int, _ format: Int, _ images: Int, _ annotations: Int, _ pages: Int, _ document: Int,
                _ wordsAdded: Int, _ wordsRemoved: Int) {
        self.added = added
        self.removed = removed
        self.changed = changed
        self.moved = moved
        self.text = text
        self.format = format
        self.images = images
        self.annotations = annotations
        self.pages = pages
        self.document = document
        self.wordsAdded = wordsAdded
        self.wordsRemoved = wordsRemoved
    }

    public var total: Int { added + removed + changed + moved }
}

/// `pages`: every page of both files once, in the order of the new file with removed pages at their place.
public struct ComparisonResult {
    public let pages: [PagePair]
    public let changes: [CompareChange]
    public let summary: ComparisonSummary
    public let oldPageCount: Int
    public let newPageCount: Int

    public init(_ pages: [PagePair], _ changes: [CompareChange], _ summary: ComparisonSummary, _ oldPageCount: Int, _ newPageCount: Int) {
        self.pages = pages
        self.changes = changes
        self.summary = summary
        self.oldPageCount = oldPageCount
        self.newPageCount = newPageCount
    }

    public var isIdentical: Bool { changes.isEmpty }
}
