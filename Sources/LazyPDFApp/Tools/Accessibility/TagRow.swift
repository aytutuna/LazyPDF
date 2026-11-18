import Foundation
import LazyPDFKit

/// One line of the tag tree as the tree view lists it. The model builds the lines of the nodes that are open, so a large tree
/// costs only what is looked at; past `TagRow.shown` kids the rest are one line that says how many.
public struct TagRow: Identifiable {
    static let shown = 200

    /// The steps from the roots, which is also where the line is in the tree on the screen.
    public let id: String
    public let kid: StructKid?
    public let depth: Int
    public let label: String
    public let hasKids: Bool
    public let isOpen: Bool

    /// The line that says how many kids are not listed.
    public var isMore: Bool { kid == nil }
}
