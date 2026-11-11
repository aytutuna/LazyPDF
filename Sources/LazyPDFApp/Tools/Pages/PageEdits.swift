import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Pages/PageEdits.cs: what the Pages panel does to the document, apart from the controls.
// Each call changes the document in memory; the caller commits.

/// Where new pages go, relative to the selection.
public enum InsertPlace: Int, CaseIterable {
    case afterSelection, beforeSelection, atStart, atEnd
}

/// A paper size for Resize, in points.
public struct PaperSize: Equatable {
    public let name: String
    public let width: Double
    public let height: Double

    public static var all: [PaperSize] {
        [PaperSize(name: "A4", width: 595.276, height: 841.89),
         PaperSize(name: "A3", width: 841.89, height: 1190.551),
         PaperSize(name: "A5", width: 419.528, height: 595.276),
         PaperSize(name: L10n.t("Letter"), width: 612, height: 792),
         PaperSize(name: L10n.t("Legal"), width: 612, height: 1008)]
    }
}

/// The file of a tab as the work off the main actor opens it: its bytes as they stand, with the password or identity the tab
/// was opened with.
public struct TabCopy: @unchecked Sendable {
    let file: [UInt8]
    let password: String?
    let certificate: X509Certificate?

    @MainActor
    public init(_ tab: DocumentTab, _ host: ToolHost) {
        file = tab.session.current
        password = tab.password
        certificate = tab.certificate.flatMap { host.verifyCertificate($0) }
    }

    public func open() throws -> PdfDocument {
        try ToolDocuments.open(file, password: password, certificate: certificate)
    }
}

public enum PageEdits {
    public static let pointsPerMillimetre = 72 / 25.4

    /// A number as typed in a field, in the digits and decimal mark of `locale`; nil when it is not one.
    public static func number(_ text: String, locale: Locale = .current) -> Double? {
        let typed = text.trimmingCharacters(in: .whitespaces)
        // NumberStyles.Float takes no thousands separator: "2,5" in English is refused, not read as 25.
        if let group = locale.groupingSeparator, typed.contains(group) { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        return formatter.number(from: typed)?.doubleValue
    }

    /// A second copy of the file as it stands, for work on another thread.
    @MainActor
    public static func reopen(_ tab: DocumentTab, _ host: ToolHost) throws -> PdfDocument {
        try TabCopy(tab, host).open()
    }

    public static func insertAt(_ place: InsertPlace, _ selection: [Int], _ pageCount: Int) -> Int {
        switch place {
        case .atStart: return 0
        case .atEnd: return pageCount
        default: break
        }
        guard let first = selection.min(), let last = selection.max() else { return pageCount }
        return place == .beforeSelection ? first : last + 1
    }

    /// The size a blank page takes: that of the page next to where it goes.
    public static func neighbourSize(_ document: PdfDocument, _ at: Int) -> (width: Double, height: Double) {
        let page = document.pages[min(max(at - 1, 0), document.pages.count - 1)]
        let geometry = PageGeometry(page)
        return (geometry.width, geometry.height)
    }

    /// Replaces `pages` with `sourcePages` of another file, at the place of the last of them.
    public static func replace(_ target: PdfDocument, _ pages: [Int], _ source: PdfDocument, _ sourcePages: [Int]) throws {
        guard let last = pages.max() else { return }
        try PageOperations.importPages(target, source, sourcePages, last + 1)
        try PageOperations.delete(target, pages)
    }

    /// Where the moved pages stand after `PageOperations.move` put them before page `before`.
    public static func movedTo(_ pages: [Int], _ before: Int) -> [Int] {
        let first = before - pages.filter { $0 < before }.count
        return Array(first..<first + pages.count)
    }

    /// Moves each run of neighbouring pages one place, so pages apart stay apart; a run at the edge stays.
    public static func nudge(_ document: PdfDocument, _ pages: [Int], _ step: Int) throws {
        var runs: [[Int]] = []
        for page in Set(pages).sorted() {
            if let last = runs.last?.last, last + 1 == page {
                runs[runs.count - 1].append(page)
            } else {
                runs.append([page])
            }
        }
        if step > 0 { runs.reverse() }
        let total = document.pages.count
        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            if step < 0 ? first == 0 : last == total - 1 { continue }
            try PageOperations.move(document, run, step < 0 ? first - 1 : last + 2)
        }
    }

