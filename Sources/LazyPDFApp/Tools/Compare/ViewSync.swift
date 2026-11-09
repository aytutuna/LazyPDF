import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Compare/ViewSync.cs. Makes two viewers of the two files scroll and zoom together. The
// one that was moved leads; the other is moved so that the same place of the paired page sits at the same place of its view.
// There is no pointer to ask on iOS, and a move the follower made itself is told apart by the revision it ended on.

@MainActor
public final class ViewSync {
    // Reveal only moves when the area is outside the middle of the view, and then centres it; an area this big never fits.
    private static let reach = 100000.0

    private let old: ViewerModel
    private let new: ViewerModel
    private let pairs: [PagePair]
    private var oldWatch: ObservationWatch?
    private var newWatch: ObservationWatch?
    private var echo: [ObjectIdentifier: Int] = [:]

    public var enabled = true

    public init(_ old: ViewerModel, _ new: ViewerModel, _ pairs: [PagePair]) {
        self.old = old
        self.new = new
        self.pairs = pairs
        oldWatch = ObservationWatch(track: { _ = old.viewRevision }, changed: { [weak self] in
            guard let self else { return }
            self.follow(self.old, self.new, fromOld: true)
        })
        newWatch = ObservationWatch(track: { _ = new.viewRevision }, changed: { [weak self] in
            guard let self else { return }
            self.follow(self.new, self.old, fromOld: false)
        })
    }

    public func detach() {
        oldWatch?.stop()
        newWatch?.stop()
        oldWatch = nil
        newWatch = nil
    }

    /// The page of the other file that stands for `page`; a page without a partner takes its neighbour's.
    public static func partner(_ pairs: [PagePair], _ page: Int, fromOld: Bool) -> Int {
        guard let at = pairs.firstIndex(where: { (fromOld ? $0.oldIndex : $0.newIndex) == page }) else { return -1 }
        func other(_ pair: PagePair) -> Int { fromOld ? pair.newIndex : pair.oldIndex }
        for i in at..<pairs.count where other(pairs[i]) >= 0 { return other(pairs[i]) }
        for i in stride(from: at - 1, through: 0, by: -1) where other(pairs[i]) >= 0 { return other(pairs[i]) }
        return -1
    }

    private func follow(_ leader: ViewerModel, _ follower: ViewerModel, fromOld: Bool) {
        if !enabled || echo[ObjectIdentifier(leader)] == leader.viewRevision { return }
        if follower.fit != leader.fit { follower.fit = leader.fit }
        if leader.fit == .none && abs(follower.zoom - leader.zoom) > 1e-6 { follower.zoom = leader.zoom }
        let middle = ViewPoint(leader.viewport.width / 2, leader.viewport.height / 2)
        if let at = leader.viewToPage(middle, nearest: true) {
            let page = Self.partner(pairs, at.page, fromOld: fromOld)
            if page >= 0 && page < follower.pageCount { show(follower, page, at.point, middle) }
        }
        echo[ObjectIdentifier(follower)] = follower.viewRevision
    }

    // The second reveal corrects for the bar above the pages, which the first one does not know about.
    private func show(_ viewer: ViewerModel, _ page: Int, _ point: ViewPoint, _ wanted: ViewPoint) {
        viewer.reveal(page, Self.around(point))
        guard let matrix = viewer.pageToView(page) else { return }
        let shown = matrix.inverted().transform(wanted)
        let shift = ViewPoint(point.x - shown.x, point.y - shown.y)
        if abs(shift.x) + abs(shift.y) > 0.5 { viewer.reveal(page, Self.around(ViewPoint(point.x + shift.x, point.y + shift.y))) }
    }

    private static func around(_ point: ViewPoint) -> ViewRect {
        ViewRect(point.x - reach, point.y - reach, 2 * reach, 2 * reach)
    }
}
