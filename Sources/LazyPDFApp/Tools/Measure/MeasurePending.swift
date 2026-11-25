import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Measure/MeasurePending.cs.

/// What identifies a page and its shape: a page that was turned, cropped or rescaled is not the one a measurement was taken on.
struct PageKey: Equatable {
    let number: Int
    let rotate: Int
    let box: PdfRect
    let unit: Double

    static func of(_ page: PdfPage) -> PageKey {
        PageKey(number: page.reference.number, rotate: page.rotate, box: page.cropBox, unit: page.userUnit)
    }
}

/// A measurement waiting to be written, with the page it was taken on.
struct Pending: Equatable {
    let id = UUID()
    var item: MeasureItem
    var key: PageKey

    /// The ones whose page is still in the file as it was, moved to where that page is now.
    static func keep(_ pending: [Pending], _ document: PdfDocument) -> [Pending] {
        var location: [Int: (index: Int, key: PageKey)] = [:]
        for i in 0..<document.pages.count {
            let page = document.pages[i]
            location[page.reference.number] = (i, PageKey.of(page))
        }
        return pending.compactMap { waiting in
            guard let now = location[waiting.key.number], now.key == waiting.key else { return nil }
            var moved = waiting
            moved.item.page = now.index
            return moved
        }
    }
}

extension Pending {
    /// The same measurements with their pages under the numbers a rewrite gave them. One whose page is not in the map is gone,
    /// and gets a number no page has so that `keep` drops it.
    static func remap(_ pending: [Pending], _ map: [Int: Int]) -> [Pending] {
        pending.map { waiting in
            var moved = waiting
            moved.key = PageKey(number: map[waiting.key.number] ?? -1, rotate: waiting.key.rotate, box: waiting.key.box, unit: waiting.key.unit)
            return moved
        }
    }
}
