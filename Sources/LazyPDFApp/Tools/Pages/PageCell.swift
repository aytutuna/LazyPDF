import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Pages/PageCell.cs: one page in the organize grid. The picture is made when the grid shows
// the cell and let go of when it scrolls away; the marks show where a dragged page would land.

@MainActor
@Observable
public final class PageCell: Identifiable {
    public let index: Int

    /// A rebuilt grid has new cells for the same pages, and a grid keyed by page would not ask them for their pictures.
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
    public let label: String
    public let name: String
    public private(set) var width: Double
    public private(set) var height: Double

    /// Size of the picture in pixels per point of the page.
    public private(set) var scale: Double

    public private(set) var image: PdfRgbaImage?
    public var dropBefore = false
    public var dropAfter = false

    @ObservationIgnored private let renderer: DocumentRenderer?
    @ObservationIgnored private var density = 1.0
    @ObservationIgnored private var ticket = 0
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var shown = false

    public init(index: Int, label: String, width: Double, height: Double, scale: Double, renderer: DocumentRenderer?) {
        self.index = index
        self.label = label
        name = L10n.t("Page {0}", label)
        self.width = width
        self.height = height
        self.scale = scale
        self.renderer = renderer
    }

    /// The grid shows the cell: starts drawing the picture if it is not there and not coming. `displayScale` is the pixels of the
    /// screen in a point.
    public func appear(displayScale: Double) {
        shown = true
        density = displayScale
        fetch()
    }

    /// The grid scrolled the cell away.
    public func disappear() {
        shown = false
        release()
    }

    /// Changes the size the cell is drawn at; the picture it has stays until `sharpen` asks for a better one.
    public func refit(width: Double, height: Double, scale: Double) {
        self.width = width
        self.height = height
        self.scale = scale
    }

    /// Draws the picture again at the present size, keeping the old one on show until the new one is there.
    public func sharpen() {
        guard shown else { return }
        ticket += 1
        loading = false
        fetch()
    }

    /// Drops the picture; the next `appear` makes it again.
    public func release() {
        ticket += 1
        loading = false
        image = nil
    }

    private func fetch() {
        guard shown, !loading, let renderer else { return }
        loading = true
        let started = ticket
        let page = index
        let dpi = scale * 72 * density
        Task { [weak self] in
            await DrawTurns.shared.enter()
            var picture: PdfRgbaImage?
            if self?.ticket == started {
                picture = await Task.detached { renderer.render(page, dpi) }.value
            }
            await DrawTurns.shared.leave()
            guard let self, self.ticket == started else { return }
            // A page that could not be drawn stays marked as loading, so the grid does not ask again and again.
            if picture != nil || self.image == nil { self.image = picture }
        }
    }
}
