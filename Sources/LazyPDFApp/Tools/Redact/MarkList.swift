import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Redact/MarkList.cs.

/// One entry of the review list: the mark and a few words to know it by.
public struct MarkItem: Identifiable, Equatable {
    public let id = UUID()
    public let mark: RedactionMark
    public let label: String

    public init(_ mark: RedactionMark, _ label: String) {
        self.mark = mark
        self.label = label
    }

    public var page: Int { mark.page }

    public var pageText: String { L10n.t("Page {0}", page + 1) }

    public var spoken: String { L10n.t("{0}, page {1}", label, page + 1) }

    public static func == (a: MarkItem, b: MarkItem) -> Bool { a.id == b.id }
}

/// What is marked on a document so far, in reading order. Nothing is written to the file until the redaction is applied.
public final class MarkList {
    private static let samePlace = 0.5

    // Marks by page and the unit square of their first corner, so that a new one is compared only with its neighbours.
    private struct Cell: Hashable {
        let page: Int
        let x: Int
        let y: Int
    }

    private var cells: [Cell: [MarkItem]] = [:]

    public private(set) var items: [MarkItem] = []

    /// Called after the list changed.
    public var changed: (() -> Void)?

    public init() {}

    /// Adds what is not marked already and returns how many were new.
    @discardableResult
    public func add(_ new: [MarkItem]) -> Int {
        var added = 0
        for item in new {
            if neighbours(item).contains(where: { Self.same($0.mark, item.mark) }) { continue }
            cells[cell(item), default: []].append(item)
            items.append(item)
            added += 1
        }
        if added == 0 { return 0 }
        // The keys are worked out once and the position breaks ties, so the order is the one the marks came in.
        items = items.enumerated().map { (at: $0.offset, item: $0.element, top: Self.top($0.element.mark), left: Self.left($0.element.mark)) }
            .sorted { a, b in
                if a.item.page != b.item.page { return a.item.page < b.item.page }
                if a.top != b.top { return a.top > b.top }
                return a.left != b.left ? a.left < b.left : a.at < b.at
            }.map { $0.item }
        changed?()
        return added
    }

    public func remove(_ item: MarkItem) {
        guard let at = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: at)
        cells[cell(item)]?.removeAll { $0.id == item.id }
        changed?()
    }

    public func clear() {
        if items.isEmpty { return }
        items = []
        cells = [:]
        changed?()
    }

    private func cell(_ item: MarkItem) -> Cell {
        let box = item.mark.quads[0].bounds
        return Cell(page: item.page, x: Int(box.left.rounded(.down)), y: Int(box.bottom.rounded(.down)))
    }

    private func neighbours(_ item: MarkItem) -> [MarkItem] {
        let at = cell(item)
        var found: [MarkItem] = []
        for dx in -1...1 {
            for dy in -1...1 { found += cells[Cell(page: at.page, x: at.x + dx, y: at.y + dy)] ?? [] }
        }
        return found
    }

    private static func top(_ mark: RedactionMark) -> Double { mark.quads.map { $0.bounds.top }.max() ?? 0 }

    private static func left(_ mark: RedactionMark) -> Double { mark.quads.map { $0.bounds.left }.min() ?? 0 }

    private static func same(_ a: RedactionMark, _ b: RedactionMark) -> Bool {
        guard a.page == b.page, a.quads.count == b.quads.count else { return false }
        return zip(a.quads, b.quads).allSatisfy { near($0.bounds, $1.bounds) }
    }

    private static func near(_ a: PdfRect, _ b: PdfRect) -> Bool {
        abs(a.left - b.left) < samePlace && abs(a.bottom - b.bottom) < samePlace
            && abs(a.right - b.right) < samePlace && abs(a.top - b.top) < samePlace
    }
}
