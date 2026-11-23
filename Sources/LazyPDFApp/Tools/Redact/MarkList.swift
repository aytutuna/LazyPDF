import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Redact/MarkList.cs.

/// One entry of the review list: the mark and a few words to know it by. A `value` is a hit in a comment or a field; its mark
/// is only where the comment or field sits, and it is not applied as a mark.
public struct MarkItem: Identifiable, Equatable {
    public let id: UUID

    /// What the list shows the item by: a box that was moved or resized is a new item in the same row.
    public let row: UUID
    public let mark: RedactionMark
    public let label: String
    public let isBox: Bool
    public let value: RedactionValueMatch?
    public let place: String?

    public init(_ mark: RedactionMark, _ label: String, isBox: Bool = false, value: RedactionValueMatch? = nil, place: String? = nil, row: UUID? = nil) {
        let id = UUID()
        self.id = id
        self.mark = mark
        self.label = label
        self.isBox = isBox
        self.value = value
        self.place = place
        self.row = row ?? id
    }

    public var page: Int { mark.page }

    public var pageText: String { place ?? L10n.t("Page {0}", page + 1) }

    public var spoken: String { place.map { L10n.t("{0}, {1}", label, $0) } ?? L10n.t("{0}, page {1}", label, page + 1) }

    public static func == (a: MarkItem, b: MarkItem) -> Bool { a.id == b.id }
}

/// What is marked on a document so far, in reading order. Nothing is written to the file until the redaction is applied.
public final class MarkList {
    private static let samePlace = 0.5
    private static let maxSteps = 20

    // Marks by page and the unit square of their first corner, so that a new one is compared only with its neighbours.
    private struct Cell: Hashable {
        let page: Int
        let x: Int
        let y: Int
    }

    private var cells: [Cell: [MarkItem]] = [:]
    private var history: [[MarkItem]] = []

    // The item the last coalescing replace produced, so a run of nudges of it is one step of undo.
    private var lastEdited: UUID?

    public private(set) var items: [MarkItem] = []

    public var canUndo: Bool { !history.isEmpty }

    /// Called after the list changed.
    public var changed: (() -> Void)?

    public init() {}

    /// Adds what is not marked already and returns how many were new.
    @discardableResult
    public func add(_ new: [MarkItem]) -> Int {
        let before = items
        var added = 0
        for item in new {
            if neighbours(item).contains(where: { Self.same($0, item) }) { continue }
            cells[cell(item), default: []].append(item)
            items.append(item)
            added += 1
        }
        if added == 0 { return 0 }
        push(before)
        items = Self.sorted(items)
        changed?()
        return added
    }

    public func remove(_ item: MarkItem) {
        guard let at = items.firstIndex(where: { $0.id == item.id }) else { return }
        push(items)
        items.remove(at: at)
        cells[cell(item)]?.removeAll { $0.id == item.id }
        changed?()
    }

    /// Takes out the hits in comments and fields, which are tied to places in text that may since have changed.
    @discardableResult
    public func removeValues() -> Bool {
        guard items.contains(where: { $0.value != nil }) else { return false }
        push(items)
        items.removeAll { $0.value != nil }
        rebuildCells()
        changed?()
        return true
    }

    /// Puts `new` where `old` was, for a box that was moved or resized. One step of undo, or, with `coalesce`, the same
    /// step as the last coalescing replace of `old` when that is what made it. Like Windows, it does not look for a twin.
    public func replace(_ old: MarkItem, _ new: MarkItem, coalesce: Bool = false) {
        guard items.contains(where: { $0.id == old.id }) else { return }
        if coalesce && old.id == lastEdited {
            lastEdited = new.id
        } else {
            push(items)
            lastEdited = coalesce ? new.id : nil
        }
        items = Self.sorted(items.filter { $0.id != old.id } + [new])
        rebuildCells()
        changed?()
    }

    public func clear() {
        if items.isEmpty { return }
        push(items)
        items = []
        cells = [:]
        changed?()
    }

    public func undo() {
        guard let last = history.popLast() else { return }
        lastEdited = nil
        items = last
        rebuildCells()
        changed?()
    }

    /// Drops the history, for when the marks no longer belong to the file. Changed is raised so a shown Undo goes away.
    public func forget() {
        lastEdited = nil
        if history.isEmpty { return }
        history = []
        changed?()
    }

    private func push(_ before: [MarkItem]) {
        lastEdited = nil
        history.append(before)
        if history.count > Self.maxSteps { history.removeFirst() }
    }

    private func rebuildCells() {
        cells = [:]
        for item in items { cells[cell(item), default: []].append(item) }
    }

    // The keys are worked out once and the position breaks ties, so the order is the one the marks came in.
    private static func sorted(_ items: [MarkItem]) -> [MarkItem] {
        items.enumerated().map { (at: $0.offset, item: $0.element, top: top($0.element.mark), left: left($0.element.mark)) }
            .sorted { a, b in
                if a.item.page != b.item.page { return a.item.page < b.item.page }
                if a.top != b.top { return a.top > b.top }
                return a.left != b.left ? a.left < b.left : a.at < b.at
            }.map { $0.item }
    }

    private func cell(_ item: MarkItem) -> Cell {
        let box = item.mark.quads[0].bounds
        return Cell(page: item.page, x: Self.index(box.left), y: Self.index(box.bottom))
    }

    // Far beyond any page, so a crafted coordinate lands in an edge cell instead of overflowing the conversion.
    private static func index(_ value: Double) -> Int {
        let limit = 1e12
        if !(value > -limit) { return Int(-limit) }
        return value < limit ? Int(value.rounded(.down)) : Int(limit)
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

    private static func same(_ a: MarkItem, _ b: MarkItem) -> Bool {
        if a.value != nil || b.value != nil {
            guard let x = a.value, let y = b.value else { return false }
            return (x.page, x.annotation, x.source, x.start, x.length) == (y.page, y.annotation, y.source, y.start, y.length)
        }
        return same(a.mark, b.mark)
    }

    private static func same(_ a: RedactionMark, _ b: RedactionMark) -> Bool {
        guard a.page == b.page, a.quads.count == b.quads.count else { return false }
        return zip(a.quads, b.quads).allSatisfy { near($0.bounds, $1.bounds) }
    }

    private static func near(_ a: PdfRect, _ b: PdfRect) -> Bool {
        abs(a.left - b.left) < samePlace && abs(a.bottom - b.bottom) < samePlace
            && abs(a.right - b.right) < samePlace && abs(a.top - b.top) < samePlace
    }
}
