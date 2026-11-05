import Foundation

// Twin of windows/LazyPDF.Core/Optimize/LinearizerHints.cs: the primary hint stream (F.4): the page offset table,
// then the shared object table. The first page's objects are each a group of the shared table, ahead of the groups
// of the shared section, so that the groups cover the file from the first page's object onward without a gap.

private struct PageHint {
    let objects: Int
    let length: Int
    let shared: [Int]
    let contentOffset: Int
    let contentLength: Int
}

private struct BitWriter {
    private var bytes: [UInt8] = []
    private var used = 0

    var length: Int { bytes.count }

    mutating func write(_ value: Int, _ bits: Int) {
        for b in stride(from: bits - 1, through: 0, by: -1) {
            if used == 0 { bytes.append(0) }
            if (value >> b) & 1 != 0 { bytes[bytes.count - 1] |= UInt8(0x80 >> used) }
            used = (used + 1) & 7
        }
    }

    mutating func align() { used = 0 }

    func toArray() -> [UInt8] { bytes }
}

extension Linearizer {
    /// The hint stream object, from offsets that do not count the stream itself.
    func hintStream(_ at: [Int]) -> [UInt8] {
        var entryOf: [Int: Int] = [:]
        for (i, o) in part6.enumerated() { entryOf[o] = i }
        for (i, o) in part8.enumerated() { entryOf[o] = part6.count + i }

        var pages: [PageHint] = []
        for p in 0..<pageItem.count {
            let objects = pageObjects[p]
            let (offset, span) = contentSpan(p)
            let shared = pageShared[p].compactMap { entryOf[$0] }.sorted()
            pages.append(PageHint(objects: objects.count, length: objects.reduce(0) { $0 + length[$1] }, shared: shared, contentOffset: offset, contentLength: span))
        }
        let groups = (part6 + part8).map { length[$0] }
        let sharedFirstAt = part8.isEmpty ? 0 : at[part8[0]]
        let sharedFirst = part8.isEmpty ? 0 : number[part8[0]]
        var outline: [Int]?
        if let first = outlines.first {
            outline = [number[first], at[first], outlines.count, outlines.reduce(0) { $0 + length[$1] }]
        }
        let (tables, sharedAt, outlineAt) = Self.tables(pages, at[part6[0]], groups, part6.count, sharedFirst, sharedFirstAt, outline)

        let dictionary = PdfDictionary()
        dictionary.add("S", PdfNumber(sharedAt))
        if outline != nil { dictionary.add("O", PdfNumber(outlineAt)) }
        let writer = PdfObjectWriter(position: 0, security: options.security)
        writer.writeStream(hintNumber, 0, dictionary, tables)
        return writer.output
    }

    /// Where the page's content streams start in its section and how long they run; 0 and 0 when they are not in it.
    private func contentSpan(_ page: Int) -> (offset: Int, length: Int) {
        var wanted = Set<Int>()
        func add(_ value: PdfObject?) {
            if let reference = value as? PdfReference, let item = index[reference.number] { wanted.insert(item) }
        }
        var contents = pageDictionary(pageItem[page])["Contents"]
        add(contents)
        if let reference = contents as? PdfReference, let at = index[reference.number] { contents = items[at] }
        if let array = contents as? PdfArray {
            for item in array.items { add(item) }
        }

        var position = 0
        var first = -1
        var end = 0
        for o in pageObjects[page] {
            if wanted.contains(o) {
                if first < 0 { first = position }
                end = position + length[o]
            }
            position += length[o]
        }
        return first < 0 ? (0, 0) : (first, end - first)
    }

    private static func tables(_ pages: [PageHint], _ firstPageAt: Int, _ groups: [Int], _ firstGroups: Int, _ sharedFirst: Int, _ sharedFirstAt: Int, _ outline: [Int]?) -> (bytes: [UInt8], sharedAt: Int, outlineAt: Int) {
        let minObjects = pages.map { $0.objects }.min() ?? 0
        let minLength = pages.map { $0.length }.min() ?? 0
        let minOffset = pages.map { $0.contentOffset }.min() ?? 0
        let minContent = pages.map { $0.contentLength }.min() ?? 0
        let bitsObjects = bits((pages.map { $0.objects }.max() ?? 0) - minObjects)
        let bitsLength = bits((pages.map { $0.length }.max() ?? 0) - minLength)
        let bitsOffset = bits((pages.map { $0.contentOffset }.max() ?? 0) - minOffset)
        let bitsContent = bits((pages.map { $0.contentLength }.max() ?? 0) - minContent)
        let bitsCount = bits(pages.map { $0.shared.count }.max() ?? 0)
        let bitsId = bits(pages.map { $0.shared.last ?? 0 }.max() ?? 0)

        var w = BitWriter()
        w.write(minObjects, 32)
        w.write(firstPageAt, 32)
        w.write(bitsObjects, 16)
        w.write(minLength, 32)
        w.write(bitsLength, 16)
        w.write(minOffset, 32)
        w.write(bitsOffset, 16)
        w.write(minContent, 32)
        w.write(bitsContent, 16)
        w.write(bitsCount, 16)
        w.write(bitsId, 16)
        w.write(0, 16)
        w.write(fractionDenominator, 16)
        for p in pages { w.write(p.objects - minObjects, bitsObjects) }
        w.align()
        for p in pages { w.write(p.length - minLength, bitsLength) }
        w.align()
        for p in pages { w.write(p.shared.count, bitsCount) }
        w.align()
        for p in pages {
            for id in p.shared { w.write(id, bitsId) }
        }
        w.align()
        // The numerators take no bits: every fraction is 0.
        for p in pages { w.write(p.contentOffset - minOffset, bitsOffset) }
        w.align()
        for p in pages { w.write(p.contentLength - minContent, bitsContent) }
        w.align()
        let sharedAt = w.length

        let minGroup = groups.min() ?? 0
        let bitsGroup = bits((groups.max() ?? 0) - minGroup)
        w.write(sharedFirst, 32)
        w.write(sharedFirstAt, 32)
        w.write(firstGroups, 32)
        w.write(groups.count, 32)
        w.write(0, 16)
        w.write(minGroup, 32)
        w.write(bitsGroup, 16)
        for g in groups { w.write(g - minGroup, bitsGroup) }
        w.align()
        // No group has a signature, and each is a single object (its count less one takes no bits).
        for _ in groups { w.write(0, 1) }
        w.align()
        let outlineAt = w.length
        if let outline {
            for value in outline { w.write(value, 32) }
        }
        return (w.toArray(), sharedAt, outlineAt)
    }

    private static func bits(_ value: Int) -> Int {
        value <= 0 ? 0 : 64 - value.leadingZeroBitCount
    }
}
