import Foundation

// Twin of windows/LazyPDF.Core/Pages/PageLabels.cs, named PageLabelShift because Structure has a PageLabels.swift: page labels
// follow the pages. A range runs from its first page to the next range's, so removing or inserting pages moves the starts.

enum PageLabels {
    /// Renumbers after pages were removed (indexes as they were). A range with no page left is dropped; one that lost its
    /// first pages starts its numbering further on.
    static func removed(_ document: PdfDocument, _ removed: [Int], _ pageCount: Int) throws {
        let ranges = PdfPageLabels.read(document)
        if ranges.isEmpty { return }
        let gone = Set(removed)
        var result: [PageLabelRange] = []
        for (i, range) in ranges.enumerated() {
            let start = range.startPage
            let end = i + 1 < ranges.count ? ranges[i + 1].startPage : pageCount
            var leading = 0
            while start + leading < end && gone.contains(start + leading) { leading += 1 }
            if start + leading >= end { continue }
            let before = gone.reduce(0) { $0 + ($1 < start ? 1 : 0) }
            result.append(PageLabelRange(start - before, range.style, range.prefix, wrapped(range.firstNumber + leading)))
        }
        try PdfPageLabels.write(document, result)
    }

    /// Makes room for `count` pages inserted at `at`; they continue the range before.
    static func inserted(_ document: PdfDocument, _ at: Int, _ count: Int) throws {
        let ranges = PdfPageLabels.read(document)
        if ranges.isEmpty { return }
        try PdfPageLabels.write(document, ranges.map {
            $0.startPage >= at ? PageLabelRange(wrapped($0.startPage + count), $0.style, $0.prefix, $0.firstNumber) : $0
        })
    }
}

// The C# adds in int, which wraps; the label numbers are read back clamped to 1 and int.MaxValue.
private func wrapped(_ value: Int) -> Int { Int(Int32(truncatingIfNeeded: value)) }
