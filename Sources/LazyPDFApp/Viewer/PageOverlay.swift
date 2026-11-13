import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Viewer/PageOverlay.cs. Where the Windows overlay is a Canvas of WPF elements, this one is a list
// of plain marks the platform's page view paints, so it builds on Linux. Everything is in page space: points from the top left
// of the page as shown, y down. The viewer scales and rotates the whole layer with the page and clips it to the page.

/// A colour for a mark. `accent` is the system's accent colour, whose red, green and blue are not used.
public struct OverlayColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public var isAccent: Bool

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        isAccent = false
    }

    private init(accent alpha: Double) {
        red = 0
        green = 0
        blue = 0
        self.alpha = alpha
        isAccent = true
    }

    public static let accent = OverlayColor(accent: 1)
    public static let black = OverlayColor(red: 0, green: 0, blue: 0)
    public static let white = OverlayColor(red: 1, green: 1, blue: 1)

    /// The same colour at `alpha`, for a wash over the page.
    public func opacity(_ alpha: Double) -> OverlayColor {
        var made = self
        made.alpha = alpha
        return made
    }
}

/// How a shape is drawn. A line is `lineWidth` screen points wide however far the page is zoomed (a line of 1.5 stays 1.5),
/// unless `scalesWithPage` is set, which makes it points of the page, as a mark that will be written to the file is. `dash`
/// is on and off lengths in the same unit.
public struct OverlayStyle: Equatable, Sendable {
    public var stroke: OverlayColor?
    public var fill: OverlayColor?
    public var lineWidth: Double
    public var scalesWithPage: Bool
    public var dash: [Double]
    public var round: Bool

    public init(stroke: OverlayColor? = nil, fill: OverlayColor? = nil, lineWidth: Double = 1.5, scalesWithPage: Bool = false,
                dash: [Double] = [], round: Bool = false) {
        self.stroke = stroke
        self.fill = fill
        self.lineWidth = lineWidth
        self.scalesWithPage = scalesWithPage
        self.dash = dash
        self.round = round
    }
}

/// `leading` starts the line, which for a right-to-left line is its right edge; `left` is the left edge whatever the direction.
public enum TextAlign: Sendable {
    case leading, left, center, trailing, justified
}

/// The face, size and colour of text on the page, as the Windows tools set them on a TextBlock or a TextBox. `size` is points
/// of the page; `family` is a PDF base-14 style name ("Helvetica", "Times", "Courier") or any installed family.
public struct OverlayTextLook: Equatable, Sendable {
    public var family: String
    public var size: Double
    public var bold: Bool
    public var italic: Bool
    public var color: OverlayColor
    public var alignment: TextAlign

    public init(family: String = "Helvetica", size: Double = 12, bold: Bool = false, italic: Bool = false,
                color: OverlayColor = .black, alignment: TextAlign = .leading) {
        self.family = family
        self.size = size
        self.bold = bold
        self.italic = italic
        self.color = color
        self.alignment = alignment
    }
}

public enum TextAnchor: Sendable {
    /// `at` is the top left corner of the text.
    case topLeading
    /// `at` is the middle of the text, which is also what a rotation turns about.
    case center
}

/// A label on the page. Lines break at "\n". `background` fills the box behind the text, as the halo of a measurement does.
/// With `sizeOnScreen` the size is screen points and the text keeps its size as the page is zoomed.
public struct OverlayText {
    public var text: String
    public var at: ViewPoint
    public var anchor: TextAnchor
    public var look: OverlayTextLook
    public var sizeOnScreen: Bool
    public var background: OverlayColor?

    public init(_ text: String, at: ViewPoint, anchor: TextAnchor = .topLeading, look: OverlayTextLook = OverlayTextLook(),
                sizeOnScreen: Bool = false, background: OverlayColor? = nil) {
        self.text = text
        self.at = at
        self.anchor = anchor
        self.look = look
        self.sizeOnScreen = sizeOnScreen
        self.background = background
    }
}

/// A picture stretched over `rect`. The pixels do not change after the picture is made; a new picture replaces it.
public struct OverlayPicture {
    public let image: PdfRgbaImage
    public var rect: ViewRect

    /// The platform's own form of the image, made when it is first painted and shared by copies of the picture.
    public let native = NativeCache()

    public init(_ image: PdfRgbaImage, rect: ViewRect) {
        self.image = image
        self.rect = rect
    }
}

