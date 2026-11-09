import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Forms/FieldFrames.cs: the outlines of the fields on the pages in view while they are being
// edited, the selected one with handles, and the fields the detector found.

@MainActor
final class FieldFrames {
    private static let prefix = "forms.frame."
    private static let handleSize = 8.0
    private static let wash = OverlayColor.accent.opacity(0.18)

    private let viewer: DocumentViewer
    private var form: PdfForm?
    private var name: String?
    private var index = 0
    private var ordinal = 0
    private var proposals: [FieldProposal] = []
    private var drawn = Set<Int>()

    init(_ viewer: DocumentViewer) {
        self.viewer = viewer
    }

    /// The centres of the eight handles of a box, clockwise from the top left corner.
    static func handles(_ box: ViewRect) -> [ViewPoint] {
        let cx = box.x + box.width / 2, cy = box.y + box.height / 2
        return [ViewPoint(box.left, box.top), ViewPoint(cx, box.top), ViewPoint(box.right, box.top), ViewPoint(box.right, cy),
                ViewPoint(box.right, box.bottom), ViewPoint(cx, box.bottom), ViewPoint(box.left, box.bottom), ViewPoint(box.left, cy)]
    }

    func show(_ form: PdfForm, selected: String?, index: Int, ordinal: Int, proposals: [FieldProposal]) {
        self.form = form
        name = selected
        self.index = index
        self.ordinal = ordinal
        self.proposals = proposals
        redraw()
    }

    /// Draws again when other pages came into view. The marks keep their size at any zoom, so a zoom needs nothing.
    func follow() {
        if form != nil && drawn != Set(viewer.visiblePages) { redraw() }
    }

    func clear() {
        for page in drawn { viewer.overlay(page).remove(prefix: Self.prefix) }
        drawn = []
        form = nil
    }

    private func redraw() {
        guard let form else { return }
        let visible = Set(viewer.visiblePages)
        for page in drawn { viewer.overlay(page).remove(prefix: Self.prefix) }
        drawn = visible
        var seen: [String: Int] = [:]
        var byPage: [Int: [(widget: FormWidget, selected: Bool)]] = [:]
        for field in form.fields {
            let own = seen[field.name, default: 0]
            seen[field.name] = own + 1
            for (i, widget) in field.widgets.enumerated() {
                byPage[widget.pageIndex, default: []].append((widget, field.name == name && i == index && own == ordinal))
            }
        }
        for page in visible {
            let overlay = viewer.overlay(page)
            let geometry = viewer.geometry(page)
            var n = 0
            func put(_ shape: OverlayShape, _ style: OverlayStyle) {
                overlay.set(OverlayItem(Self.prefix + "\(page).\(n)", shape, style: style))
                n += 1
            }
            for (widget, selected) in byPage[page] ?? [] {
                let box = Self.box(geometry.toDisplay(widget.rect))
                put(.rect(box), OverlayStyle(stroke: .accent, fill: selected ? Self.wash : nil, lineWidth: selected ? 2.5 : 1.25))
                if selected {
                    for centre in Self.handles(box) {
                        put(.marker(center: centre, size: Self.handleSize, round: false),
                            OverlayStyle(stroke: .accent, fill: .white, lineWidth: 1.5))
                    }
                }
            }
            for proposal in proposals where proposal.pageIndex == page {
                put(.rect(Self.box(geometry.toDisplay(proposal.rect))),
                    OverlayStyle(stroke: .accent, fill: Self.wash, lineWidth: 1.5, dash: [4, 3]))
            }
        }
    }

    static func box(_ d: DisplayRect) -> ViewRect {
        ViewRect(d.x, d.y, d.width, d.height)
    }
}
