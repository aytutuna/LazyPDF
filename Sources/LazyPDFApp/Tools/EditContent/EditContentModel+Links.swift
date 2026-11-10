import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/EditContent/EditContentPanel.Links.cs: links, drag an area to make one, click one to change
// where it goes.

extension EditContentModel {
    func startLink(_ page: Int, _ area: PdfRect, _ old: PdfLink?) {
        guard let surface else { return }
        linkPage = page
        linkArea = area
        linkOld = old
        surface.showArea(old == nil ? page : -1, old == nil ? area : nil)
        surface.activeLink = old?.reference
        hideMessage()
        if let old {
            if let uri = old.uri {
                linkToPage = false
                linkText = uri
            } else if let destination = old.destination, destination.pageIndex >= 0 {
                linkToPage = true
                linkText = String(destination.pageIndex + 1)
            } else {
                linkText = ""
                showMessage(L10n.t("This link does something else. Saving replaces it."), caution: false)
            }
        } else {
            linkText = ""
        }
        refreshPanel()
        linkFocus += 1
    }

    /// Picks a link from the list.
    public func selectLink(_ row: EditRow) {
        guard let edits, let viewer, let surface else { return }
        let page = min(max(viewer.pageIndex, 0), viewer.pageCount - 1)
        let links = edits.links(page)
        guard row.id < links.count else { return }
        startLink(page, links[row.id].rect, links[row.id])
        viewer.reveal(page, surface.pageRect(page, links[row.id].rect))
    }

    func linkTarget() -> PdfAction? {
        ContentEdits.target(toPage: linkToPage, linkText, tab?.pageCount ?? 0)
    }

    /// The link box has an address or a page that can be used.
    public var canApplyLink: Bool { linkTarget() != nil }

    public func applyLink() {
        guard let edits, let area = linkArea, let target = linkTarget() else { return }
        let page = linkPage
        let old = linkOld
        let status = old == nil ? L10n.t("Link added.") : L10n.t("Link changed.")
        if apply({ try edits.setLink(page, area, target, old) }, status) { endLink() }
    }

    public func removeLink() {
        guard let edits, let link = linkOld else { return }
        let page = linkPage
        if apply({ try edits.removeLink(page, link) }, L10n.t("Link removed.")) { endLink() }
    }

    func endLink() {
        linkArea = nil
        linkOld = nil
        surface?.showArea(-1, nil)
        surface?.activeLink = nil
        refreshPanel()
    }
}