public final class NativeCache {
    public var value: AnyObject?

    public init() {}
}

public enum OverlayShape {
    case rect(ViewRect)
    case ellipse(ViewRect)
    case line(ViewPoint, ViewPoint)
    /// A polyline, or a polygon when `closed`.
    case path([ViewPoint], closed: Bool)
    /// A square or round mark of `size` screen points about `center`: a drag handle, a snap point. It does not grow with the
    /// zoom, so a finger can still hit it.
    case marker(center: ViewPoint, size: Double, round: Bool)
    case text(OverlayText)
    case picture(OverlayPicture)
}

/// One mark. Items are painted in order of `layer`, then in the order they were added; `set` with an `id` already there
/// replaces that item and keeps its place. `rotation` turns it clockwise, in degrees, about `pivot` (the middle of a
/// rectangle, ellipse or picture, the anchor of a text). `opacity` multiplies the colours.
public struct OverlayItem {
    public var id: String
    public var shape: OverlayShape
    public var style: OverlayStyle
    public var opacity: Double
    public var rotation: Double
    public var pivot: ViewPoint?
    public var layer: Int

    public init(_ id: String, _ shape: OverlayShape, style: OverlayStyle = OverlayStyle(), opacity: Double = 1, rotation: Double = 0,
                pivot: ViewPoint? = nil, layer: Int = 0) {
        self.id = id
        self.shape = shape
        self.style = style
        self.opacity = opacity
        self.rotation = rotation
        self.pivot = pivot
        self.layer = layer
    }
}

/// Where the caret goes when a field opens, which is also what the first key replaces.
public enum FieldCaret {
    /// Everything is selected, so typing replaces the text: a note or a label to rewrite.
    case all
    /// After the last character: a value to add to.
    case end
    /// At the character nearest `point` (page space): a field opened by a click inside its text.
    case at(ViewPoint)
}

/// A text box on the page that takes the keyboard: a note being typed, a form field being filled. The page view puts a real
/// text control over `area`, so the system's input methods, spelling and accessibility work. `text` follows what is typed.
/// The field ends once: `commit` when it loses the focus or Return (or Command-Return for a multi-line one) is pressed,
/// `drop` on Escape or the Cancel of the keyboard bar on iOS, and `done` hears the text, or nil for a drop.
@MainActor
public final class OverlayField {
    public let id: String
    public var area: ViewRect { didSet { touch() } }

    /// Setting it changes what the control shows; typing in the control goes through `typed`.
    public var text: String { didSet { if !typing { touch() } } }
    public var look: OverlayTextLook { didSet { touch() } }

    /// The text wraps at the width of `area` instead of growing to the right.
    public var wraps: Bool

    /// Return makes a new line, and only Command-Return (Control on Windows) ends it.
    public var multiline: Bool

    public var border: OverlayColor?

    /// The box behind the text; the system's field colour when nil.
    public var background: OverlayColor?

    /// What a screen reader calls the box.
    public var label: String

    public var onChange: ((String) -> Void)?

    public var caret: FieldCaret

    /// The characters show as dots: a password.
    public var secure: Bool

    /// The most characters the control takes; nil for no limit.
    public var maxLength: Int?

    /// Tab was pressed (`backwards` with Shift). With this set the key does not type a tab: the field decides, usually by
    /// finishing and opening the next one. Nil leaves Tab to the control.
    public var onTab: ((_ backwards: Bool) -> Void)?

    private let done: (String?) -> Void
    weak var overlay: PageOverlay?
    public private(set) var isClosed = false

    /// The control lost the keyboard to something else, as against Return: `done` heard the text, but the person may not be
    /// finished with it.
    public private(set) var endedByFocusLoss = false
    private var typing = false

    public init(_ id: String, area: ViewRect, text: String = "", look: OverlayTextLook = OverlayTextLook(), wraps: Bool = true, multiline: Bool = false,
                border: OverlayColor? = .accent, background: OverlayColor? = nil, label: String = "", caret: FieldCaret = .all,
                secure: Bool = false, maxLength: Int? = nil, done: @escaping (String?) -> Void) {
        self.id = id
        self.area = area
        self.text = text
        self.look = look
        self.wraps = wraps
        self.multiline = multiline
        self.border = border
        self.background = background
        self.label = label
        self.caret = caret
        self.secure = secure
        self.maxLength = maxLength
        self.done = done
    }

