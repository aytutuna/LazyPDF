import Foundation
import LazyPDFKit

// The sections under the grid (PagesPanel.Sections.cs): one is open at a time, and the pinned button does what the open one
// sets up.

extension PagesToolModel {
    public var action: ToolAction? {
        switch section {
        case .crop:
            return ToolAction(L10n.t("Crop pages"), symbol: "crop", canRun: { [self] in cropBox != nil }, run: { [self] in cropPages() })
        case .resize:
            return ToolAction(L10n.t("Resize pages"), symbol: "arrow.up.left.and.arrow.down.right", canRun: { [self] in size != nil },
                              run: { [self] in resizePages() })
        case .labels:
            return ToolAction(L10n.t("Number pages"), symbol: "number", canRun: { [self] in start != nil }, run: { [self] in numberPages() })
        default:
            return nil
        }
    }

    /// A section was opened or closed with its header.
    public func setExpanded(_ opened: Section, _ expanded: Bool) {
        if expanded {
            disarm()
            section = opened
            arm()
        } else if section == opened {
            disarm()
            section = .none
        }
    }

    // The crop box is drawn on the pages, so the viewer's pointer belongs to the crop section while it is open and the switch is on.
    func arm() {
        guard section == .crop, let viewer else { return }
        let tool = CropTool(viewer)
        tool.onChange = { [weak self, weak tool] in
            guard let self else { return }
            self.cropBox = tool?.box
            if let box = tool?.box, let tab = self.tab { self.boxSpace = self.space(box.page, tab.document) }
            self.selectBoxPage()
        }
        crop = tool
        modeWatch = ObservationWatch(track: { _ = viewer.pointerTool }, changed: { [weak self] in
            // The viewer's Hand and Select buttons took the pointer; the box stays until the switch is turned on again.
            guard let self, let current = self.crop, self.cropDrawing, self.viewer?.pointerTool !== current else { return }
            self.cropDrawing = false
        })
        setDrawing(true)
    }

    func disarm() {
        guard let tool = crop else { return }
        tool.onChange = nil
        modeWatch?.stop()
        modeWatch = nil
        if let viewer, viewer.pointerTool === tool { viewer.pointerTool = nil }
        tool.clear()
        crop = nil
        cropBox = nil
        cropDrawing = false
    }

    public func setDrawing(_ on: Bool) {
        guard let crop, let viewer else { return }
        cropDrawing = on
        if on {
            viewer.pointerTool = crop
        } else if viewer.pointerTool === crop {
            viewer.pointerTool = nil
        }
    }

    func selectBoxPage() {
        guard let box = cropBox, !cropAll, box.page < grid.cells.count, !grid.selected.contains(box.page) else { return }
        grid.select([box.page])
    }

    public var cropHint: String {
        let pages = grid.selection
        let every = L10n.t("Every page is changed.")
        let kept = " " + L10n.t("The rest of the page stays in the file, only hidden. Redact removes it for good.")
        let covered = pages.isEmpty ? every
            : L10n.plural(pages.count, one: "{0} selected page is changed.", other: "{0} selected pages are changed.")
        if let box = cropBox {
            let width = Int((box.area.width / PageEdits.pointsPerMillimetre).rounded())
            let height = Int((box.area.height / PageEdits.pointsPerMillimetre).rounded())
            let changed = cropAll ? every : !pages.isEmpty ? covered : L10n.t("Page {0} is changed.", box.page + 1)
            return L10n.t("Box of {0} by {1} mm.", width, height) + " " + changed + kept
        }
        return (cropDrawing ? L10n.t("Drag a box on a page.") : L10n.t("Turn on drawing to drag a box.")) + kept
    }

    public var resizeHint: String {
        let pages = grid.selection
        let covered = pages.isEmpty ? L10n.t("Every page is changed.")
            : L10n.plural(pages.count, one: "{0} selected page is changed.", other: "{0} selected pages are changed.")
        return L10n.t("Pages keep their orientation.") + " " + covered
    }

