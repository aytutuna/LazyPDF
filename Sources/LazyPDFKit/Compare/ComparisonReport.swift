import Foundation

// Twin of windows/LazyPDF.Core/Compare/ComparisonReport.cs: shows a `ComparisonResult`: as a PDF, the new document with a
// highlight on every difference that has a place in it and a summary in front, and as plain text.
//
// A text cut at a length is cut in UTF-16 units, as the C# does; a half of a surrogate pair left at the cut reads as U+FFFD,
// since a Swift String cannot hold one.

public enum ComparisonReport {
    private static let maxMarks = 5000
    private static let maxComment = 500
    static let green = [0.55, 0.85, 0.55]
    static let red = [1.0, 0.55, 0.55]
    static let amber = [1.0, 0.85, 0.35]

    /// A copy of `after` with highlights (green added, red removed, amber changed or moved) whose comments hold the old
    /// text, and the summary pages in front. A removal is marked at the place it was. `after` is not changed; the date is
    /// the one the annotations carry. `fonts` is only needed when a file name or text of the summary has characters
    /// Latin-1 lacks; without it they print as ?.
    public static func write(_ after: PdfDocument, _ result: ComparisonResult, _ oldName: String, _ newName: String,
                             _ fonts: FontSource? = nil, _ date: DateTimeOffset? = nil) throws -> [UInt8] {
        try report(nil, after, result, oldName, newName, fonts, date)
    }

    /// As above, given the old file as well: a removal that has no place in the new page is marked at the same place of the
    /// displayed page, scaled to the new page's size, where the other overload uses its old coordinates unchanged.
    public static func write(_ before: PdfDocument, _ after: PdfDocument, _ result: ComparisonResult, _ oldName: String, _ newName: String,
                             _ fonts: FontSource? = nil, _ date: DateTimeOffset? = nil) throws -> [UInt8] {
        try report(before, after, result, oldName, newName, fonts, date)
    }

    private static func report(_ before: PdfDocument?, _ after: PdfDocument, _ result: ComparisonResult, _ oldName: String, _ newName: String,
                               _ fonts: FontSource?, _ date: DateTimeOffset?) throws -> [UInt8] {
        let copy = try PdfDocument.open(try after.saveRewrite())
        let writer = PdfAnnotationWriter(copy, fonts)
        var marks = 0
        var truncated = false
        for change in result.changes {
            if change.newPage < 0 || change.newPage >= copy.pages.count || change.area == .document { continue }
            if marks >= maxMarks {
                truncated = true
                break
            }
            marks += try mark(writer, copy.pages[change.newPage], change, before, date)
        }
        try SummaryPages.insert(copy, result, oldName, newName, truncated, fonts)
        return try copy.saveRewrite()
    }

    private static func mark(_ writer: PdfAnnotationWriter, _ page: PdfPage, _ change: CompareChange, _ before: PdfDocument?,
                             _ date: DateTimeOffset?) throws -> Int {
        let color: [Double]
        switch change.kind {
        case .added: color = green
        case .removed: color = red
        default: color = amber
        }
        let info = AnnotationInfo(author: "Lazy PDF", contents: comment(change), subject: CompareText.kindName(change.kind), date: date)
        if change.area == .page {
            let box = page.cropBox
            _ = try writer.addNote(page, PdfRect(box.left + 8, box.top - 32, box.left + 32, box.top - 8), info, icon: "Comment", color: color)
            return 1
        }
        // Nothing of the change is on this page (a removal from a page that has no words left): mark where it was.
        let quads = (change.newQuads.isEmpty ? carried(change, page, before) : change.newQuads).map(widen)
        if quads.isEmpty { return 0 }
        _ = try writer.addTextMarkup(page, .highlight, quads, info: info, style: AnnotationStyle(color: color))
        return 1
    }

    private static func carried(_ change: CompareChange, _ page: PdfPage, _ before: PdfDocument?) -> [TextQuad] {
        guard let before, change.oldPage >= 0, change.oldPage < before.pages.count else { return change.oldQuads }
        let from = PageGeometry(before.pages[change.oldPage])
        let to = PageGeometry(page)
        func point(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            let shown = from.toDisplay(x, y)
            return to.toUser(shown.x * to.width / from.width, shown.y * to.height / from.height)
        }
        return change.oldQuads.map { q in
            let p0 = point(q.x0, q.y0), p1 = point(q.x1, q.y1), p2 = point(q.x2, q.y2), p3 = point(q.x3, q.y3)
            return TextQuad(p0.x, p0.y, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y)
        }
    }

