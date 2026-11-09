import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Compare/CompareWindow.xaml.cs and CompareWindow.Marks.cs: the two files side by side, or the
// new one with what differs painted over it, in a sheet of its own. The panel owns the comparison; this shows it and goes
// where the change list says. A box for each difference and the picture of how a page differs are made for the pages in view
// only.

@MainActor
@Observable
public final class CompareWindowModel {
    private static let maxImages = 12
    static let markPrefix = "compare.m."
    static let pictureId = "compare.p."

    private static let green = OverlayColor(red: 46.0 / 255, green: 160.0 / 255, blue: 67.0 / 255)
    private static let red = OverlayColor(red: 209.0 / 255, green: 52.0 / 255, blue: 56.0 / 255)
    private static let amber = OverlayColor(red: 245.0 / 255, green: 160.0 / 255, blue: 0)
    private static let blue = OverlayColor(red: 0, green: 120.0 / 255, blue: 212.0 / 255)

    public let session: CompareSession
    public let oldViewer: ViewerModel
    public let newViewer: ViewerModel

    public private(set) var rows: [ChangeRow]
    public private(set) var overlayMode = false
    public private(set) var linked = true
    public private(set) var isClosed = false

    @ObservationIgnored private var sync: ViewSync?
    @ObservationIgnored private var watches: [ObservationWatch] = []
    @ObservationIgnored private var oldMarks: [Int: [(box: ViewRect, color: OverlayColor)]] = [:]
    @ObservationIgnored private var newMarks: [Int: [(box: ViewRect, color: OverlayColor)]] = [:]
    @ObservationIgnored private var oldDrawn = Set<Int>()
    @ObservationIgnored private var newDrawn = Set<Int>()
    @ObservationIgnored private var images: [Int: PdfRgbaImage] = [:]
    @ObservationIgnored private var tried = Set<Int>()
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var again = false

    public init(_ session: CompareSession, _ rows: [ChangeRow], _ renderers: @escaping () -> DocumentRenderer) {
        self.session = session
        self.rows = rows
        oldViewer = ViewerModel(makeRenderer: renderers, openAddress: { _ in })
        newViewer = ViewerModel(makeRenderer: renderers, openAddress: { _ in })
        oldViewer.show(session.old)
        newViewer.show(session.new)
        oldViewer.fit = .width
        newViewer.fit = .width
        sync = ViewSync(oldViewer, newViewer, session.result?.pages ?? [])
        for viewer in [oldViewer, newViewer] {
            watches.append(ObservationWatch(track: { _ = viewer.viewRevision; _ = viewer.visiblePages }, changed: { [weak self] in
                self?.viewChanged()
            }))
        }
        drawMarks()
    }

    public var title: String { L10n.t("Comparison of {0} and {1}", session.old.title, session.new.title) }
    public var oldTitle: String { L10n.t("Old: {0}", session.old.title) }
    public var newTitle: String { L10n.t("New: {0}", session.new.title) }

    public var legend: String {
        session.byPixels ? L10n.t("Blue marks places that look different.") : CompareText.legend
    }

    public func setRows(_ value: [ChangeRow]) {
        rows = value
        drawMarks()
    }

    public func go(_ row: ChangeRow) {
        if !overlayMode { show(oldViewer, row.oldPage, row.oldArea) }
        show(newViewer, row.newPage, row.newArea)
    }

    private func show(_ viewer: ViewerModel, _ page: Int, _ area: ViewRect?) {
        guard page >= 0, page < viewer.pageCount else { return }
        if let area { viewer.reveal(page, area) } else { viewer.goToPage(page) }
    }

    public func setOverlay(_ on: Bool) {
        overlayMode = on
        showPictures()
    }

    public func setLinked(_ on: Bool) {
        linked = on
        sync?.enabled = on
    }

    public func close() {
        if isClosed { return }
        isClosed = true
        watches.forEach { $0.stop() }
        watches = []
        sync?.detach()
        sync = nil
        for viewer in [oldViewer, newViewer] {
            viewer.endToolMarks(prefix: "compare.")
            viewer.show(nil)
        }
    }