    /// Where the pages stand after `nudge`.
    public static func nudged(_ pages: [Int], _ step: Int, _ total: Int) -> [Int] {
        let chosen = Set(pages)
        return pages.sorted().map { page in
            var end = page
            while chosen.contains(end + step) { end += step }
            return end + step < 0 || end + step >= total ? page : page + step
        }
    }

    /// True when `nudge` would move at least one page.
    public static func canNudge(_ pages: [Int], _ step: Int, _ total: Int) -> Bool {
        let chosen = Set(pages)
        return pages.contains { $0 + step >= 0 && $0 + step < total && !chosen.contains($0 + step) }
    }

    /// Where the pages and their copies stand after `PageOperations.duplicate`.
    public static func duplicated(_ pages: [Int]) -> [Int] {
        var found: [Int] = []
        for (i, page) in pages.sorted().enumerated() {
            found.append(page + i)
            found.append(page + i + 1)
        }
        return found
    }

    /// Resizes to the paper size, each page keeping its orientation.
    public static func resizeTo(_ document: PdfDocument, _ pages: [Int], _ width: Double, _ height: Double, _ mode: ResizeMode) throws {
        let shortSide = min(width, height), longSide = max(width, height)
        var portrait: [Int] = []
        var landscape: [Int] = []
        for page in pages {
            let shown = PageGeometry(document.pages[page])
            if shown.width > shown.height { landscape.append(page) } else { portrait.append(page) }
        }
        if !portrait.isEmpty { try PageOperations.resize(document, portrait, shortSide, longSide, mode) }
        if !landscape.isEmpty { try PageOperations.resize(document, landscape, longSide, shortSide, mode) }
    }

    /// Sets the display rectangle (page space of the page it was drawn on) as the crop box of every page, each through its own
    /// geometry.
    public static func crop(_ document: PdfDocument, _ pages: [Int], _ area: DisplayRect) throws {
        for page in pages {
            let box = PageGeometry(document.pages[page]).toUser(area)
            try PageOperations.setBox(document, [page], .crop, box)
        }
    }

    /// The pages the display rectangle (page space of the page it was drawn on) touches, which are the ones a crop can use it on.
    public static func cropTargets(_ document: PdfDocument, _ pages: [Int], _ area: DisplayRect) -> [Int] {
        pages.filter { page in
            let shown = document.pages[page]
            return !PageGeometry(shown).toUser(area).intersect(shown.mediaBox).isEmpty
        }
    }

    /// Numbers pages `first` to `last` as given. The pages after keep the labels they had: a range that started inside is
    /// cut, and the one in force after `last` is started again there.
    public static func relabel(_ document: PdfDocument, _ first: Int, _ last: Int, _ style: PageLabelStyle, _ prefix: String,
                               _ start: Int) throws {
        let old = PdfPageLabels.read(document)
        var ranges = old.filter { $0.startPage < first }
        ranges.append(PageLabelRange(first, style, prefix, start))
        let next = last + 1
        if next < document.pages.count {
            if let inForce = old.filter({ $0.startPage <= next }).max(by: { $0.startPage < $1.startPage }) {
                if inForce.startPage == next {
                    ranges.append(inForce)
                } else {
                    ranges.append(PageLabelRange(next, inForce.style, inForce.prefix, inForce.firstNumber + next - inForce.startPage))
                }
            } else {
                ranges.append(PageLabelRange(next, .decimal, "", next + 1))
            }
            ranges.append(contentsOf: old.filter { $0.startPage > next })
        }
        try PdfPageLabels.write(document, ranges)
    }

    public static func clearLabels(_ document: PdfDocument) throws {
        try PdfPageLabels.write(document, [])
    }

    /// The pages of the selection as a run from the first to the last: labels are ranges, so gaps cannot be left out.
    public static func span(_ selection: [Int]) -> (first: Int, last: Int) {
        (selection.min() ?? 0, selection.max() ?? 0)
    }
}