    /// Typing in the control, from the page view.
    public func typed(_ text: String) {
        if isClosed || text == self.text { return }
        typing = true
        self.text = text
        typing = false
        onChange?(text)
    }

    /// Whether the control may replace `range` of `current` with `replacement`: not when that passes `maxLength`.
    public func accepts(_ current: String, replacing range: NSRange, with replacement: String) -> Bool {
        guard let maxLength else { return true }
        let kept = (current as NSString).replacingCharacters(in: range, with: replacement)
        return kept.count <= maxLength || replacement.isEmpty
    }

    /// Ends the field with `text` kept.
    public func commit(_ text: String, focusLost: Bool = false) {
        if isClosed { return }
        endedByFocusLoss = focusLost
        self.text = text
        close(text)
    }

    /// Ends the field with what is typed so far, for a command that needs the text now.
    public func finish() {
        commit(text)
    }

    /// Ends the field and keeps nothing.
    public func drop() {
        close(nil)
    }

    private func close(_ result: String?) {
        if isClosed { return }
        isClosed = true
        overlay?.fieldClosed(self)
        done(result)
    }

    private func touch() {
        overlay?.touch()
    }
}

/// The layer a tool puts its marks on, over one page: made on first use by `DocumentViewer.overlay(_:)` and kept for as long
/// as the document is shown. Marks follow the page as it scrolls and zooms, and do not take the pointer; a tool that wants
/// the pointer is a `PagePointerTool` and hit-tests in page space itself. Only a field takes the keyboard.
///
/// Give each mark an id that starts with the tool's own name ("measure.rubber") so that `remove(prefix:)` can take all of
/// them away when the tool detaches.
@MainActor
public final class PageOverlay {
    public let page: Int

    /// The size of the page in points as shown, kept current as the file changes.
    public internal(set) var size: ViewSize

    public private(set) var items: [OverlayItem] = []
    public private(set) var fields: [OverlayField] = []

    /// Moves with every change, for a view that wants to know whether to paint again.
    public private(set) var revision = 0

    var onChange: (() -> Void)?

    public init(page: Int, size: ViewSize) {
        self.page = page
        self.size = size
    }

    /// The items in painting order.
    public var painted: [OverlayItem] {
        items.enumerated().sorted { ($0.element.layer, $0.offset) < ($1.element.layer, $1.offset) }.map(\.element)
    }

    public func item(_ id: String) -> OverlayItem? {
        items.first { $0.id == id }
    }

    /// Adds the item, or replaces the one with its id.
    public func set(_ item: OverlayItem) {
        if let at = items.firstIndex(where: { $0.id == item.id }) {
            items[at] = item
        } else {
            items.append(item)
        }
        touch()
    }

    public func remove(_ id: String) {
        guard let at = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: at)
        touch()
    }

    /// Removes every item whose id starts with `prefix`.
    public func remove(prefix: String) {
        let before = items.count
        items.removeAll { $0.id.hasPrefix(prefix) }
        if items.count != before { touch() }
    }

    public func removeAll() {
        if items.isEmpty { return }
        items.removeAll()
        touch()
    }

    /// Puts the field on the page. A field with the same id that is open is dropped first.
    @discardableResult
    public func open(_ field: OverlayField) -> OverlayField {
        for old in fields where old.id == field.id { old.drop() }
        field.overlay = self
        fields.append(field)
        touch()
        return field
    }

    public func field(_ id: String) -> OverlayField? {
        fields.first { $0.id == id }
    }

    /// Drops every open field whose id starts with `prefix`; their `done` hears nil.
    public func dropFields(prefix: String) {
        for field in fields where field.id.hasPrefix(prefix) { field.drop() }
    }

    /// Ends every open field whose id starts with `prefix`; their `done` hears what was typed.
    public func finishFields(prefix: String) {
        for field in fields where field.id.hasPrefix(prefix) { field.finish() }
    }

    func fieldClosed(_ field: OverlayField) {
        fields.removeAll { $0 === field }
        touch()
    }

    func touch() {
        revision &+= 1
        onChange?()
    }

    /// The document went: open fields end, with their text if the document is still open to take it.
    func discard(keepText: Bool = false) {
        onChange = nil
        for field in fields {
            if keepText { field.finish() } else { field.drop() }
        }
        items.removeAll()
    }
}