    /// A highlight of no width would not show; take it two points each way across the line.
    private static func widen(_ q: TextQuad) -> MarkupQuad {
        let dx = q.x1 - q.x0, dy = q.y1 - q.y0, length = (dx * dx + dy * dy).squareRoot()
        if length >= 1 { return MarkupQuad(q.x3, q.y3, q.x2, q.y2, q.x0, q.y0, q.x1, q.y1) }
        var ux = q.x3 - q.x0, uy = q.y3 - q.y0
        var height = (ux * ux + uy * uy).squareRoot()
        if height < 1e-9 { (ux, uy, height) = (0, 1, 1) }
        let rx = uy / height * 2, ry = -ux / height * 2
        return MarkupQuad(q.x3 - rx, q.y3 - ry, q.x2 + rx, q.y2 + ry, q.x0 - rx, q.y0 - ry, q.x1 + rx, q.y1 + ry)
    }

    private static func comment(_ change: CompareChange) -> String {
        let text: String
        switch (change.area, change.kind) {
        case (.text, .removed), (.text, .changed): text = CompareText.was + change.oldText
        case (.text, .moved): text = change.detail ?? ""
        case (.text, _): text = CompareText.kindName(change.kind)
        default: text = change.detail ?? CompareText.kindName(change.kind)
        }
        return cut(text, maxComment)
    }

    /// The text up to `units` UTF-16 units, one less when that would cut a pair in two, then "..." when there was more.
    private static func cut(_ text: String, _ units: Int) -> String {
        let all = Array(text.utf16)
        if all.count <= units { return text }
        let end = UTF16.isLeadSurrogate(all[units - 1]) ? units - 1 : units
        return String(decoding: all[..<end], as: UTF16.self) + "..."
    }

    /// The result as lines of text: totals, then the differences page by page, then those of the document.
    public static func toText(_ result: ComparisonResult, _ oldName: String, _ newName: String) -> String {
        var sb = CompareText.title + "\n" + oldName + " / " + newName + "\n"
        sb += CompareText.pageCounts(result.oldPageCount, result.newPageCount) + "\n"
        if result.isIdentical { return sb + CompareText.noDifferences + "\n" }
        let s = result.summary
        sb += CompareText.changeCount(s.total) + ": "
        sb += CompareText.kindName(.added) + " \(s.added), "
        sb += CompareText.kindName(.removed) + " \(s.removed), "
        sb += CompareText.kindName(.changed) + " \(s.changed), "
        sb += CompareText.kindName(.moved) + " \(s.moved)\n"

        struct Place: Hashable {
            let newPage: Int
            let oldPage: Int
        }
        var places: [Place] = []
        var groups: [Place: [CompareChange]] = [:]
        for c in result.changes where c.area != .document {
            let place = Place(newPage: c.newPage, oldPage: c.oldPage)
            if groups[place] == nil { places.append(place) }
            groups[place, default: []].append(c)
        }
        for place in places {
            sb += "\n" + pageHeading(place.newPage, place.oldPage) + "\n"
            for c in groups[place] ?? [] { sb += "  " + line(c) + "\n" }
        }
        let document = result.changes.filter { $0.area == .document }
        if !document.isEmpty {
            sb += "\n" + CompareText.areaName(.document) + "\n"
            for c in document { sb += "  " + line(c) + "\n" }
        }
        return sb
    }

    private static func pageHeading(_ newPage: Int, _ oldPage: Int) -> String {
        if newPage < 0 { return "\(CompareText.pages) \(oldPage + 1) (old file)" }
        if oldPage == newPage || oldPage < 0 { return "\(CompareText.pages) \(newPage + 1)" }
        return "\(CompareText.pages) \(newPage + 1) (was \(oldPage + 1))"
    }

    static func line(_ c: CompareChange) -> String {
        let head = "\(CompareText.kindName(c.kind)) \(Ordinal.lower(CompareText.areaName(c.area)))"
        let detail = c.detail.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
        let words: String
        if c.oldText.isEmpty && c.newText.isEmpty {
            words = ""
        } else if c.newText.isEmpty {
            words = ": \(shorten(c.oldText))"
        } else if c.oldText.isEmpty {
            words = ": \(shorten(c.newText))"
        } else if Ordinal.equal(c.oldText, c.newText) {
            words = ": \(shorten(c.newText))"
        } else {
            words = ": \(shorten(c.oldText)) -> \(shorten(c.newText))"
        }
        return head + detail + words
    }

    private static func shorten(_ text: String) -> String { cut(text, 120) }
}
