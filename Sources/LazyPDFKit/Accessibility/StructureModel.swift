import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/StructureModel.cs: what a structure tree holds. The parent of a kid is
// weak: the tree and the elements above hold their kids, as the garbage collector lets the C# parent and kid hold each
// other.

/// Anything that can sit in an element's /K: a child element, a marked-content sequence or an object reference.
public class StructKid {
    init() {}

    /// The element that holds this one; nil for a root element and for a kid that is not in a tree yet.
    public internal(set) weak var parent: StructElement?
}

/// A marked-content sequence of a page (ISO 32000-1 14.7.4.2), found by its /MCID in the content.
public final class StructContent: StructKid {
    public let pageIndex: Int
    public let mcid: Int

    /// The form XObject whose content holds the sequence; nil when it is in the page's own content.
    public let stream: PdfReference?

    /// /StmOwn of the MCR (14.7.4.2): the object the stream belongs to, written back as it was read.
    var streamOwner: PdfObject?

    public init(_ pageIndex: Int, _ mcid: Int, _ stream: PdfReference? = nil) {
        self.pageIndex = pageIndex
        self.mcid = mcid
        self.stream = stream
        super.init()
    }
}

/// An object reference (OBJR): an annotation or XObject that belongs to an element.
public final class StructObject: StructKid {
    public let pageIndex: Int
    public let target: PdfReference

    public init(_ pageIndex: Int, _ target: PdfReference) {
        self.pageIndex = pageIndex
        self.target = target
        super.init()
    }
}

/// One structure element (14.7.2). Properties read from the file and the live `dictionary` are kept: keys this class has
/// no property for (attributes, class names, revisions) stay as they were.
public final class StructElement: StructKid, CustomStringConvertible {
    var kidList: [StructKid] = []

    public convenience init(_ type: String) {
        self.init(type, PdfDictionary(), nil)
    }

    init(_ type: String, _ dictionary: PdfDictionary, _ reference: PdfReference?) {
        self.type = type
        self.dictionary = dictionary
        self.reference = reference
        super.init()
    }

    /// The structure type as written (/S), which a role map may take to a standard one.
    public var type: String

    public var title: String?
    public var alt: String?
    public var lang: String?
    public var actualText: String?
    public var id: String?

    /// The page the element's content is on (/Pg), -1 when none is named. Written from the first content kid when left at -1.
    public var pageIndex = -1

    /// Nil until the element is written or when the file held it as a direct dictionary.
    public internal(set) var reference: PdfReference?

    public let dictionary: PdfDictionary

    public var kids: [StructKid] { kidList }

    public var children: [StructElement] { kidList.compactMap { $0 as? StructElement } }

    public var description: String { "\(type) (\(kidList.count) kids)" }
}
