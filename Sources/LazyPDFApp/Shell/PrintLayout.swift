import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/PrintLayout.cs. The system print panels print the whole file, so the pages the
// layout asks for are made into a file of their own, which is what is printed.

public enum PrintParity: Int, CaseIterable, Sendable {
    case all, odd, even
}

/// What the print flow does to the pages before the system's paper takes them.
public struct PrintLayout: Equatable, Sendable {
    /// 1, 2, 4, 6, 9 or 16.
    public var perSheet = 1
    /// Two pages on each side of a landscape sheet, folded in order; `perSheet` is then ignored.
    public var booklet = false
    /// Odd means sides 1, 3, 5 of the layout, the fronts of a two-sided run; with no layout a side is a page.
    public var parity = PrintParity.all
    public var reverse = false
    /// Bound on the right: n-up fills columns from the right and a booklet swaps the two pages of each side.
    public var rightToLeft = false
    /// Points between pages and from the pages to the sheet edge.
    public var gap = 0.0
    public var border = false
    /// Pages typed like "1-3, 5"; empty for all. It is taken before odd or even, as on Windows.
    public var range = ""

    public static let perSheetChoices = [1, 2, 4, 6, 9, 16]

    /// The widest gap offered, in points (25 mm).
    public static let maxGap = 72.0

    public init(perSheet: Int = 1, booklet: Bool = false, parity: PrintParity = .all, reverse: Bool = false, rightToLeft: Bool = false,
                gap: Double = 0, border: Bool = false, range: String = "") {
        self.perSheet = perSheet
        self.booklet = booklet
        self.parity = parity
        self.reverse = reverse
        self.rightToLeft = rightToLeft
        self.gap = gap
        self.border = border
        self.range = range
    }

    public var isPlain: Bool { perSheet == 1 && !booklet && parity == .all && !reverse && range.isEmpty }

    /// Whether the pages go through `PageOperations.impose`.
    public var imposes: Bool { booklet || perSheet > 1 }

    /// What is wrong with the typed range, or nil when it is empty or fine.
    public func rangeError(count: Int) -> String? {
        range.isEmpty ? nil : PageRange.parse(range, count).error?.message
    }

    /// The pages to print: the typed range or all of them. Without a layout they are cut down to the odd or even ones by
    /// page number and reversed, and -1 stands for the blank that keeps the backs of a manual two-sided run on the right
    /// paper. With a layout the range is returned as it is, since odd, even and reverse then act on the sides.
    public func pages(count: Int) -> [Int] {
        let chosen = range.isEmpty ? Array(0..<count) : PageRange.parse(range, count).pages
        if imposes { return chosen }
        let kept = chosen.filter { keeps($0) }
        return arrange(kept, pad: parity == .even && !kept.isEmpty && chosen.filter { $0 % 2 == 0 }.count > kept.count)
    }

    /// How many sides the layout makes of this many pages.
    public func sideCount(_ pageCount: Int) -> Int {
        pageCount <= 0 ? 0 : booklet ? (pageCount + 3) / 4 * 2 : (pageCount + perSheet - 1) / perSheet
    }

    /// The zero-based sides to print, in order; -1 is a blank page. Empty when nothing is left.
    public func sheetsToPrint(_ sideCount: Int) -> [Int] {
        let kept = (0..<max(sideCount, 0)).filter { keeps($0) }
        return arrange(kept, pad: parity == .even && !kept.isEmpty && sideCount % 2 == 1)
    }

    /// Whether nothing is left to print of a file of this many pages.
    public func isEmpty(count: Int) -> Bool {
        imposes ? sheetsToPrint(sideCount(pages(count: count).count)).isEmpty : pages(count: count).isEmpty
    }

    private func keeps(_ index: Int) -> Bool {
        switch parity {
        case .all: return true
        case .odd: return index % 2 == 0
        case .even: return index % 2 == 1
        }
    }

    // The unpaired last front has no back: the blank ends the even run, or starts it when it is fed in reverse.
    private func arrange(_ kept: [Int], pad: Bool) -> [Int] {
        var list = reverse ? Array(kept.reversed()) : kept
        if pad { list.insert(-1, at: reverse ? 0 : list.count) }
        return list
    }

    public func options(sheetWidth: Double, sheetHeight: Double) -> ImposeOptions {
        ImposeOptions(mode: booklet ? .booklet : .nUp, sheetWidth: sheetWidth, sheetHeight: sheetHeight, perSheet: perSheet,
                      gap: gap, border: border, rightToLeft: rightToLeft)
    }

