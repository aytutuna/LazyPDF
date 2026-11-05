import Foundation

// Twin of windows/LazyPDF.Core/Compare/Comparison.cs: one comparison of two files, pair by pair.

final class Comparison {
    private static let minMoveWords = 4
    private static let maxSlide = 64
    private static let poorText = 10

    let before: PdfDocument
    let after: PdfDocument
    let options: CompareOptions
    let oldReader: PageReader
    let newReader: PageReader

    init(_ before: PdfDocument, _ after: PdfDocument, _ options: CompareOptions) {
        self.before = before
        self.after = after
        self.options = options
        let ids = TokenIds()
        oldReader = PageReader(before, options, ids)
        newReader = PageReader(after, options, ids)
    }

    final class TextHunk {
        let pair: Int
        let range: SequenceDiff.Hunk
        let oldText: String
        let newText: String
        let oldQuads: [TextQuad]
        let newQuads: [TextQuad]
        let key: String

        // The two hunks of a move point at each other.
        weak var partner: TextHunk?

        init(_ pair: Int, _ range: SequenceDiff.Hunk, _ oldData: PageData, _ newData: PageData) {
            self.pair = pair
            self.range = range
            oldText = oldData.words(range.oldStart, range.oldCount)
            newText = newData.words(range.newStart, range.newCount)
            oldQuads = range.oldCount > 0 ? oldData.quads(range.oldStart, range.oldCount) : oldData.anchor(range.oldStart)
            newQuads = range.newCount > 0 ? newData.quads(range.newStart, range.newCount) : newData.anchor(range.newStart)
            let ids = range.oldCount == 0 ? newData.ids[range.newStart..<range.newStart + range.newCount] : oldData.ids[range.oldStart..<range.oldStart + range.oldCount]
            key = ids.map { String($0) }.joined(separator: ",")
        }
    }

    final class PairWork {
        let pair: PagePair
        var hunks: [TextHunk] = []
        var others: [CompareChange] = []

        init(_ pair: PagePair) {
            self.pair = pair
        }
    }

    func run() throws -> ComparisonResult {
        let (oldSignatures, oldPoor) = try signatures(oldReader)
        let (newSignatures, newPoor) = try signatures(newReader)
        let pairs = try PageAligner.align(oldSignatures, newSignatures, oldPoor, newPoor)
        var work: [PairWork] = []
        for p in 0..<pairs.count {
            try Task.checkCancellation()
            let item = PairWork(pairs[p])
            try comparePair(p, item)
            work.append(item)
        }
        Self.findMoves(work)

        var changes: [CompareChange] = []
        var wordsAdded = 0, wordsRemoved = 0
        for item in work {
            for change in item.others where change.area == .page { changes.append(change) }
            for hunk in item.hunks {
                if hunk.partner != nil && hunk.range.newCount == 0 { continue }
                let pair = item.pair
                if let source = hunk.partner {
                    let from = work[source.pair].pair.oldIndex
                    changes.append(CompareChange(.moved, .text, from, pair.newIndex, source.oldText, hunk.newText,
                                                 source.oldQuads, hunk.newQuads, CompareText.movedFrom(from)))
                    continue
                }
                let kind: ChangeKind = hunk.range.oldCount == 0 ? .added : hunk.range.newCount == 0 ? .removed : .changed
                wordsAdded += hunk.range.newCount
                wordsRemoved += hunk.range.oldCount
                changes.append(CompareChange(kind, .text, pair.oldIndex, pair.newIndex, hunk.oldText, hunk.newText, hunk.oldQuads, hunk.newQuads))
            }
            for change in item.others where change.area != .page { changes.append(change) }
        }
        try compareDocuments(pairs, &changes)
        return ComparisonResult(pairs, changes, Self.summarize(changes, wordsAdded, wordsRemoved), before.pages.count, after.pages.count)
    }

