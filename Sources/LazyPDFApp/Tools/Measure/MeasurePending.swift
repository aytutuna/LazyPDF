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
    let key: PageKey

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
