import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/TagNode.cs: an element the layout analysis decided on, before any of the file
// is changed: its type, what is under it and the page-level operations whose output belongs to it.

/// A heading's look: the size in points to half a point and whether it is bold. Headings with the same look get the same level.
struct HeadingLook: Hashable {
    let size: Double
    let bold: Bool
}

final class TagNode {
    var type: String
    var children: [TagNode] = []

    /// Operations of the page's own content that draw this node's text or picture, in drawing order.
    var operations: [Int] = []

    var heading: HeadingLook?

    /// Where the node sits on the page as shown, from the top left.
    var area = DisplayRect(0, 0, 0, 0)

    var element: StructElement?

    init(_ type: String) {
        self.type = type
    }
}

/// An annotation of a page that gets its own element.
struct TagAnnotation {
    let reference: PdfReference
    let subtype: String
    let text: String
}

final class TagPage {
    let index: Int
    var nodes: [TagNode] = []
    var annotations: [TagAnnotation] = []

    init(_ index: Int) {
        self.index = index
    }
}
