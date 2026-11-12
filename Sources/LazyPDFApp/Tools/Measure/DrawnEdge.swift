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

/// Collects the edges of the paths a page paints, leaving out those that only clip.
final class EdgeReader: ContentVisitor {
    private static let limit = 20000

    private(set) var edges: [DrawnEdge] = []

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