    private static func summarize(_ changes: [CompareChange], _ wordsAdded: Int, _ wordsRemoved: Int) -> ComparisonSummary {
        func kind(_ k: ChangeKind) -> Int { changes.filter { $0.kind == k }.count }
        func area(_ a: ChangeArea) -> Int { changes.filter { $0.area == a }.count }
        return ComparisonSummary(kind(.added), kind(.removed), kind(.changed), kind(.moved),
                                 area(.text), area(.format), area(.image), area(.annotation), area(.page), area(.document),
                                 wordsAdded, wordsRemoved)
    }

    /// The shingles of each page; a page with little text also counts its pictures, so that scans and slides can be paired.
    private func signatures(_ reader: PageReader) throws -> (signatures: [[Int]], textPoor: [Bool]) {
        var result: [[Int]] = []
        var poor: [Bool] = []
        for i in 0..<reader.count {
            try Task.checkCancellation()
            let data = reader.load(i)
            var shingles = Set<Int>()
            if data.ids.count == 1 { shingles.insert(data.ids[0]) }
            var k = 0
            while k + 1 < data.ids.count {
                shingles.insert(Self.combine(data.ids[k], data.ids[k + 1]))
                k += 1
            }
            poor.append(data.ids.count < Self.poorText)
            if data.ids.count < Self.poorText {
                for image in try reader.images(data.page) { shingles.insert(Self.hash(image.hash)) }
            }
            result.append(shingles.sorted())
        }
        return (result, poor)
    }

    // The C# hashes with HashCode.Combine and the string comparer, which are seeded for each process, so no result can
    // depend on their values and only their spread matters. These two are fixed.
    private static func combine(_ a: Int, _ b: Int) -> Int {
        var h = UInt64(truncatingIfNeeded: a) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(truncatingIfNeeded: b) &+ 0x7F4A_7C15 &+ (h << 6) &+ (h >> 2)
        return Int(truncatingIfNeeded: h)
    }

    private static func hash(_ text: String) -> Int {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for unit in text.utf16 { h = (h ^ UInt64(unit)) &* 0x100_0000_01B3 }
        return Int(truncatingIfNeeded: h)
    }

    private func comparePair(_ index: Int, _ work: PairWork) throws {
        let pair = work.pair
        if pair.isAdded || pair.isRemoved {
            let page = pair.isAdded ? after.pages[pair.newIndex] : before.pages[pair.oldIndex]
            let box = [Self.boxQuad(page.cropBox)]
            work.others.append(CompareChange(pair.isAdded ? .added : .removed, .page, pair.oldIndex, pair.newIndex, "", "",
                                             pair.isAdded ? [] : box, pair.isAdded ? box : [],
                                             pair.isAdded ? CompareText.pageAdded : CompareText.pageRemoved))
            return
        }

        let oldData = oldReader.load(pair.oldIndex)
        let newData = newReader.load(pair.newIndex)
        if pair.moved {
            work.others.append(CompareChange(.moved, .page, pair.oldIndex, pair.newIndex, "", "",
                                             [Self.boxQuad(oldData.page.cropBox)], [Self.boxQuad(newData.page.cropBox)], CompareText.pageMoved))
        }
        compareSize(work, oldData.page, newData.page)

        var hunks = SequenceDiff.diff(oldData.ids, newData.ids)
        for k in 0..<hunks.count {
            hunks[k] = Self.slide(hunks[k], k > 0 ? hunks[k - 1] : nil, k + 1 < hunks.count ? hunks[k + 1] : nil, oldData, newData)
        }
        for hunk in hunks {
            if options.ignoreWhiteSpace && hunk.oldCount > 0 && hunk.newCount > 0
                && Ordinal.equal(squash(oldData, hunk.oldStart, hunk.oldCount), squash(newData, hunk.newStart, hunk.newCount)) { continue }
            work.hunks.append(TextHunk(index, hunk, oldData, newData))
        }
        compareFormats(work, oldData, newData, hunks)
        try compareImages(work, oldData.page, newData.page)
        compareAnnotations(work, oldData.page, newData.page)
    }

    private func squash(_ data: PageData, _ from: Int, _ count: Int) -> String {
        let joined = (from..<from + count).map(data.word).joined()
        return options.ignoreCase ? Ordinal.lower(joined) : joined
    }

