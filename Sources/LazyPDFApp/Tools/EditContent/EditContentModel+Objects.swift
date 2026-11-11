import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/EditContent/EditContentPanel.Objects.cs: pictures and shapes, replace, save, crop, colours,
// opacity, order, turning, deleting and adding pictures.

extension EditContentModel {
    public func deleteSelection() {
        guard let surface, let edits, !surface.selected.isEmpty else { return }
        let page = surface.page, ids = surface.selected
        if apply({ try edits.delete(page, ids) }, L10n.t("Deleted.")) { surface.clear() }
    }

    public func turn(left: Bool) {
        guard let surface, let edits, !surface.selected.isEmpty else { return }
        let page = surface.page, ids = surface.selected
        apply({ try edits.rotate(page, ids, left ? 90 : -90) }, L10n.t("Turned."))
    }

    public func flip(across: Bool) {
        guard let surface, let edits, let viewer, !surface.selected.isEmpty else { return }
        let page = surface.page, ids = surface.selected, turned = viewer.rotation
        apply({ try edits.flip(page, ids, acrossScreen: across, viewRotation: turned) }, L10n.t("Flipped."))
    }

    public func order(_ move: OrderMove) {
        guard let surface, let edits, surface.selected.count == 1, let o = edits.object(surface.page, surface.selected[0]) else { return }
        let page = surface.page, id = o.id
        if !apply({ try edits.order(page, id, move) }, L10n.t("Order changed.")) { return }

        // The object keeps its place on the page but not its number; it is the one of its kind with the same box.
        let same = edits.objects(page).filter { $0.kind == o.kind && $0.bounds == o.bounds }.map(\.id)
        let moved = move == .front || move == .forward ? same.max() : same.min()
        if let moved { surface.select(page, [moved]) }
    }

    /// Makes the selection a tenth smaller or larger about its middle: the way to resize without a handle.
    public func scaleSelection(by factor: Double) {
        guard let surface, let edits, !surface.selected.isEmpty else { return }
        let page = surface.page, ids = surface.selected
        let objects = edits.objects(page, ids)
        guard var box = objects.first?.bounds else { return }
        for o in objects.dropFirst() {
            box = PdfRect(Swift.min(box.left, o.bounds.left), Swift.min(box.bottom, o.bounds.bottom),
                          Swift.max(box.right, o.bounds.right), Swift.max(box.top, o.bounds.top))
        }
        let cx = (box.left + box.right) / 2, cy = (box.bottom + box.top) / 2
        let w = box.width * factor / 2, h = box.height * factor / 2
        let scaled = PdfRect(cx - w, cy - h, cx + w, cy + h)
        apply({ try edits.resize(page, ids, scaled) }, L10n.t("Resized."))
    }

    public func replaceImage() async {
        guard let surface, let host, let edits, surface.selected.count == 1 else { return }
        let id = surface.selected[0], page = surface.page
        guard let chosen = await host.filePicker.pickFiles([.picture], multiple: false).first, let file = readPicture(chosen) else { return }
        apply({ try edits.replaceImage(page, id, file) }, L10n.t("Picture replaced."))
    }

    public func extractImage() async {
        guard let surface, let host, let edits, surface.selected.count == 1 else { return }
        guard let picture = try? edits.extract(surface.page, surface.selected[0]) else {
            showMessage(EditingText.noImage, caution: true)
            return
        }
        let name = "picture." + picture.fileExtension
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lazypdf-" + UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(picture.data).write(to: file)
        } catch {
            host.showProblem(Problem(L10n.t("Picture not saved"), L10n.t("{0} could not be written. Choose another folder.", name)))
            return
        }
        if !(await host.fileExporter.export([file])).saved.isEmpty { host.setStatus(L10n.t("Picture saved.")) }
    }

    public func cropImage() {
        finishPending()
        surface?.setMode(.crop)
        refreshPanel()
    }

    func crop(_ page: Int, _ area: PdfRect) {
        guard let surface, let edits else { return }
        surface.setMode(.select)
        if surface.selected.count == 1, surface.page == page, let id = surface.selected.first, let image = edits.object(page, id) as? ImageObject {
            let kept = image.bounds.intersect(area)
            if !kept.isEmpty {
                apply({ try edits.crop(page, id, kept) }, L10n.t("Picture cropped."))
                return
            }
        }
        refreshPanel()
    }

    public func addPicture() async {
        guard let host, let viewer, let edits, let surface else { return }
        guard let chosen = await host.filePicker.pickFiles([.picture], multiple: false).first, let file = readPicture(chosen) else { return }
        finishPending()
        let page = viewer.pageIndex
        let size = viewer.pageSize(page)
        let width = size.width * 0.5, height = size.height * 0.5
        let box = viewer.geometry(page).toUser(DisplayRect((size.width - width) / 2, (size.height - height) / 2, width, height))
        if !apply({ try edits.addImage(page, box, file) }, L10n.t("Picture added.")) { return }
        if let last = edits.objects(page).last as? ImageObject { surface.select(page, [last.id]) }
    }

    private func readPicture(_ file: ToolFile) -> [UInt8]? {
        defer { file.access?.stop() }
        do {
            let bytes = [UInt8](try Data(contentsOf: file.url))
            return host?.imageCodec.map { SignatureArt.uprightFile(bytes, $0) } ?? bytes
        } catch {
            showMessage(L10n.t("{0} could not be read. Check that the file is still there.", file.url.lastPathComponent), caution: true)
            return nil
        }
    }

    // MARK: Shapes and opacity

    public func chooseFill(_ color: RgbColor) {
        shapeStyle(fill: color, stroke: nil, width: nil)
    }

    public func chooseLine(_ color: RgbColor) {
        shapeStyle(fill: nil, stroke: color, width: nil)
    }

    private func shapeStyle(fill: RgbColor?, stroke: RgbColor?, width: Double?) {
        guard let surface, let edits, !surface.selected.isEmpty else { return }
        let page = surface.page, ids = surface.selected
        apply({ try edits.pathStyle(page, ids, fill: fill, stroke: stroke, width: width) }, L10n.t("Shape changed."))
    }

    public func commitWidth() {
        let objects = selectedObjects()
        guard objects.count == 1, let path = objects[0] as? PathObject else { return }
        guard let width = Self.parse(widthText, min: 0, max: 200) else {
            widthText = Self.number(path.lineWidth)
            return
        }
        if abs(width - path.lineWidth) > 0.05 { shapeStyle(fill: nil, stroke: nil, width: width) }
    }

    // The slider settles for a moment before it is applied, to what it was moved on and not to what was chosen since.
    public func setOpacity(_ percent: Double) {
        guard let surface, !surface.selected.isEmpty else { return }
        opacity = percent
        if opacityTask == nil { opacityWanted = (surface.page, surface.selected, percent / 100) } else { opacityWanted?.value = percent / 100 }
        opacityTask?.cancel()
        opacityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            self?.fireOpacity()
        }
    }

    func flushOpacity() {
        if opacityTask == nil { return }
        opacityTask?.cancel()
        fireOpacity()
    }

    private func fireOpacity() {
        opacityTask = nil
        guard let edits, let wanted = opacityWanted else { return }
        opacityWanted = nil
        apply({ try edits.opacity(wanted.page, wanted.ids, wanted.value) }, L10n.t("Opacity changed."))
    }
}
