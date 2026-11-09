import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Stamps/StampsPanel.Runs.cs and StampsPanel.Fill.cs: the stamps already in the file, listing
// them, loading one into the form to update it, and taking them off. A run picked goes back into the form: all of it when this
// session wrote it, what the file keeps otherwise.

/// One stamp run of the file, in the list.
public struct RunRow: Identifiable, Equatable {
    public let info: StampInfo
    let pageCount: Int

    public var id: Int { info.id }

    init(_ info: StampInfo, _ pageCount: Int) {
        self.info = info
        self.pageCount = pageCount
    }

    public static func == (a: RunRow, b: RunRow) -> Bool {
        a.id == b.id && a.info.kind == b.info.kind && a.info.label == b.info.label && a.info.pages == b.info.pages
    }

    public var title: String {
        switch info.kind {
        case .watermark:
            if info.label == "image" { return L10n.t("Picture watermark") }
            if let label = info.label, !label.isEmpty { return label }
            return L10n.t("Watermark")
        case .background: return L10n.t("Background")
        case .bates: return L10n.t("Bates numbers")
        case .headerFooter: return L10n.t("Header and footer")
        }
    }

    public var details: String {
        let kind: String
        switch info.kind {
        case .watermark: kind = L10n.t("Watermark")
        case .background: kind = L10n.t("Background")
        case .bates: kind = L10n.t("Bates numbers")
        case .headerFooter: kind = L10n.t("Header and footer")
        }
        let pages = info.pages.count == pageCount ? L10n.t("All pages") : L10n.plural(info.pages.count, one: "{0} page", other: "{0} pages")
        let what = info.kind == .headerFooter && !(info.label ?? "").isEmpty ? info.label ?? kind : kind
        return what + " · " + pages
    }

    public var summary: String { title + ", " + details }
}

extension StampsModel {
    func buildRuns() {
        guard let tab else { return }
        let keep = selected?.id
        let rows = PdfStamper(tab.document).list().map { RunRow($0, tab.pageCount) }
        written = written.filter { $0.key.tab != tab.id || rows.contains { row in row.id == $0.key.run } }
        runs = rows
        selected = rows.first { $0.id == keep }
    }

    /// Picks a run of the list, or none to describe a new stamp.
    public func select(_ row: RunRow?) {
        selected = row
        if let row { load(row.info) }
        // A loaded run is already on the pages; its preview waits for the first edit.
        touched = false
        previewOn = row == nil
        refresh()
    }

    public func addNewInstead() {
        select(nil)
    }

    private func load(_ info: StampInfo) {
        guard let tab else { return }
        var loaded = form
        switch info.kind {
        case .background: loaded.mode = .background
        case .headerFooter: loaded.mode = .headerFooter
        case .bates: loaded.mode = .bates
        case .watermark: loaded.mode = .watermark
        }
        if let draft = written[WrittenRun(tab: tab.id, run: info.id)], draft.kind == info.kind {
            fill(draft, &loaded)
        } else {
            fromFile(info, &loaded)
        }
        if info.pages.count == tab.pageCount {
            loaded.pages = .all
        } else {
            loaded.pages = .typed
            loaded.pagesText = PageChoice.describe(info.pages)
        }
        form = loaded
    }

    // The file keeps a run's kind, a label and its pages. What it does not keep is left empty, so the update asks for it again.
    private func fromFile(_ info: StampInfo, _ form: inout StampForm) {
        setPicture(nil)
        switch info.kind {
        case .watermark:
            form.watermarkText = info.label == "image" ? "" : info.label ?? ""
            form.behind = info.behind
        case .headerFooter:
            form.headerLeft = ""
            form.headerCentre = ""
            form.headerRight = ""
            form.footerLeft = ""
            form.footerCentre = ""
            form.footerRight = ""
        case .bates:
            form.start = ""
        case .background:
            break
        }
    }

    private func fill(_ draft: StampDraft, _ form: inout StampForm) {
        setPicture(draft.picture)
        if let mark = draft.watermark {
            form.watermarkText = mark.text ?? ""
            look(mark.fontFamily, mark.fontStyle, mark.color, &form)
            form.opacity = mark.opacity * 100
            form.turn = mark.rotation
            form.scale = mark.scale * 100
            form.place = mark.anchor.rawValue
            form.behind = mark.behind
            form.layer = mark.layerName != nil
        } else if let back = draft.background {
            form.backColor = max(0, backColors.firstIndex { $0.color == back.color } ?? 0)
            form.fit = back.fit == .cover ? 0 : back.fit == .contain ? 1 : 2
            form.opacity = back.opacity * 100
            form.layer = back.layerName != nil
        } else if let spec = draft.headerFooter {
            look(spec.fontFamily, spec.fontStyle, spec.color, &form)
            form.textSize = spec.fontSize
            form.margin = spec.marginX
            if let bates = spec.bates {
                form.prefix = bates.prefix
                form.suffix = bates.suffix
                form.digits = String(bates.digits)
                form.start = String(bates.start)
                let header = !(spec.header.left.isEmpty && spec.header.center.isEmpty && spec.header.right.isEmpty)
                let band = header ? spec.header : spec.footer
                form.batesPlace = (header ? 0 : 3) + (!band.left.isEmpty ? 0 : !band.center.isEmpty ? 1 : 2)
            } else {
                form.headerLeft = spec.header.left
                form.headerCentre = spec.header.center
                form.headerRight = spec.header.right
                form.footerLeft = spec.footer.left
                form.footerCentre = spec.footer.center
                form.footerRight = spec.footer.right
                form.firstNumber = String(spec.startNumber)
                form.dateFormat = spec.dateFormat
            }
        }
    }

    private func look(_ family: String, _ style: FontStyles, _ color: StampColor, _ form: inout StampForm) {
        form.family = max(0, families.firstIndex(of: family) ?? 0)
        form.bold = style.contains(.bold)
        form.italic = style.contains(.italic)
        form.color = max(0, colors.firstIndex { $0.color == color } ?? 0)
    }

    // MARK: Removing

    public func removeSelected() async {
        guard let row = selected else { return }
        await takeOff(L10n.t("Removing the stamp"), L10n.t("Remove stamp"), L10n.t("Stamp removed.")) { document in
            PdfStamper(document).remove(row.id)
        }
    }

    public func removeAll() async {
        await takeOff(L10n.t("Removing the stamps"), L10n.t("Remove all stamps"), L10n.t("Stamps removed.")) { document in
            PdfStamper(document).removeAll()
        }
    }

    private func takeOff(_ busy: String, _ label: String, _ status: String, _ remove: @escaping @Sendable (PdfDocument) -> Int) async {
        guard let tab, let host else { return }
        await ChangeGate.runAsync(tab, host, label) { [self] in
            try await working {
                guard try await editDocument(tab, host, busy, remove) != nil else { return }
                previewOn = false
                clearPreviews()
                if try tab.commit(label) { host.setStatus(status) }
                buildRuns()
                refresh()
            }
        }
    }
}
