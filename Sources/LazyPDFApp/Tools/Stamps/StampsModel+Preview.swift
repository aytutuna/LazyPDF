import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Stamps/StampsPanel.Preview.cs: the pending stamp drawn on the pages in view, until the person
// changes the form again or writes it. The marks are the overlay's own, so they follow the page and need no redraw on a zoom;
// they are made again when the form changes and when the pages in view do.

extension StampsModel {
    func updatePreview() {
        guard let viewer, let tab else { return }
        let draft = previewOn ? readDraft().draft : nil
        let visible = Set(viewer.visiblePages)
        for page in previewPages where !visible.contains(page) || draft == nil { clear(page) }
        guard let draft else { return }

        let (pages, _) = PageChoice.resolve(form.pages, form.pagesText, tab.pageCount)
        let targets = PageChoice.targets(pages, tab.pageCount)
        for page in visible.sorted() {
            clear(page)
            guard let ordinal = targets.firstIndex(of: page) else { continue }
            let items = StampPreview.build(draft, picture: pictureImage, page: page, pageCount: tab.pageCount, ordinal: ordinal,
                                           size: viewer.pageSize(page), fileName: tab.title, now: PanelDates.now())
            if items.isEmpty { continue }
            let overlay = viewer.overlay(page)
            for item in items { overlay.set(item) }
            previewPages.insert(page)
        }
    }

    func clearPreviews() {
        for page in previewPages { clear(page) }
    }

    private func clear(_ page: Int) {
        previewPages.remove(page)
        if let viewer, page < viewer.pageCount { viewer.overlay(page).remove(prefix: StampPreview.prefix) }
    }
}