    private func compareSize(_ work: PairWork, _ oldPage: PdfPage, _ newPage: PdfPage) {
        let a = PageGeometry(oldPage)
        let b = PageGeometry(newPage)
        var detail: String?
        if abs(a.width - b.width) > 1 || abs(a.height - b.height) > 1 {
            detail = CompareText.pageSize(a.width, a.height, b.width, b.height)
        } else if oldPage.rotate != newPage.rotate {
            detail = CompareText.pageRotation(oldPage.rotate, newPage.rotate)
        }
        guard let detail else { return }
        work.others.append(CompareChange(.changed, .page, work.pair.oldIndex, work.pair.newIndex, "", "",
                                         [Self.boxQuad(oldPage.cropBox)], [Self.boxQuad(newPage.cropBox)], detail))
    }

    /// A pure insertion or deletion can often be read several ways ("a b" + "a" after "a" is also "a" + "b a"): the block
    /// slides over equal neighbours. Take the reading whose block starts and ends on line boundaries, so that the same
    /// paragraph looks the same at both ends of a move.
    private static func slide(_ hunk: SequenceDiff.Hunk, _ previous: SequenceDiff.Hunk?, _ next: SequenceDiff.Hunk?,
                              _ oldData: PageData, _ newData: PageData) -> SequenceDiff.Hunk {
        let deletion = hunk.newCount == 0, insertion = hunk.oldCount == 0
        if deletion == insertion { return hunk }
        let data = deletion ? oldData : newData
        let ids = data.ids
        let start = deletion ? hunk.oldStart : hunk.newStart, count = deletion ? hunk.oldCount : hunk.newCount

        // The block stays between its neighbours, which it may not overlap.
        var low = 0
        if let p = previous { low = deletion ? p.oldStart + p.oldCount : p.newStart + p.newCount }
        var high = ids.count
        if let n = next { high = deletion ? n.oldStart : n.newStart }
        var left = 0
        while left < maxSlide && start - left > low && ids[start - left - 1] == ids[start - left + count - 1] { left += 1 }
        var right = 0
        while right < maxSlide && start + right + count < high && ids[start + right] == ids[start + right + count] { right += 1 }
        var best = 0
        var bestScore = score(data, start, count)
        for shift in -left...right {
            let value = score(data, start + shift, count)
            if value > bestScore || (value == bestScore && abs(shift) < abs(best)) { (best, bestScore) = (shift, value) }
        }
        var moved = hunk
        moved.oldStart += best
        moved.newStart += best
        return moved
    }

    private static func score(_ data: PageData, _ start: Int, _ count: Int) -> Int {
        let words = data.text.words
        let begins = start == 0 || words[data.kept[start]].line != words[data.kept[start - 1]].line
        let ends = start + count >= data.kept.count || words[data.kept[start + count]].line != words[data.kept[start + count - 1]].line
        return (begins ? 1 : 0) + (ends ? 1 : 0)
    }

    /// A block of at least `minMoveWords` words that one place lost and another gained, word for word, was moved. Blocks
    /// inside a changed stretch are not looked at.
    private static func findMoves(_ work: [PairWork]) {
        var removed: [String: [TextHunk]] = [:]
        for item in work {
            for hunk in item.hunks where hunk.range.newCount == 0 && hunk.range.oldCount >= minMoveWords {
                removed[hunk.key, default: []].append(hunk)
            }
        }
        for item in work {
            for hunk in item.hunks where hunk.range.oldCount == 0 && hunk.range.newCount >= minMoveWords {
                guard var queue = removed[hunk.key], !queue.isEmpty else { continue }
                let source = queue.removeFirst()
                removed[hunk.key] = queue
                hunk.partner = source
                source.partner = hunk
            }
        }
    }

    static func boxQuad(_ r: PdfRect) -> TextQuad { TextQuad(r.left, r.bottom, r.right, r.bottom, r.right, r.top, r.left, r.top) }
}
