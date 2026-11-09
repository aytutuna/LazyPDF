import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/EditContent/EditSurface.Chrome.cs: what the surface draws on the pages: the selection with
// its handles, the area being dragged and the links. Marks keep their size on the screen whatever the zoom, so a zoom does not
// draw them again; only a change of the selection, the gesture or the file does.

extension EditSurface {
    static let prefix = "editcontent.chrome."
    private static let tint = OverlayColor.accent.opacity(0.15)

    /// Outlines an area the person dragged and the panel has not used yet; a negative page takes it away.
    func showArea(_ page: Int, _ area: PdfRect?) {
        let old = areaPage
        areaPage = area == nil ? -1 : page
        if let area, page >= 0 { self.area = pageRect(page, area) }
        redraw(old)
        redraw(areaPage)
    }

    func redrawAll() {
        var pages = Set(viewer.visiblePages).union(chromePages)
        pages.insert(page)
        for each in pages { redraw(each) }
    }

    func redraw(_ page: Int) {
        guard page >= 0, page < viewer.pageCount else { return }
        let marks = chrome(page)
        if marks.isEmpty && !chromePages.contains(page) { return }
        let overlay = viewer.overlay(page)
        overlay.remove(prefix: Self.prefix)
        for (n, mark) in marks.enumerated() { overlay.set(OverlayItem(Self.prefix + String(n), mark.shape, style: mark.style)) }
        if marks.isEmpty { chromePages.remove(page) } else { chromePages.insert(page) }
    }

    func removeChrome() {
        for page in chromePages where page < viewer.pageCount { viewer.overlay(page).remove(prefix: Self.prefix) }
        chromePages = []
    }

    private typealias Mark = (shape: OverlayShape, style: OverlayStyle)

    private func chrome(_ page: Int) -> [(shape: OverlayShape, style: OverlayStyle)] {
        var marks: [Mark] = []
        if mode == .link {
            for link in links(page) {
                let active = link.reference != nil && link.reference == activeLink
                marks.append(outline(pageRect(page, link.rect), active ? 2.4 : 1.05, dashed: !active, fill: active ? Self.tint : nil))
            }
        }
        if page == self.page && !selected.isEmpty && mode != .crop { selection(&marks) }
        if page == areaPage { marks.append(outline(area, 1.5, dashed: true, fill: Self.tint)) }
        if gesture == .band && moved && page == gesturePage {
            marks.append(outline(ViewRect(from: start, to: now), 1.5, dashed: mode != .select, fill: Self.tint))
        }
        return marks
    }

    private func selection(_ marks: inout [Mark]) {
        var bounds = selectionBounds()
        if bounds.isEmpty { return }
        if selected.count > 1 {
            for id in selected {
                if let o = edits.object(page, id) { marks.append(outline(pageRect(page, o.bounds), 0.9, dashed: true, fill: nil)) }
            }
        }
        if gesture == .move && moved {
            bounds.x += now.x - start.x
            bounds.y += now.y - start.y
            marks.append(outline(bounds, 1.5, dashed: true, fill: Self.tint))
            return
        }
        if gesture == .resize && moved {
            marks.append(outline(resized(), 1.5, dashed: true, fill: Self.tint))
            return
        }
        marks.append(outline(bounds, 1.5, dashed: false, fill: nil))
        for at in Self.handles(bounds) {
            marks.append((.marker(center: at, size: 8, round: false), OverlayStyle(stroke: .accent, fill: .white, lineWidth: 1.5)))
        }
    }

    private func outline(_ rect: ViewRect, _ width: Double, dashed: Bool, fill: OverlayColor?) -> Mark {
        (.rect(rect), OverlayStyle(stroke: .accent, fill: fill, lineWidth: width, dash: dashed ? [4, 3] : []))
    }
}
