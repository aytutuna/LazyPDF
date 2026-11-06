import Foundation
import LazyPDFKit

// Port of windows/LazyPDF.App/Viewer/RevisionDiff.cs: which pages a commit, an undo or a redo can have changed. An edit
// session only ever appends to its buffer or cuts back to an earlier end, so the objects that differ are the ones defined
// in the stretch by which the longer buffer exceeds the shorter.

public enum RevisionDiff {
    private static let maxObjects = 5000

    // Keys that lead away from the page: up to the page tree and sideways to other pages. They mean that only in the
    // dictionaries of the page, its annotations and structure; in a resource dictionary a key is any name.
    private static let away: Set<String> = ["Parent", "P", "Prev", "Next", "StructParent", "StructParents", "Dest", "A", "AA", "Popup", "IRT"]

    private static let marker = Array(" obj".utf8)

    /// The numbers of the objects defined in the part of one buffer that the other does not have, or nil when neither buffer
    /// begins with the other (the file was rewritten) and everything counts as changed.
    public static func changed(_ before: [UInt8], _ after: [UInt8]) -> Set<Int>? {
        let (shorter, longer) = before.count <= after.count ? (before, after) : (after, before)
        guard longer.starts(with: shorter) else { return nil }
        var numbers = Set<Int>()
        let tail = longer[shorter.count...]
        var at = tail.startIndex
        while let end = find(marker, in: tail, from: at) {
            at = end + marker.count
            // "12 0 obj": the generation, a space, then the number.
            var i = end - 1
            while i >= tail.startIndex && isDigit(tail[i]) { i -= 1 }
            if i < tail.startIndex || i == end - 1 || tail[i] != 0x20 { continue }
            let stop = i - 1
            var j = stop
            while j >= tail.startIndex && isDigit(tail[j]) { j -= 1 }
            if j == stop || stop - j > 9 { continue }
            numbers.insert(tail[(j + 1)...stop].reduce(0) { $0 * 10 + Int($1 - 0x30) })
        }
        return numbers
    }

    /// Whether the page, or anything it draws with (contents, resources, annotations and what those lead to), or a page tree
    /// node it inherits from, is among `changed`.
    public static func touches(_ document: PdfDocument, _ page: PdfPage, _ changed: Set<Int>) -> Bool {
        if let root = document.trailer["Root"] as? PdfReference, changed.contains(root.number) { return true }
        if changed.contains(page.reference.number) { return true }
        if parentChanged(document, page.dictionary, changed) { return true }
        var seen = Set<Int>()
        var queue: [(value: PdfObject, resources: Bool)] = [(page.dictionary, false)]
        var head = 0
        while head < queue.count {
            // A walk that stops short may have missed the change, and a picture that is too old stays on screen.
            if seen.count >= maxObjects { return true }
            let (value, resources) = queue[head]
            head += 1
            switch value {
            case let reference as PdfReference:
                if !seen.insert(reference.number).inserted { break }
                if changed.contains(reference.number) { return true }
                if let target = document.get(reference.number) { queue.append((target, resources)) }
            case let stream as PdfStream:
                queue.append((stream.dictionary, resources))
            case let dictionary as PdfDictionary:
                // A form field's value, which a widget without an appearance is drawn from, can sit on a parent field.
                if !resources && document.name(dictionary, "Subtype") == "Widget" && parentChanged(document, dictionary, changed) { return true }
                for (key, item) in dictionary.entries where resources || !away.contains(key) {
                    queue.append((item, resources || key == "Resources"))
                }
            case let array as PdfArray:
                for item in array.items { queue.append((item, resources)) }
            default:
                break
            }
        }
        return false
    }

    private static func parentChanged(_ document: PdfDocument, _ start: PdfDictionary, _ changed: Set<Int>) -> Bool {
        var node: PdfDictionary? = start
        var depth = 0
        while depth < 32, let current = node {
            if let up = current["Parent"] as? PdfReference, changed.contains(up.number) { return true }
            node = document.dict(current, "Parent")
            depth += 1
        }
        return false
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private static func find(_ pattern: [UInt8], in bytes: ArraySlice<UInt8>, from start: Int) -> Int? {
        var i = start
        while i + pattern.count <= bytes.endIndex {
            if bytes[i] == pattern[0] && bytes[i..<(i + pattern.count)].elementsEqual(pattern) { return i }
            i += 1
        }
        return nil
    }
}
