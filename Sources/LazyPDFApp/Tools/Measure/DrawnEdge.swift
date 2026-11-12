import Foundation
import LazyPDFKit

/// A straight stretch of a painted path, in PDF user space. A lone point has both ends equal.
public struct DrawnEdge: Equatable {
    public let x1: Double, y1: Double, x2: Double, y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }
}

/// The edges of the pages of one revision, read from a document of its own so that walking a heavy page stays off the main
/// actor. The document is not safe to share, so pages are read one at a time.
final class EdgeSource: @unchecked Sendable {
    private let document: PdfDocument
    private let lock = NSLock()

    init(_ document: PdfDocument) {
        self.document = document
    }

    func edges(_ page: Int) -> [DrawnEdge] {
        lock.lock()
        defer { lock.unlock() }
        guard page >= 0, page < document.pages.count else { return [] }
        let reader = EdgeReader()
        let interpreter = ContentInterpreter(document)
        interpreter.walkPatterns = false
        interpreter.run(document.pages[page], reader)
        return reader.edges
    }
}

/// Collects the edges of the paths a page paints, leaving out those that only clip, and the outlines of its pictures.
final class EdgeReader: ContentVisitor {
    private static let limit = 20000

    private(set) var edges: [DrawnEdge] = []

    override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
        if edges.count >= Self.limit { return }
        let b = image.bounds
        edges.append(DrawnEdge(b.left, b.bottom, b.right, b.bottom))
        edges.append(DrawnEdge(b.right, b.bottom, b.right, b.top))
        edges.append(DrawnEdge(b.right, b.top, b.left, b.top))
        edges.append(DrawnEdge(b.left, b.top, b.left, b.bottom))
    }

    override func paintPath(_ context: ContentContext, _ path: PathInfo) {
        if path.clips || edges.count >= Self.limit { return }
        var start: (Double, Double)?
        var last: (Double, Double)?
        for s in path.segments {
            switch s.kind {
            case .move:
                start = (s.x1, s.y1)
                last = start
                edges.append(DrawnEdge(s.x1, s.y1, s.x1, s.y1))
            case .line:
                if let from = last { edges.append(DrawnEdge(from.0, from.1, s.x1, s.y1)) }
                last = (s.x1, s.y1)
            case .curve:
                last = (s.x3, s.y3)
                edges.append(DrawnEdge(s.x3, s.y3, s.x3, s.y3))
            case .close:
                if let from = last, let to = start { edges.append(DrawnEdge(from.0, from.1, to.0, to.1)) }
                last = start
            }
        }
    }
}
