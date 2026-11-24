import Foundation

// Follows PagePayload in windows/LazyPDF.App/Tools/Pages/PageDrag.cs.

/// The pages a drag or a "Copy to" menu is about: the tab they are in, their indexes and the tab's revision when they were picked.
@MainActor
public struct PageDragPayload {
    public weak var tab: DocumentTab?
    public weak var grid: PageGrid?
    public let pages: [Int]
    public let revision: Int

    public init(tab: DocumentTab, grid: PageGrid?, pages: [Int]) {
        self.tab = tab
        self.grid = grid
        self.pages = pages
        revision = tab.revision
    }
}
