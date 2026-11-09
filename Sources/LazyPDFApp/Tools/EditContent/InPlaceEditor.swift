import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/EditContent/InPlaceEditor.cs: a text box on the page over the text being changed, in the
// font and size of the run, so that what is typed is what the page will show. Return keeps it, Escape drops it. The box is an
// OverlayField, so the page view gives it a real text control.

@MainActor
final class InPlaceEditor {
    static let fieldId = "editcontent.field"

    private let viewer: DocumentViewer
    private var field: OverlayField?
    private var closing = false

    /// The text was kept: Return, or the control lost the focus. The editor is closed when this is called.
    var onKept: ((String) -> Void)?

    /// Escape, or Cancel on the keyboard bar.
    var onDropped: (() -> Void)?

    init(_ viewer: DocumentViewer) {
        self.viewer = viewer
    }

    var isOpen: Bool { field != nil }

    private(set) var page = 0

    var text: String { field?.text ?? "" }

    /// `area` is where the text is, in page space. `caret` is a place on the page for the caret to go; the end of the text
    /// without one. `wrap` makes the text wrap inside the width of `area` instead of growing to the right.
    func open(page: Int, area: ViewRect, text: String, look: OverlayTextLook, wrap: Bool, caret: ViewPoint? = nil) {
        close()
        self.page = page
        let made = OverlayField(Self.fieldId, area: area, text: text, look: look, wraps: wrap, multiline: false,
                                label: L10n.t("Text on the page"), caret: caret.map { FieldCaret.at($0) } ?? FieldCaret.end) { [weak self] result in
            self?.ended(result)
        }
        made.background = Self.background(look)
        field = made
        viewer.overlay(page).open(made)
    }

    /// Shows the text in another font, size or colour while it is open.
    func restyle(_ look: OverlayTextLook) {
        field?.look = look
        field?.background = Self.background(look)
    }

    /// Takes the box away without telling anyone.
    func close() {
        guard let old = field else { return }
        field = nil
        closing = true
        old.drop()
        closing = false
    }

    // The field is closed already when its result comes, whoever ended it.
    private func ended(_ result: String?) {
        if closing { return }
        field = nil
        if let result { onKept?(result) } else { onDropped?() }
    }

    // Light text gets a dark box and the other way round.
    private static func background(_ look: OverlayTextLook) -> OverlayColor {
        let c = look.color
        let light = (c.red * 0.3 + c.green * 0.59 + c.blue * 0.11) * 255 > 190
        return light ? .black : .white
    }
}
