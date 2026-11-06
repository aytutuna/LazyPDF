import Foundation

// Twin of windows/LazyPDF.Core/Compare/Comparison.Document.cs: what the files say apart from their pages: metadata,
// bookmarks, attachments and form values.

/// A Dictionary with string keys that keeps the order they were added in, which is the order .NET enumerates one in when
/// nothing was removed; the differences come out in that order. Keys are compared by UTF-16 unit, as `Dictionary<string, T>`
/// does by default.
struct InsertionMap<Value> {
    private var list: [(key: String, value: Value)] = []
    private var index: [[UInt16]: Int] = [:]

    var entries: [(key: String, value: Value)] { list }

    func lookup(_ key: String) -> Value? {
        guard let at = index[Array(key.utf16)] else { return nil }
        return list[at].value
    }

    func contains(_ key: String) -> Bool { index[Array(key.utf16)] != nil }

    mutating func set(_ key: String, _ value: Value) {
        let units = Array(key.utf16)
        if let at = index[units] {
            list[at].value = value
        } else {
            index[units] = list.count
            list.append((key, value))
        }
    }
}

extension Comparison {
    func compareDocuments(_ pairs: [PagePair], _ changes: inout [CompareChange]) throws {
        compareMetadata(&changes)
        compareBookmarks(pairs, &changes)
        try compareAttachments(&changes)
        compareForms(&changes)
    }

    private static func document(_ kind: ChangeKind, _ oldText: String?, _ newText: String?, _ detail: String) -> CompareChange {
        CompareChange(kind, .document, -1, -1, oldText ?? "", newText ?? "", [], [], detail)
    }

    /// One change for each value that differs between two keyed lists.
    static func compareValues(_ before: InsertionMap<String?>, _ after: InsertionMap<String?>, _ detail: (String) -> String, _ changes: inout [CompareChange]) {
        for (key, value) in after.entries {
            let old: String? = before.lookup(key) ?? nil
            let oldEmpty = (old ?? "").isEmpty, newEmpty = (value ?? "").isEmpty
            if oldEmpty && newEmpty { continue }
            if oldEmpty {
                changes.append(document(.added, nil, value, detail(key)))
            } else if newEmpty {
                changes.append(document(.removed, old, nil, detail(key)))
            } else if let o = old, let v = value, !Ordinal.equal(o, v) {
                changes.append(document(.changed, o, v, detail(key)))
            }
        }
        for (key, old) in before.entries where !after.contains(key) && !(old ?? "").isEmpty {
            changes.append(document(.removed, old, nil, detail(key)))
        }
    }

    private func compareMetadata(_ changes: inout [CompareChange]) {
        func clock(_ date: DateTimeOffset?) -> String? {
            guard let date else { return nil }
            let local = DateTimeOffset(valid: date.year, date.month, date.day, date.hour, date.minute, date.second)
            guard let utc = local?.addSeconds(-date.offsetMinutes * 60) else { return nil }
            return String(format: "%04ld-%02ld-%02ld %02ld:%02ld:%02ldZ", utc.year, utc.month, utc.day, utc.hour, utc.minute, utc.second)
        }
        func fields(_ document: PdfDocument) -> InsertionMap<String?> {
            let m = DocumentMetadata.read(document)
            var result = InsertionMap<String?>()
            result.set("Title", m.title)
            result.set("Author", m.author)
            result.set("Subject", m.subject)
            result.set("Keywords", m.keywords)
            result.set("Creator", m.creator)
            result.set("Producer", m.producer)
            result.set("Created", clock(m.created))
            result.set("Modified", clock(m.modified))
            for (key, value) in m.custom { result.set(key, value) }
            return result
        }
        Self.compareValues(fields(before), fields(after), CompareText.metadata, &changes)
    }

    private struct Bookmark {
        let level: Int
        let title: String
        let page: Int
    }

    private func compareBookmarks(_ pairs: [PagePair], _ changes: inout [CompareChange]) {
        let oldList = Self.flatten(Outline.read(before).root, 0)
        let newList = Self.flatten(Outline.read(after).root, 0)
        if oldList.isEmpty && newList.isEmpty { return }
        var ids: [[UInt16]: Int] = [:]
        func id(_ b: Bookmark) -> Int {
            let key = Array("\(b.level)\t\(b.title)".utf16)
            if let known = ids[key] { return known }
            let next = ids.count
            ids[key] = next
            return next
        }
        let a = oldList.map(id), b = newList.map(id)
        func titles(_ list: [Bookmark], _ from: Int, _ count: Int) -> String {
            list.dropFirst(from).prefix(count).map { $0.title }.joined(separator: "; ")
        }

        let hunks = SequenceDiff.diff(a, b)
        for h in hunks {
            let kind: ChangeKind = h.oldCount == 0 ? .added : h.newCount == 0 ? .removed : .changed
            changes.append(Self.document(kind, titles(oldList, h.oldStart, h.oldCount), titles(newList, h.newStart, h.newCount), CompareText.bookmark))
        }

        var newOf: [Int: Int] = [:]
        for p in pairs where p.oldIndex >= 0 && p.newIndex >= 0 { newOf[p.oldIndex] = p.newIndex }
        var i = 0, j = 0
        func equal(_ x: Int, _ y: Int) {
            if oldList[x].page < 0 || newList[y].page < 0 { return }
            if newOf[oldList[x].page] != newList[y].page {
                changes.append(Self.document(.changed, oldList[x].title, newList[y].title, CompareText.bookmarkPage))
            }
        }
        for h in hunks {
            while i < h.oldStart {
                equal(i, j)
                i += 1
                j += 1
            }
            (i, j) = (h.oldStart + h.oldCount, h.newStart + h.newCount)
        }
        while i < oldList.count {
            equal(i, j)
            i += 1
            j += 1
        }
    }

    private static func flatten(_ parent: OutlineItem, _ level: Int) -> [Bookmark] {
        var list: [Bookmark] = []
        for item in parent.children {
            list.append(Bookmark(level: level, title: item.title, page: item.destination?.pageIndex ?? -1))
            list.append(contentsOf: flatten(item, level + 1))
        }
        return list
    }

    private func compareForms(_ changes: inout [CompareChange]) {
        func values(_ document: PdfDocument) -> InsertionMap<String?> {
            var result = InsertionMap<String?>()
            for field in PdfForm.read(document).fields where field.kind != .signature {
                if result.contains(field.name) { continue }
                result.set(field.name, field.selected.count > 1 ? field.selected.joined(separator: "; ") : field.value)
            }
            return result
        }
        Self.compareValues(values(before), values(after), CompareText.formField, &changes)
    }
}
