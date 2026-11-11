import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Panels/Pages/PageThumb.cs.

/// Thumbnails are drawn two at a time, so scrolling a long list does not queue the whole file.
actor DrawTurns {
    static let shared = DrawTurns()

    private var free = 2
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if free > 0 {
            free -= 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    func leave() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}

/// One page in the thumbnail list. The picture is made the first time the list asks for it and let go of when the row
/// scrolls away, so a long file holds only the thumbnails near the window.
@MainActor
@Observable
public final class PageThumb: Identifiable {
    public let index: Int
    public let objectNumber: Int

    /// A rebuilt list has new thumbnails for the same pages, and a list keyed by page would not ask them for their pictures.
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
    public let label: String
    public let name: String
    public let width: Double
    public let height: Double

    @ObservationIgnored private let dpi: Double
    @ObservationIgnored private let renderer: DocumentRenderer?
    @ObservationIgnored private var ticket = 0
    @ObservationIgnored private var loading = false

    public private(set) var image: PdfRgbaImage?
    /// The picture of the same page from the list this one replaced, shown until its own is made.
    public private(set) var stale: PdfRgbaImage?

    public var shown: PdfRgbaImage? { image ?? stale }

    public init(index: Int, objectNumber: Int, label: String, width: Double, height: Double, dpi: Double, renderer: DocumentRenderer?) {
        self.index = index
        self.objectNumber = objectNumber
        self.label = label
        name = L10n.t("Page {0}", label)
        self.width = width
        self.height = height
        self.dpi = dpi
        self.renderer = renderer
    }

    public func inherit(_ old: PageThumb) {
        if old.objectNumber == objectNumber && old.width == width && old.height == height { stale = old.image ?? old.stale }
    }

    /// Starts drawing the picture if it is not there and not coming.
    public func load() {
        guard image == nil, !loading, let renderer else { return }
        loading = true
        let started = ticket
        let page = index
        let density = dpi
        Task { [weak self] in
            await DrawTurns.shared.enter()
            var picture: PdfRgbaImage?
            if self?.ticket == started {
                picture = await Task.detached { renderer.render(page, density) }.value
            }
            await DrawTurns.shared.leave()
            guard let self, self.ticket == started else { return }
            // A page that could not be drawn stays marked as loading, so the list does not ask again and again.
            self.image = picture
            if picture != nil { self.stale = nil }
        }
    }

    /// Drops the picture; asking for it again makes it again.
    public func release() {
        ticket += 1
        loading = false
        image = nil
        stale = nil
    }
}
