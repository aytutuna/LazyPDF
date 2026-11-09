import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/FillSign/FillSignPanel.xaml.cs: a signature, initials, a line of text or today's date, put on
// the page where the pointer says.

/// A saved signature in the list.
public struct SavedRow: Identifiable {
    public let item: SavedItem
    public let image: PdfRgbaImage

    public var id: String { item.url.lastPathComponent }

    public var name: String { item.kind == .initials ? L10n.t("Saved initials") : L10n.t("Saved signature") }
}

public struct DateChoice: Equatable {
    public let pattern: String
    public let sample: String
}

@MainActor
@Observable
public final class FillSignModel: ToolPanelModel {
    public enum Kind {
        case signature, initials, text, date
    }

    public static let sizes = [10, 12, 14, 18, 24, 36]
    private static let datePatterns = ["d MMMM yyyy", "dd.MM.yyyy", "yyyy-MM-dd", "M/d/yyyy"]

    public private(set) var kind = Kind.signature
    public private(set) var saved: [SavedRow] = []
    public private(set) var selected: String?
    public var words = ""
    public var size = 12
    public var formatIndex = 0
    public private(set) var dates: [DateChoice] = []

    /// The pointer is armed: the next tap or drag on a page places the thing.
    public private(set) var placing = false
    public private(set) var hint = ""

    /// The sheet that makes a new signature is up.
    public var showMaker = false
    public let maker: SignatureMakerModel

    var tab: DocumentTab?
    var host: ToolHost?
    var viewer: DocumentViewer?
    var image: PdfRgbaImage?
    @ObservationIgnored private let store: SavedSignatures
    @ObservationIgnored private let fonts: FontSource
    @ObservationIgnored private var tool: PlacementTool?
    @ObservationIgnored private var cautioned = false

    public init(store: SavedSignatures, fonts: FontSource, system: SignatureSystem, codec: ImageCodec) {
        self.store = store
        self.fonts = fonts
        maker = SignatureMakerModel(system: system, codec: codec)
        dates = Self.datePatterns.map { DateChoice(pattern: $0, sample: Self.format($0, Date())) }
        showKind()
    }

    public var action: ToolAction? {
        ToolAction(placing ? L10n.t("Stop placing") : L10n.t("Place on page"), symbol: placing ? "xmark" : "plus", canRun: { [self] in placing || ready },
                   run: { [self] in arm() })
    }

    public var isImage: Bool { kind == .signature || kind == .initials }

    private var savedKind: SavedKind { kind == .initials ? .initials : .signature }

    private var ready: Bool {
        isImage ? image != nil : kind == .date || !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.viewer = viewer
        self.host = host
        cautioned = false
    }

    public func detach() {
        stop()
        tab = nil
        viewer = nil
        host = nil
    }

    public func selectKind(_ kind: Kind) {
        self.kind = kind
        showKind()
    }

    private func showKind() {
        stop()
        image = nil
        selected = nil
        if isImage { fillSaved() }
    }

    private func fillSaved() {
        saved = store.list(savedKind).compactMap { item in store.load(item).map { SavedRow(item: item, image: $0) } }
        selected = saved.first?.id
        image = saved.first?.image
    }

    public func select(_ row: SavedRow) {
        selected = row.id
        image = store.load(row.item)
        stop()
    }

    public func remove(_ row: SavedRow) {
        store.remove(row.item)
        fillSaved()
    }

    public func makeNew() {
        stop()
        maker.reset()
        showMaker = true
    }

    public func cancelMaker() {
        showMaker = false
    }

    /// The sheet's Use: the image made is the one to place, and kept for next time when the switch says so.
    public func useMade() {
        guard let made = maker.image else { return }
        showMaker = false
        if maker.keep {
            do {
                let item = try store.add(savedKind, made)
                fillSaved()
                selected = item.url.lastPathComponent
            } catch {
                host?.showProblem(Problem(L10n.t("Signature not kept"), L10n.t("It could not be saved. It can still be placed this time.")))
                selected = nil
            }
        } else {
            selected = nil
        }
        image = made
    }

    public func chooseMakerPicture() async {
        guard let host else { return }
        await maker.choosePicture(using: host.filePicker)
    }

    // MARK: Placing

    private func arm() {
        guard let tab, let host else { return }
        if tool != nil {
            stop()
            return
        }
        if let problem = FillSignPlacement.refusal(tab.document) {
            host.showProblem(problem)
        } else if !cautioned, let caution = FillSignPlacement.caution(tab.document) {
            host.showNotice(L10n.t("Check before going on"), caution, NoticeAction(L10n.t("Go on anyway")) { [weak self] in self?.goOn() })
        } else {
            begin()
        }
    }

    private func goOn() {
        guard tab != nil else { return }
        cautioned = true
        begin()
    }

    private func begin() {
        guard let viewer, let host else { return }
        let aspect = isImage ? Double(image?.width ?? 1) / Double(max(image?.height ?? 1, 1)) : 0
        let made = PlacementTool(viewer, aspect: aspect, placed: { [weak self] page, from, to in self?.placed(page, from, to) },
                                 stopped: { [weak self] in self?.stop() })
        tool = made
        viewer.pointerTool = made
        placing = true
        hint = (aspect > 0 ? L10n.t("Click the page, or drag a box, to place it.") : L10n.t("Click the page where the text starts."))
            + " " + L10n.t("Or press Enter on the page.")
        host.setStatus(L10n.t("Click where it should go."))
    }

    func stop() {
        guard let made = tool else { return }
        tool = nil
        if viewer?.pointerTool === made { viewer?.pointerTool = nil }
        placing = false
        hint = ""
    }

    private func placed(_ page: Int, _ from: ViewPoint, _ to: ViewPoint?) {
        guard let tab, let host, let viewer else { return }
        stop()
        let now = PanelDates.now()
        do {
            if isImage {
                guard let image else { return }
                let aspect = Double(image.width) / Double(image.height)
                let pageSize = viewer.pageSize(page)
                let dragged = to.map { FillSignPlacement.fromDrag(from, $0, aspect, pageSize) }
                let box = dragged.flatMap { $0.width >= 20 ? $0 : nil }
                    ?? FillSignPlacement.around(from, kind == .initials ? FillSignPlacement.initialsWidth : FillSignPlacement.signatureWidth, aspect, pageSize)
                try FillSignPlacement.placeImage(tab, page, box, image, now)
            } else {
                try FillSignPlacement.placeText(tab, fonts, page, from, textToPlace(), Double(size), now)
            }
        } catch let error as InvalidOperationException {
            try? tab.session.discard()
            host.showProblem(Problem(L10n.t("Text cannot be drawn"), error.message))
            return
        } catch {
            try? tab.session.discard()
            host.showProblem(error is PdfPermissionException ? Problems.restricted()
                : Problem(L10n.t("Something went wrong"), L10n.t("{0} could not be finished. If part of it was done, Undo takes it back.", L10n.t("Place on page"))))
            return
        }
        host.setStatus(L10n.t("Placed on page {0}.", page + 1))
    }

    /// The text that goes on the page: the words typed, or today's date in the format chosen.
    func textToPlace() -> String {
        kind == .date ? Self.format(dates[min(max(formatIndex, 0), dates.count - 1)].pattern, Date()) : words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func format(_ pattern: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
