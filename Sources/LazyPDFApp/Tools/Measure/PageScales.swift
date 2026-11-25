import Foundation
import LazyPDFKit

// Follows PageScales in windows/LazyPDF.App/Tools/Measure/MeasurePanel.xaml.cs.

/// The scale of each page: one typed for it, else one written on it, else the one for the file.
final class PageScales {
    private var typed: [Int: MeasureScale] = [:]
    private var found: [Int: MeasureScale?] = [:]
    private var overridden = false

    private(set) var defaultScale: MeasureScale

    init(_ start: MeasureScale) {
        defaultScale = start
    }

    static func key(_ document: PdfDocument, _ page: Int) -> Int { document.pages[page].reference.number }

    /// A page that is gone (the viewer can be a step ahead of the panel) takes the file's scale.
    func scale(_ document: PdfDocument, _ page: Int) -> MeasureScale {
        guard page >= 0, page < document.pages.count else { return defaultScale }
        if let own = typed[Self.key(document, page)] { return own }
        return overridden ? defaultScale : writtenOn(document, page) ?? defaultScale
    }

    func set(_ key: Int, _ scale: MeasureScale) {
        typed[key] = scale
    }

    func setAll(_ scale: MeasureScale) {
        defaultScale = scale
        typed.removeAll()
        overridden = true
    }

    /// Writing marks changes what the pages hold.
    func forgetFound() {
        found.removeAll()
    }

    /// A rewrite numbers the objects again; a page that is not in the map is gone.
    func remap(_ map: [Int: Int]) {
        typed = Dictionary(uniqueKeysWithValues: typed.compactMap { key, scale in map[key].map { ($0, scale) } })
        found = Dictionary(uniqueKeysWithValues: found.compactMap { key, scale in map[key].map { ($0, scale) } })
    }

    /// Object numbers come back after an undo, so what was typed for a page that is gone must not reach the next one.
    func prune(_ document: PdfDocument) {
        let live = Set((0..<document.pages.count).map { Self.key(document, $0) })
        typed = typed.filter { live.contains($0.key) }
    }

    /// How many pages of the document other than this one have a scale of their own that `setAll` would replace.
    func otherScaleCount(except key: Int, _ document: PdfDocument) -> Int {
        var count = 0
        for page in 0..<document.pages.count {
            let pageKey = Self.key(document, page)
            if pageKey == key { continue }
            if typed[pageKey] != nil {
                count += 1
            } else if !overridden, writtenOn(document, page) != nil {
                count += 1
            }
        }
        return count
    }

    private func writtenOn(_ document: PdfDocument, _ page: Int) -> MeasureScale? {
        let key = Self.key(document, page)
        if let known = found[key] { return known }
        let read = MeasureScale.findOnPage(document, document.pages[page])
        found[key] = .some(read)
        return read
    }
}
