import Foundation
import LazyPDFKit

// Twin of windows/LazyPDF.App/Viewer/IDocumentViewer.cs, without the WPF element: the views show a viewer, they are not it.
// FullScreen is left to the window; no tool asks for it.

/// Which tool the pointer is, when no `DocumentViewer.pointerTool` has taken it.
public enum PointerMode: Sendable {
    /// Dragging pans the page.
    case hand
    /// Dragging selects text; double and triple clicks select a word and a line.
    case select
}

/// A point of page space on one page.
public struct PagePoint: Equatable {
    public var page: Int
    public var point: ViewPoint

    public init(_ page: Int, _ point: ViewPoint) {
        self.page = page
        self.point = point
    }
}

public struct PointerModifiers: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = PointerModifiers(rawValue: 1)
    public static let command = PointerModifiers(rawValue: 2)
    public static let option = PointerModifiers(rawValue: 4)
    public static let control = PointerModifiers(rawValue: 8)
}

/// What a pointer tool is told. `point` is in page space of `page` (points from the top left of the page as shown, y down)
/// and may lie outside the page during a drag; `view` is the same place in the viewer's view. `clicks` is 1, 2 or 3 for a
/// press and 0 for a move; `fromKeys` means Return sent it, so it is a click and a box tool has to pick the size.
public struct PagePointer {
    public var page: Int
    public var point: ViewPoint
    public var view: ViewPoint
    public var pressed: Bool
    public var clicks: Int
    public var modifiers: PointerModifiers
    public var fromKeys: Bool

    /// A finger made it. A tool that adds a point per press waits for the release, since a second finger cancels the press.
    public var touch: Bool

    public init(page: Int, point: ViewPoint, view: ViewPoint, pressed: Bool, clicks: Int,
                modifiers: PointerModifiers = [], fromKeys: Bool = false, touch: Bool = false) {
        self.page = page
        self.point = point
        self.view = view
        self.pressed = pressed
        self.clicks = clicks
        self.modifiers = modifiers
        self.fromKeys = fromKeys
        self.touch = touch
    }
}

public enum PointerCursor: Sendable {
    case arrow
    case crosshair
    case text
    case link
    case move
}

/// A tool that takes the pointer from the viewer: a press, moves with `pressed` set for the same page, then a release, which
/// always arrives. Moves with nothing pressed arrive for the page under a mouse pointer; a finger gives none. Secondary
/// clicks and scrolling stay with the viewer, and so does the keyboard except for the keys `key` takes.
@MainActor
public protocol PagePointerTool: AnyObject {
    /// The cursor over the pages; nil for the arrow. Only the Mac shows it.
    var cursor: PointerCursor? { get }

    /// Whether a touch that lands here is the tool's. A finger the tool does not take scrolls the page, so a tool whose
    /// targets are small (a check box, a handle) answers true only over them. The Mac asks nothing.
    func takes(_ pointer: PagePointer) -> Bool

    /// A key the tool uses (Delete, Escape): true if it was taken, else the viewer gets it.
    func key(_ key: ViewerKey, modifiers: PointerModifiers) -> Bool

    func press(_ pointer: PagePointer)
    func move(_ pointer: PagePointer)
    func release(_ pointer: PagePointer)

    /// Escape was pressed during a press, or the tool was replaced: drop what was started.
    func cancel()
}

extension PagePointerTool {
    public func takes(_ pointer: PagePointer) -> Bool { true }

    public func key(_ key: ViewerKey, modifiers: PointerModifiers) -> Bool { false }
}

/// A selected stretch of one page: its characters, their text and their boxes in PDF user space (what annotations take
/// as quad points).
public struct SelectedRun {
    public let page: Int
    public let range: LazyPDFKit.TextRange
    public let text: String
    public let quads: [TextQuad]

    public init(page: Int, range: LazyPDFKit.TextRange, text: String, quads: [TextQuad]) {
        self.page = page
        self.range = range
        self.text = text
        self.quads = quads
    }
}

