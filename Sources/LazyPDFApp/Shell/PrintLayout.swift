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
    public var parity = PrintParity.all
    /// Pages typed like "1-3, 5"; empty for all. It is taken before odd or even, as on Windows.
    public var range = ""

    public static let perSheetChoices = [1, 2, 4, 6, 9, 16]

    public init(perSheet: Int = 1, booklet: Bool = false, parity: PrintParity = .all, range: String = "") {
        self.perSheet = perSheet
        self.booklet = booklet
        self.parity = parity
        self.range = range
    }

    public var isPlain: Bool { perSheet == 1 && !booklet && parity == .all && range.isEmpty }

    /// Whether the pages go through `PageOperations.impose`.
    public var imposes: Bool { booklet || perSheet > 1 }

    /// What is wrong with the typed range, or nil when it is empty or fine.
    public func rangeError(count: Int) -> String? {
        range.isEmpty ? nil : PageRange.parse(range, count).error?.message
    }

    /// The pages to print: the typed range or all of them, cut down to the odd or even ones by page number.
    public func pages(count: Int) -> [Int] {
        let chosen = range.isEmpty ? Array(0..<count) : PageRange.parse(range, count).pages
        return chosen.filter { i in
            switch parity {
            case .all: return true
            case .odd: return i % 2 == 0
            case .even: return i % 2 == 1
            }
        }
    }

    public func options(sheetWidth: Double, sheetHeight: Double) -> ImposeOptions {
        ImposeOptions(mode: booklet ? .booklet : .nUp, sheetWidth: sheetWidth, sheetHeight: sheetHeight, perSheet: perSheet)
    }

    /// The file to print, saved: the sheets for a layout that imposes, else the pages that are left.
    public func file(_ source: PdfDocument, sheetWidth: Double, sheetHeight: Double) throws -> PrintSheets {
        let pages = pages(count: source.pages.count)
        if imposes {
            let result = try PageOperations.impose(source, pages, options(sheetWidth: sheetWidth, sheetHeight: sheetHeight))
            return PrintSheets(bytes: try result.document.saveRewrite(), count: result.sheets, dropped: result.annotationsDropped)
        }
        let part = try PageAssembly.extract(source, pages, files: false)
        return PrintSheets(bytes: try part.saveRewrite(), count: pages.count, dropped: 0)
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