    /// A message when the gap leaves no room for the pages on a sheet of this size in points, else nil.
    public func validate(sheetWidth: Double, sheetHeight: Double) -> String? {
        guard imposes else { return nil }
        let grids: [Int: (Double, Double)] = [2: (2, 1), 4: (2, 2), 6: (3, 2), 9: (3, 3)]
        let (columns, rows) = booklet ? (2.0, 1.0) : grids[perSheet] ?? (4, 4)
        let width = booklet ? max(sheetWidth, sheetHeight) : sheetWidth
        let height = booklet ? min(sheetWidth, sheetHeight) : sheetHeight
        return width - gap * (columns + 1) > 0 && height - gap * (rows + 1) > 0 ? nil
            : L10n.t("The gap leaves no room for the pages on this paper.")
    }

    /// The layout choices kept between prints: not the sides, the order or the binding, which a person picks for each job.
    public static func remembered(_ preferences: AppPreferences) -> PrintLayout {
        PrintLayout(perSheet: perSheetChoices.contains(preferences.printPerSheet) ? preferences.printPerSheet : 1,
                    booklet: preferences.printBooklet, gap: min(max(preferences.printGap, 0), maxGap), border: preferences.printBorder)
    }

    public func remember(in preferences: inout AppPreferences) {
        preferences.printPerSheet = perSheet
        preferences.printBooklet = booklet
        if imposes { preferences.printGap = gap } // a plain job has no gap to offer, so it must not wipe the kept one
        preferences.printBorder = border
    }

    /// The file to print, saved: the sides of a layout that imposes, else the pages that are left. Blanks are real pages.
    public func file(_ source: PdfDocument, sheetWidth: Double, sheetHeight: Double) throws -> PrintSheets {
        let chosen = pages(count: source.pages.count)
        if imposes {
            let result = try PageOperations.impose(source, chosen, options(sheetWidth: sheetWidth, sheetHeight: sheetHeight))
            let sides = sheetsToPrint(result.sheets)
            if sides.isEmpty { throw PdfReadException.damaged("There are no sides to print.") }
            if sides != Array(0..<result.sheets) {
                try PageOperations.keepPages(result.document, sides, blankWidth: sheetWidth, blankHeight: sheetHeight)
            }
            return PrintSheets(bytes: try result.document.saveRewrite(), count: sides.count, dropped: result.annotationsDropped)
        }
        let real = chosen.filter { $0 >= 0 }
        if real.isEmpty { throw PdfReadException.damaged("There are no pages to print.") }
        let part = try PageAssembly.extract(source, real, files: false)
        if real.count != chosen.count {
            // The blank is as big as the page it sits beside.
            let beside = part.pages[chosen.first == -1 ? 0 : real.count - 1]
            let box = beside.cropBox
            let sideways = beside.rotate % 180 != 0
            var next = 0
            var order: [Int] = []
            for page in chosen {
                order.append(page < 0 ? -1 : next)
                if page >= 0 { next += 1 }
            }
            try PageOperations.keepPages(part, order, blankWidth: (sideways ? box.height : box.width) * beside.userUnit,
                                         blankHeight: (sideways ? box.width : box.height) * beside.userUnit)
        }
        return PrintSheets(bytes: try part.saveRewrite(), count: chosen.count, dropped: 0)
    }

    /// `file` off the calling thread. A cancel of `token` ends the wait with `CancellationError` at once; the engine
    /// cannot be stopped half way, so the job runs on and its result is dropped.
    public func fileInBackground(_ source: PdfDocument, sheetWidth: Double, sheetHeight: Double, token: CancelToken) async throws -> PrintSheets {
        try token.throwIfCancelled()
        let layout = self
        let first = FirstResult()
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                let result = Result { try layout.file(source, sheetWidth: sheetWidth, sheetHeight: sheetHeight) }
                if first.claim() { continuation.resume(with: result) }
            }
            Task.detached {
                while !token.isCancelled && !first.isClaimed { try? await Task.sleep(nanoseconds: 50_000_000) }
                if token.isCancelled && first.claim() { continuation.resume(throwing: CancellationError()) }
            }
        }
    }

    /// The note for the annotations a layout could not place, or nil when none was left out.
    public static func droppedNote(_ dropped: Int) -> String? {
        dropped == 0 ? nil : L10n.plural(dropped, one: "{0} link or note without a picture was left off the sheets.",
                                         other: "{0} links and notes without a picture were left off the sheets.")
    }
}

private final class FirstResult: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    var isClaimed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimed
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// `dropped` counts the annotations that could not be placed on the sheets.
public struct PrintSheets: Sendable {
    public let bytes: [UInt8]
    public let count: Int
    public let dropped: Int
}