/// What the shell, the side panels and the tools need of the viewer. Page numbers are 0-based, angles clockwise degrees.
/// "Page space" is points from the top left of the page as shown (crop box, /Rotate applied, before the viewer's own
/// rotation), y down: the engine's display space, which `PageGeometry` converts to and from PDF user space.
///
/// The class behind it is `@Observable`: views follow `pageIndex`, `zoom`, `mode`, `hasSelection` and `layers` as they
/// change, and `viewRevision` moves with every scroll, zoom, rotation or rearrangement, after which `pageToView` answers
/// differently.
@MainActor
public protocol DocumentViewer: AnyObject {
    /// The document shown; nil on the Home tab.
    var tab: DocumentTab? { get }

    /// Shows `tab` at the page and zoom it remembers.
    func show(_ tab: DocumentTab?)

    /// The page in view. Setting it scrolls there and notes the jump in the history; the viewer keeps the tab's
    /// `pageIndex` current.
    var pageIndex: Int { get set }

    /// 1 is 100 % (the page at the size it prints). Setting it keeps the centre of the view where it is.
    var zoom: Double { get set }

    var pageCount: Int { get }

    /// The label of a page as the file numbers them ("iv", "A-3"), else its number from 1.
    func pageLabel(_ page: Int) -> String

    var fit: FitMode { get set }

    /// 1 for one page across, 2 for facing pages.
    var columns: Int { get set }

    /// With two columns, the first page stands alone so that pages 2 and 3 face each other.
    var coverPage: Bool { get set }

    /// All pages scroll together; false shows one page or spread at a time.
    var continuous: Bool { get set }

    /// 0, 90, 180 or 270. Turns the view only.
    var rotation: Int { get set }

    var tint: PageTint { get set }

    /// Hides the viewer's own bar and fits the width, for reading.
    var readingMode: Bool { get set }

    func goToPage(_ page: Int)

    /// Goes to a destination of the file and notes the jump in the history.
    func goTo(_ destination: PdfDestination)

    /// Does what a link or bookmark says: a destination, a named action, or (after asking) an address.
    func follow(_ action: PdfAction?)

    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    func goBack()
    func goForward()

    /// Scrolls so that `area` (page space) is in view; nothing moves if it already is.
    func reveal(_ page: Int, _ area: ViewRect)

    func showFind()
    func showGoToPage()

    /// The pages that meet the window, in order.
    var visiblePages: [Int] { get }

    /// The page size in points as shown, before the viewer's rotation.
    func pageSize(_ page: Int) -> ViewSize

    /// Takes page space of `page` to the viewer's view at the present scroll, zoom and rotation; nil for a page not laid
    /// out (the other pages of a one-page-at-a-time view). Stale once `viewRevision` moves.
    func pageToView(_ page: Int) -> ViewMatrix?

    /// The page under a point of the view and the point in its page space; nil between pages. With `nearest` the closest
    /// page is taken instead.
    func viewToPage(_ view: ViewPoint, nearest: Bool) -> PagePoint?

    /// The engine's geometry of a page; valid until the file next changes.
    func geometry(_ page: Int) -> PageGeometry

    var viewRevision: Int { get }

    /// The layer a tool draws on for a page: made on first use and kept for as long as the document is shown.
    func overlay(_ page: Int) -> PageOverlay

    /// Ends a tool's marks: the fields whose id starts with `prefix` finish with the text typed so far and the items with
    /// that prefix go, on the layers that exist. A layer is not made for a page the tool never drew on.
    func endToolMarks(prefix: String)

    /// What dragging does. Setting it also drops any `pointerTool`.
    var mode: PointerMode { get set }

    /// Takes the primary button on the pages from the viewer. Nil gives it back; setting another cancels the one before.
    var pointerTool: PagePointerTool? { get set }

    /// The characters of a page and their places in PDF user space for this revision of the file; nil when the text
    /// cannot be read.
    func text(_ page: Int) async -> TextPage?

    var hasSelection: Bool { get }

    /// The selected text, page by page.
    func selection() async -> [SelectedRun]

    func selectAll()
    func clearSelection()

    /// The search the find bar and the Search panel share.
    var search: ViewerSearch { get }

    /// Shows or hides a layer in the view only: the viewer draws a copy of the file with the layer changed, so the file
    /// and its undo history stay as they are.
    func setLayerVisible(_ layer: PdfReference, _ visible: Bool)

    /// The layers as the view shows them: the file's, with what `setLayerVisible` changed.
    var layers: LayerSet { get }
}
