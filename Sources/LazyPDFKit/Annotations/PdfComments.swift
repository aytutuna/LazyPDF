import Foundation

// Twin of windows/LazyPDF.Core/Annotations/PdfComments.cs: the comments of a document as one ordered list, and the two
// ways to answer one (ISO 32000-1 12.5.6.3).
//
// The C# orders and searches text with the current culture and sorts with a stable OrderBy. Here text is compared
// ignoring case without a locale, and the sort breaks ties by position.

/// A comment: a markup annotation that is not a reply, with the replies and review status that hang on it.
public struct PdfComment {
    public let annotation: PdfAnnotation
    public let replies: [PdfAnnotation]
    public let status: ReviewStatus

    public init(_ annotation: PdfAnnotation, _ replies: [PdfAnnotation], _ status: ReviewStatus) {
        self.annotation = annotation
        self.replies = replies
        self.status = status
    }

    public var pageIndex: Int { annotation.pageIndex }
    public var type: AnnotationType { annotation.type }
    public var author: String? { annotation.title }
    public var date: DateTimeOffset? { annotation.modified ?? annotation.created }

    /// /Contents, or the plain text of the rich text when that is all the annotation has.
    public var text: String? {
        if let text = annotation.contents, !text.isEmpty { return text }
        if let rich = annotation.richText, !rich.isEmpty { return PdfRichText.toPlain(rich) }
        return nil
    }
}

public enum CommentOrder {
    /// Page by page, top to bottom, left to right.
    case page
    case date
    case author
    case type
}

/// What to keep in a comment list; a nil member keeps everything. `author` and `text` match ignoring case and also look
/// at the replies.
public struct CommentFilter {
    public var author: String?
    public var text: String?
    public var status: ReviewStatus?
    public var types: [AnnotationType]?
    public var pageIndex: Int?
    public var hasReplies: Bool?

    public init(author: String? = nil, text: String? = nil, status: ReviewStatus? = nil, types: [AnnotationType]? = nil,
                pageIndex: Int? = nil, hasReplies: Bool? = nil) {
        self.author = author
        self.text = text
        self.status = status
        self.types = types
        self.pageIndex = pageIndex
        self.hasReplies = hasReplies
    }
}

public enum PdfComments {
    private static let maxChain = 64

    public static func list(_ document: PdfDocument, _ filter: CommentFilter? = nil, _ order: CommentOrder = .page, descending: Bool = false) -> [PdfComment] {
        let all = PdfAnnotations.readAll(document)
        var byNumber: [Int: Int] = [:]
        for (i, a) in all.enumerated() {
            if let r = a.reference, byNumber[r.number] == nil { byNumber[r.number] = i }
        }

        var roots: [Int] = []
        var replies: [Int: [PdfAnnotation]] = [:]
        for (i, a) in all.enumerated() where a.isMarkup {
            if let root = rootOf(i, all, byNumber), root != i {
                replies[root, default: []].append(a)
            } else {
                roots.append(i)
            }
        }

        // rootOf is nil when the chain loops or is too long, and that annotation stands as a comment of its own.
        var comments = roots.map { i -> PdfComment in
            let thread = replies[i] ?? []
            return PdfComment(all[i], thread, statusOf(thread))
        }
        if let filter { comments = comments.filter { matches($0, filter) } }
        let sorted = comments.enumerated().sorted { x, y in
            let c = compare(x.element, y.element, order)
            return c != 0 ? c < 0 : x.offset < y.offset
        }.map { $0.element }
        return descending ? Array(sorted.reversed()) : sorted
    }

    private static func compare(_ a: PdfComment, _ b: PdfComment, _ order: CommentOrder) -> Int {
        var c = 0
        switch order {
        case .date:
            c = compare(a.date == nil, b.date == nil)
            if c == 0, let x = a.date, let y = b.date { c = compare(x, y) }
        case .author:
            c = compareText(a.author ?? "", b.author ?? "")
        case .type:
            c = compareText(AnnotationText.kindName(a.type), AnnotationText.kindName(b.type))
        case .page:
            c = compare(a.pageIndex, b.pageIndex)
        }
        if c == 0 { c = compare(a.pageIndex, b.pageIndex) }
        if c == 0 { c = compare(b.annotation.rect.top, a.annotation.rect.top) }
        if c == 0 { c = compare(a.annotation.rect.left, b.annotation.rect.left) }
        return c
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> Int { a < b ? -1 : a > b ? 1 : 0 }

    private static func compare(_ a: Bool, _ b: Bool) -> Int { a == b ? 0 : (b ? -1 : 1) }

    private static func compareText(_ a: String, _ b: String) -> Int {
        switch a.compare(b, options: [.caseInsensitive]) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }

    // Follows /IRT to the annotation that started the thread; nil when the chain breaks or loops.
    private static func rootOf(_ start: Int, _ all: [PdfAnnotation], _ byNumber: [Int: Int]) -> Int? {
        var current = start
        for _ in 0..<maxChain {
            guard let parent = all[current].inReplyTo, let next = byNumber[parent.number] else { return current }
            current = next
        }
        return nil
    }

    private static func statusOf(_ thread: [PdfAnnotation]) -> ReviewStatus {
        // The latest by date; of equal dates the later one in the list.
        var best: PdfAnnotation?
        for r in thread where r.state != nil {
            if let b = best, earlier(key(r), key(b)) { continue }
            best = r
        }
        return best?.state ?? .none
    }

    private static func key(_ a: PdfAnnotation) -> DateTimeOffset? { a.modified ?? a.created }

    // An annotation without a date sorts before every date.
    private static func earlier(_ a: DateTimeOffset?, _ b: DateTimeOffset?) -> Bool {
        if let x = a, let y = b { return x < y }
        return a == nil && b != nil
    }

    private static func matches(_ c: PdfComment, _ f: CommentFilter) -> Bool {
        if let page = f.pageIndex, c.pageIndex != page { return false }
        if let status = f.status, c.status != status { return false }
        if let types = f.types, !types.contains(c.type) { return false }
        if let has = f.hasReplies, has != !c.replies.isEmpty { return false }
        if let author = f.author, !author.isEmpty, !mentions(author, c.author, c.replies.map { $0.title }) { return false }
        if let text = f.text, !text.isEmpty, !mentions(text, c.text, c.replies.map { $0.contents }) { return false }
        return true
    }

    private static func mentions(_ needle: String, _ own: String?, _ others: [String?]) -> Bool {
        func has(_ text: String?) -> Bool { text?.range(of: needle, options: [.caseInsensitive]) != nil }
        return has(own) || others.contains(where: has)
    }

    /// Adds a reply (a hidden note pointing back at `parent`, /RT /R) and returns it.
    @discardableResult
    public static func reply(_ document: PdfDocument, _ parent: PdfAnnotation, _ text: String, _ author: String, _ date: DateTimeOffset) throws -> PdfAnnotation {
        try PdfAnnotationWriter(document).addReply(parent, AnnotationInfo(author: author, contents: text, subject: nil, date: date), nil)
    }

    /// Records a review status on a comment as a reply carrying /State: the Review model for None, Accepted, Rejected,
    /// Cancelled and Completed, the Marked model for Marked and Unmarked.
    @discardableResult
    public static func setStatus(_ document: PdfDocument, _ parent: PdfAnnotation, _ status: ReviewStatus, _ author: String, _ date: DateTimeOffset) throws -> PdfAnnotation {
        try PdfAnnotationWriter(document).addReply(
            parent, AnnotationInfo(author: author, contents: AnnotationText.statusSetBy(status, author), subject: nil, date: date), status)
    }
}
