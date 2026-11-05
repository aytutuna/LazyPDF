import Foundation

// Twin of windows/LazyPDF.Core/Structure/PageLabels.cs: page labels (ISO 32000-1 12.4.2).

public enum PageLabelStyle {
    case none, decimal, upperRoman, lowerRoman, upperLetters, lowerLetters
}

/// A run of pages numbered alike (ISO 32000-1 12.4.2): from page `startPage` (0-based) to the next range, each labelled
/// `prefix` and a number in `style` counting up from `firstNumber`.
public struct PageLabelRange: Equatable {
    public let startPage: Int
    public let style: PageLabelStyle
    public let prefix: String
    public let firstNumber: Int

    public init(_ startPage: Int, _ style: PageLabelStyle = .decimal, _ prefix: String = "", _ firstNumber: Int = 1) {
        self.startPage = startPage
        self.style = style
        self.prefix = prefix
        self.firstNumber = firstNumber
    }
}

public enum PdfPageLabels {
    private static let maxRanges = 100_000
    private static let romans: [(value: Int, text: String)] =
        [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]

    /// The ranges in page order; empty when the document has none (its pages are then 1, 2, 3...).
    public static func read(_ document: PdfDocument) -> [PageLabelRange] {
        var ranges: [PageLabelRange] = []
        for entry in PdfNumberTree.read(document, document.dict(document.catalog, "PageLabels")) {
            guard entry.key >= 0, entry.key <= Int(Int32.max), let d = document.resolve(entry.value) as? PdfDictionary, ranges.count < maxRanges else { continue }
            let style: PageLabelStyle
            switch document.name(d, "S") {
            case "D": style = .decimal
            case "R": style = .upperRoman
            case "r": style = .lowerRoman
            case "A": style = .upperLetters
            case "a": style = .lowerLetters
            default: style = .none
            }
            let first = document.integer(d, "St") ?? 1
            ranges.append(PageLabelRange(entry.key, style, PdfText.read(document, d, "P") ?? "", Swift.min(Swift.max(first, 1), Int(Int32.max))))
        }
        return ranges
    }

    /// Stores the ranges, sorted by start page. The first must start at page 0 (12.4.2); one for decimal numbers is put
    /// there when it is missing. No ranges removes the labels.
    public static func write(_ document: PdfDocument, _ ranges: [PageLabelRange]) throws {
        var byStart: [Int: PageLabelRange] = [:]
        for r in ranges { byStart[r.startPage] = r }
        var sorted = byStart.values.sorted { $0.startPage < $1.startPage }
        if sorted.isEmpty {
            document.catalog.remove("PageLabels")
            return
        }
        if sorted[0].startPage != 0 { sorted.insert(PageLabelRange(0), at: 0) }
        let entries: [(key: Int, value: PdfObject)] = sorted.map { r in
            let d = PdfDictionary()
            switch r.style {
            case .none: break
            case .decimal: d["S"] = PdfName("D")
            case .upperRoman: d["S"] = PdfName("R")
            case .lowerRoman: d["S"] = PdfName("r")
            case .upperLetters: d["S"] = PdfName("A")
            case .lowerLetters: d["S"] = PdfName("a")
            }
            if !r.prefix.isEmpty { d["P"] = PdfText.toObject(r.prefix) }
            if r.firstNumber != 1 { d["St"] = PdfNumber(r.firstNumber) }
            return (key: r.startPage, value: d as PdfObject)
        }
        let existing = document.dict(document.catalog, "PageLabels")
        let root = try PdfNumberTree.write(document, existing, entries)
        if existing == nil { document.catalog["PageLabels"] = root }
    }

    /// The label of one page: the last range that starts at or before it, plain decimal numbers before the first.
    public static func label(_ ranges: [PageLabelRange], _ pageIndex: Int) -> String {
        var range: PageLabelRange?
        for r in ranges where r.startPage <= pageIndex && (range == nil || r.startPage >= (range?.startPage ?? 0)) {
            range = r
        }
        guard let range else { return String(pageIndex &+ 1) }
        // A start page below zero is a caller's: the sum wraps rather than trapping.
        let number = range.firstNumber &+ (pageIndex &- range.startPage)
        return range.prefix + self.number(number, range.style)
    }

    /// The labels of all the pages.
    public static func labels(_ document: PdfDocument) -> [String] {
        let ranges = read(document)
        return (0..<document.pages.count).map { label(ranges, $0) }
    }

    /// The first page with this label, matched exactly and then ignoring case; nil when none.
    public static func find(_ document: PdfDocument, _ label: String) -> Int? {
        let all = labels(document)
        if let exact = all.firstIndex(where: { $0.unicodeScalars.elementsEqual(label.unicodeScalars) }) { return exact }
        let wanted = upper(label)
        return all.firstIndex { upper($0) == wanted }
    }

    // OrdinalIgnoreCase: each character on its own by its simple upper case. Unicode's full mapping is the simple one
    // wherever it is a single character; the Greek letters with a iota subscript map to one in the simple table but to two
    // in the full one, and .NET keeps dotless i and long s apart from I and S.
    private static func upper(_ text: String) -> [UInt32] {
        text.unicodeScalars.map { scalar in
            let v = scalar.value
            if v == 0x131 || v == 0x17F { return v }
            if v >= 0x1F80 && v <= 0x1FAF { return v & 8 == 0 ? v + 8 : v }
            if v == 0x1FB3 || v == 0x1FC3 || v == 0x1FF3 { return v + 9 }
            let mapped = Array(scalar.properties.uppercaseMapping.unicodeScalars)
            return mapped.count == 1 ? mapped[0].value : v
        }
    }

    private static func number(_ n: Int, _ style: PageLabelStyle) -> String {
        switch style {
        case .none: return ""
        case .upperRoman: return roman(n).uppercased()
        case .lowerRoman: return roman(n)
        case .upperLetters: return letters(n).uppercased()
        case .lowerLetters: return letters(n)
        case .decimal: return String(n)
        }
    }

    private static func roman(_ n: Int) -> String {
        if n < 1 { return String(n) }
        var n = n
        var result = ""
        var length = 0
        for (value, text) in romans {
            // Past 3999 the thousands just repeat; a document does not get there.
            while n >= value && length < 4096 {
                result += text
                length += text.utf8.count
                n -= value
            }
        }
        return result
    }

    // a to z, then aa to zz, then aaa (12.4.2).
    private static func letters(_ n: Int) -> String {
        if n < 1 { return String(n) }
        let letter = Character(Unicode.Scalar(UInt8(97 + (n - 1) % 26)))
        return String(repeating: letter, count: Swift.min((n - 1) / 26 + 1, 4096))
    }
}
