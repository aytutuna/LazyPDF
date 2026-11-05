import Foundation

// Twin of windows/LazyPDF.Core/Pages/PageRange.cs: from Lazy Print's PageRange.cs, the pages a user types ("1-3, 5, 8-"),
// the same in all three apps.

/// What is wrong with the typed pages, in words for the user.
public struct PageRangeError: Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// The pages typed (0-based, in the order typed, repeats kept), or what is wrong with them.
public struct PageRangeResult: Equatable {
    public let pages: [Int]
    public let error: PageRangeError?

    public init(_ pages: [Int], _ error: PageRangeError?) {
        self.pages = pages
        self.error = error
    }

    public var isSuccess: Bool { error == nil }
}

public enum PageRange {
    /// Parses "1-3, 5, 8-": single pages, ranges and an open range to the last page, separated by commas,
    /// counted from 1. A page past `pageCount` is an error ("Page 9 is past the end (8 pages)").
    public static func parse(_ text: String, _ pageCount: Int) -> PageRangeResult {
        var pages: [Int] = []
        for item in text.unicodeScalars.split(separator: ",", omittingEmptySubsequences: false) {
            let part = trim(Array(item))
            let first: Int, last: Int
            if let dash = part.firstIndex(of: "-") {
                let end = trim(Array(part[(dash + 1)...]))
                guard let low = number(trim(Array(part[..<dash]))) else { return fail(PagesText.rangeUsage) }
                first = low
                if end.isEmpty {
                    last = max(first, pageCount)
                } else {
                    guard let high = number(end), high >= first else { return fail(PagesText.rangeUsage) }
                    last = high
                }
            } else {
                guard let single = number(part) else { return fail(PagesText.rangeUsage) }
                first = single
                last = single
            }
            if last > pageCount {
                let past = first > pageCount ? first : last
                return fail(PagesText.pastTheEnd(past, pageCount))
            }
            for page in first...last { pages.append(page - 1) }
        }
        return PageRangeResult(pages, nil)
    }

    private static func fail(_ message: String) -> PageRangeResult {
        PageRangeResult([], PageRangeError(message))
    }

    private static func trim(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var rest = scalars[...]
        while let first = rest.first, first.properties.isWhitespace { rest.removeFirst() }
        while let last = rest.last, last.properties.isWhitespace { rest.removeLast() }
        return Array(rest)
    }

    private static func number(_ text: [Unicode.Scalar]) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }),
              let value = Int32(String(String.UnicodeScalarView(text))), value >= 1 else { return nil }
        return Int(value)
    }
}
