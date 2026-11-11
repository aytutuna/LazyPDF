import Foundation
import LazyPDFKit

// Follows AccessibilityPanel.Figures.cs: the figures of the file, each with its picture beside the box for its description.

extension AccessibilityModel {
    var selectedRow: FigureRow? { figures.first { $0.number == selectedFigure } }

    func renderFigures() {
        let rows = allFigures
        figures = rows
        let bare = rows.filter { !$0.hasDescription }.count
        if treeFailed {
            figuresNote = L10n.t("The tags could not be read.")
        } else if tree == nil {
            figuresNote = L10n.t("The file has no tags, so no figures are known. Add tags first.")
        } else if tree?.isTruncated == true {
            figuresNote = L10n.t("The tags are too large to list every figure.")
        } else if rows.isEmpty {
            figuresNote = L10n.t("The file has no figures.")
        } else if bare == 0 {
            figuresNote = L10n.t("Every figure has a description.")
        } else {
            figuresNote = L10n.t("{0} of {1} figures have no description.", bare, rows.count)
        }
        if rows.isEmpty {
            selectedFigure = nil
            return
        }
        let keep = figureNumber - 1
        let first = rows.firstIndex { !$0.hasDescription } ?? 0
        selectFigure(rows[keep >= 0 && keep < rows.count ? keep : first].number)
    }

    /// A figure was picked in the list: its text and picture are shown and the viewer goes to its page.
    public func selectFigure(_ number: Int) {
        guard let row = figures.first(where: { $0.number == number }) else { return }
        selectedFigure = number
        figureNumber = number
        altText = drafts[number] ?? row.alt
        rememberDraft()
        canFindBare = figures.contains { !$0.hasDescription }
        if row.page >= 0 { viewer?.goToPage(row.page) }
        showPicture(row)
    }

    private func showPicture(_ row: FigureRow) {
        pictureTicket += 1
        let ticket = pictureTicket
        figurePicture = nil
        figureNoPicture = false
        guard let copy = treeCopy, let tab else {
            figureNoPicture = true
            return
        }
        let renderer = tab.renderer
        let lock = treeLock
        Task { [self] in
            // The copy is read by one picture at a time.
            let picture = await Task.detached { FigurePictures.picture(copy, row.element, row.page, renderer, lock) }.value
            if ticket != pictureTicket { return }
            figurePicture = picture
            figureNoPicture = picture == nil
        }
    }

    /// The description box changed.
    public func typeAlt(_ text: String) {
        altText = text
        rememberDraft()
    }

    private func rememberDraft() {
        guard let row = selectedRow else {
            canSaveAlt = false
            return
        }
        let changed = altText.trimmingCharacters(in: .whitespacesAndNewlines) != row.alt
        drafts[row.number] = changed ? altText : nil
        canSaveAlt = changed
    }

    public func saveAlt() {
        guard let row = selectedRow, let tab, let host else { return }
        let text = altText
        ChangeGate.run(tab, host, L10n.t("Figure description")) { [self] in
            guard self.tab === tab else { return }
            do {
                // The tree on the screen was read from a copy; the edit goes to the open document's own.
                let tree = StructureTree.read(tab.document)
                let list = tree.map { FigureFinder.list($0) } ?? []
                guard let tree, list.indices.contains(row.number - 1) else {
                    host.showProblem(Problem(L10n.t("Description not saved"), L10n.t("The figure is no longer in the file.")))
                    return
                }
                try AccessibilityEdits.setAlt(tab.document, tree, list[row.number - 1].element, text)
                if try tab.commit(L10n.t("Figure description")) { host.setStatus(L10n.t("Description saved.")) }
            } catch let error where error is InvalidOperationException || error is PdfReadException {
                try? tab.session.discard()
                host.showProblem(Problem(L10n.t("Description not saved"), L10n.t("The tags of this file are too large to change here.")))
                return
            }
            drafts[row.number] = nil
            figureNumber = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? row.number : nextBareAfter(row.number, row.number)
        }
    }

    /// Goes to the next figure with no description.
    public func nextBare() {
        guard let row = selectedRow else { return }
        selectFigure(nextBareAfter(row.number, 0))
    }

    // The number of the next figure with no description, wrapping round, and counting the one just saved as described.
    func nextBareAfter(_ number: Int, _ saved: Int) -> Int {
        for step in 1...max(figures.count, 1) where !figures.isEmpty {
            let index = (number - 1 + step) % figures.count
            if index + 1 != saved && !figures[index].hasDescription { return index + 1 }
        }
        return number
    }
}

/// The picture of a figure: its box on the page, drawn large enough to see.
enum FigurePictures {
    static func picture(_ document: PdfDocument, _ figure: StructElement, _ page: Int, _ renderer: PageRenderer, _ lock: NSLock) -> PdfRgbaImage? {
        lock.lock()
        let found = FigureFinder.box(document, figure, page)
        lock.unlock()
        guard let box = found else { return nil }
        let region = DisplayRect(box.x - 4, box.y - 4, box.width + 8, box.height + 8)
        let dpi = min(max(200 * 72 / region.width, 36), 288)
        guard let image = renderer.render(page, dpi) else { return nil }
        lock.lock()
        let size = PageGeometry(document.pages[page])
        lock.unlock()
        return crop(image, region, Double(image.width) / size.width, Double(image.height) / size.height)
    }

    /// The part of `image` that `region` (page points) covers at `sx`, `sy` pixels to the point.
    static func crop(_ image: PdfRgbaImage, _ region: DisplayRect, _ sx: Double, _ sy: Double) -> PdfRgbaImage? {
        let left = max(Int((region.x * sx).rounded(.down)), 0), top = max(Int((region.y * sy).rounded(.down)), 0)
        let right = min(Int(((region.x + region.width) * sx).rounded(.up)), image.width)
        let bottom = min(Int(((region.y + region.height) * sy).rounded(.up)), image.height)
        if right <= left || bottom <= top { return nil }
        var pixels = [UInt8]()
        pixels.reserveCapacity((right - left) * (bottom - top) * 4)
        for y in top..<bottom {
            let start = (y * image.width + left) * 4
            pixels.append(contentsOf: image.rgba[start..<start + (right - left) * 4])
        }
        return PdfRgbaImage(right - left, bottom - top, pixels)
    }
}