    public var labelHint: String {
        let pages = grid.selection
        let note = " " + L10n.t("This sets the page numbers viewers show. Nothing is printed on the pages.")
        guard let first = pages.first, let last = pages.last else { return L10n.t("Every page is numbered.") + note }
        return L10n.t("Pages {0} to {1} are numbered.", first + 1, last + 1) + note
    }

    public var showsCustomSize: Bool { paperIndex == PaperSize.all.count }

    /// The chosen paper in points; nil while the custom size is not a number within what a page can be.
    var size: (width: Double, height: Double)? {
        let papers = PaperSize.all
        if paperIndex < 0 { return nil }
        if paperIndex < papers.count { return (papers[paperIndex].width, papers[paperIndex].height) }
        guard let width = PageEdits.number(customWidth), let height = PageEdits.number(customHeight) else { return nil }
        let points = (width: width * PageEdits.pointsPerMillimetre, height: height * PageEdits.pointsPerMillimetre)
        return (10...14400).contains(points.width) && (10...14400).contains(points.height) ? points : nil
    }

    var start: Int? {
        guard labelStart.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }), let number = Int(labelStart), number >= 1 else { return nil }
        return number
    }

    func cropPages() {
        guard let box = cropBox, let crop else { return }
        let count = grid.cells.count
        let chosen = grid.selection
        let pages = (cropAll ? Array(0..<count) : chosen.isEmpty ? [box.page] : chosen).filter { $0 < count }
        guard let tab, let host else { return }
        let targets = PageEdits.cropTargets(tab.document, pages, box.area)
        if targets.isEmpty {
            host.showProblem(Problem(L10n.t("Box is off the pages"), L10n.t("The box does not touch the pages to crop. Draw it again on a page.")))
            return
        }
        let left = pages.count - targets.count
        var status = L10n.plural(targets.count, one: "{0} page cropped", other: "{0} pages cropped")
        if left > 0 {
            status += " " + L10n.plural(left, one: "{0} page was left alone because the box is outside it.",
                                        other: "{0} pages were left alone because the box is outside them.")
        }
        let done = grid.apply(L10n.t("Crop pages"), select: chosen, status: status) { document in
            try PageEdits.crop(document, targets, box.area)
        }
        if done { crop.clear() }
    }

    public func removeCrop() {
        let pages = grid.selectedOrAll
        grid.apply(L10n.t("Remove crop"), select: grid.selection, status: L10n.t("Crop removed.")) { document in
            try PageOperations.setBox(document, pages, .crop, nil)
        }
    }

    func resizePages() {
        guard let size else { return }
        let pages = grid.selectedOrAll
        let mode: ResizeMode = scaleContent ? .scaleContent : .changeBox
        grid.apply(L10n.t("Resize pages"), select: grid.selection,
                   status: L10n.plural(pages.count, one: "{0} page resized", other: "{0} pages resized")) { document in
            try PageEdits.resizeTo(document, pages, size.width, size.height, mode)
        }
    }

    func numberPages() {
        guard let start else { return }
        let span = PageEdits.span(grid.selectedOrAll)
        let styles: [PageLabelStyle] = [.decimal, .lowerRoman, .upperRoman, .lowerLetters, .upperLetters, .none]
        let style = styles.indices.contains(labelStyleIndex) ? styles[labelStyleIndex] : .decimal
        let prefix = labelPrefix
        grid.apply(L10n.t("Number pages"), select: grid.selection, status: L10n.t("Pages numbered.")) { document in
            try PageEdits.relabel(document, span.first, span.last, style, prefix, start)
        }
    }

    public func removeLabels() {
        grid.apply(L10n.t("Remove page labels"), select: grid.selection, status: L10n.t("Labels removed.")) { document in
            try PageEdits.clearLabels(document)
        }
    }
}