    private func drawMarks() {
        clear(oldViewer, &oldDrawn)
        clear(newViewer, &newDrawn)
        oldMarks = [:]
        newMarks = [:]
        for row in rows {
            let color: OverlayColor
            switch row.kind {
            case .added: color = Self.green
            case .removed: color = Self.red
            case nil: color = Self.blue
            default: color = Self.amber
            }
            group(&oldMarks, row.oldPage, row.oldBoxes, color)
            group(&newMarks, row.newPage, row.newBoxes, color)
        }
        drawVisible()
    }

    private func group(_ marks: inout [Int: [(box: ViewRect, color: OverlayColor)]], _ page: Int, _ boxes: [ViewRect], _ color: OverlayColor) {
        if page < 0 || boxes.isEmpty { return }
        marks[page, default: []].append(contentsOf: boxes.map { ($0, color) })
    }

    private func clear(_ viewer: ViewerModel, _ drawn: inout Set<Int>) {
        for page in drawn { viewer.overlay(page).remove(prefix: Self.markPrefix + "\(page).") }
        drawn = []
    }

    private func viewChanged() {
        drawVisible()
        if overlayMode { loadPictures() }
    }

    private func drawVisible() {
        if isClosed { return }
        drawVisible(oldViewer, oldMarks, &oldDrawn)
        drawVisible(newViewer, newMarks, &newDrawn)
    }

    private func drawVisible(_ viewer: ViewerModel, _ marks: [Int: [(box: ViewRect, color: OverlayColor)]], _ drawn: inout Set<Int>) {
        let visible = viewer.visiblePages
        for page in drawn where !visible.contains(page) {
            viewer.overlay(page).remove(prefix: Self.markPrefix + "\(page).")
            drawn.remove(page)
        }
        for page in visible where page < viewer.pageCount && !drawn.contains(page) {
            guard let list = marks[page] else { continue }
            let overlay = viewer.overlay(page)
            for (n, mark) in list.enumerated() { overlay.set(item(page, n, mark.box, mark.color)) }
            drawn.insert(page)
        }
    }

    // Text that was removed leaves a box of no width: keep it visible.
    private func item(_ page: Int, _ n: Int, _ box: ViewRect, _ color: OverlayColor) -> OverlayItem {
        let width = max(box.width, 3), height = max(box.height, 3)
        let area = ViewRect(box.x - (width - box.width) / 2, box.y - (height - box.height) / 2, width, height)
        return OverlayItem(Self.markPrefix + "\(page).\(n)", .rect(area),
                           style: OverlayStyle(stroke: color.opacity(200.0 / 255), fill: color.opacity(70.0 / 255), lineWidth: 0.75))
    }

    private func showPictures() {
        for (page, image) in images {
            let overlay = newViewer.overlay(page)
            if overlayMode { overlay.set(picture(page, image)) } else { overlay.remove(Self.pictureId + "\(page)") }
        }
        if overlayMode { loadPictures() }
    }

    // One loop at a time: a view change while it runs asks it to look again, since the renderers do one page at a time.
    private func loadPictures() {
        if loading {
            again = true
            return
        }
        loading = true
        Task { [self] in
            defer { loading = false }
            repeat {
                again = false
                for page in newViewer.visiblePages {
                    if isClosed || !overlayMode { return }
                    if images[page] != nil || !tried.insert(page).inserted { continue }
                    let found = await session.overlay(page)
                    guard !isClosed, let found else { continue }
                    if !newViewer.visiblePages.contains(page) {
                        tried.remove(page)
                        continue
                    }
                    addPicture(page, found)
                }
            } while again
        }
    }

    private func addPicture(_ page: Int, _ image: PdfRgbaImage) {
        images[page] = image
        if overlayMode { newViewer.overlay(page).set(picture(page, image)) }
        while images.count > Self.maxImages {
            guard let far = images.keys.max(by: { abs($0 - page) < abs($1 - page) }) else { break }
            newViewer.overlay(far).remove(Self.pictureId + "\(far)")
            images[far] = nil
            tried.remove(far)
        }
    }

    private func picture(_ page: Int, _ image: PdfRgbaImage) -> OverlayItem {
        let size = newViewer.pageSize(page)
        return OverlayItem(Self.pictureId + "\(page)", .picture(OverlayPicture(image, rect: ViewRect(0, 0, size.width, size.height))), layer: -1)
    }
}
