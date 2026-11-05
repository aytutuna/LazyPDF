import Foundation

// Twin of windows/LazyPDF.Core/Compare/SummaryPages.cs: lays out the summary of a comparison on A4 pages and puts them in
// front of a document.

enum SummaryPages {
    private static let width = 595.0, height = 842.0, margin = 50.0
    private static let body = 10.0, head = 16.0
    private static let maxPages = 20

    private struct Line {
        var text: String
        let heading: Bool
        var swatch: [Double]?

        init(_ text: String, _ heading: Bool, _ swatch: [Double]? = nil) {
            self.text = text
            self.heading = heading
            self.swatch = swatch
        }
    }

    static func insert(_ document: PdfDocument, _ result: ComparisonResult, _ oldName: String, _ newName: String, _ truncated: Bool,
                       _ fonts: FontSource?) throws {
        var lines = Self.lines(result, oldName, newName, truncated)
        let embedder = PdfFontEmbedder(document, fonts)
        var regularFont = try embedder.add("Helvetica", .regular, lines.map { $0.text })
        var boldFont = try embedder.add("Helvetica", .bold, lines.map { $0.text })
        if regularFont == nil || boldFont == nil {
            lines = lines.map { Line(latin1($0.text), $0.heading, $0.swatch) }
            regularFont = try embedder.add("Helvetica", .regular, lines.map { $0.text })
            boldFont = try embedder.add("Helvetica", .bold, lines.map { $0.text })
        }
        // The C# takes the font as found and fails on a null: a text Latin-1 holds but WinAnsi lacks (U+0080 to U+009F)
        // with no font source leaves none.
        guard let regular = regularFont, let bold = boldFont else { throw InvalidOperationException(AnnotationText.noFont) }

        lines = lines.flatMap { l -> [Line] in
            let font = l.heading ? bold : regular
            let wrapped = font.wrap(l.text, l.heading ? head : body, width - 2 * margin - 32)
            return wrapped.enumerated().map { Line($0.element, l.heading, $0.offset == 0 ? l.swatch : nil) }
        }

        var pages: [[(line: Line, y: Double)]] = []
        var y = height - margin
        for line in lines {
            let size = line.heading ? head : body
            if pages.isEmpty || y - regular.lineHeight(size) < margin {
                if pages.count == maxPages { break }
                pages.append([])
                y = height - margin
            }
            y -= regular.lineHeight(size)
            pages[pages.count - 1].append((line, y))
        }

        for k in 0..<pages.count {
            try PageOperations.insertBlank(document, k, width, height)
            let page = document.pages[k]
            let resources = ContentResources.forEdit(document, page)
            let regularName = ContentResources.add(document, resources, "Font", regular.reference, "F")
            let boldName = ContentResources.add(document, resources, "Font", bold.reference, "F")
            let writer = ContentWriter()
            for (line, top) in pages[k] {
                let font = line.heading ? bold : regular
                let size = line.heading ? head : body
                var x = margin
                if let c = line.swatch {
                    writer.save().fillRgb(c[0], c[1], c[2]).rect(margin, top - 1, 24, size).fill().restore()
                    x += 32
                }
                writer.beginText().fillGray(0).font(line.heading ? boldName : regularName, size).moveText(x, top)
                    .show(font.encode(line.text)).endText()
            }
            page.dictionary["Contents"] = try document.add(PdfStream(PdfDictionary(), data: writer.toArray()))
        }
    }

    private static func lines(_ result: ComparisonResult, _ oldName: String, _ newName: String, _ truncated: Bool) -> [Line] {
        let s = result.summary
        var lines = [
            Line(CompareText.title, true),
            Line(oldName, false),
            Line(newName, false),
            Line(CompareText.pageCounts(result.oldPageCount, result.newPageCount), false),
            Line("", false),
        ]
        if result.isIdentical {
            lines.append(Line(CompareText.noDifferences, false))
            return lines
        }
        lines.append(Line(CompareText.changeCount(s.total), true))
        lines.append(Line("\(CompareText.kindName(.added)): \(s.added)", false, ComparisonReport.green))
        lines.append(Line("\(CompareText.kindName(.removed)): \(s.removed)", false, ComparisonReport.red))
        lines.append(Line("\(CompareText.kindName(.changed)): \(s.changed)", false, ComparisonReport.amber))
        lines.append(Line("\(CompareText.kindName(.moved)): \(s.moved)", false, ComparisonReport.amber))
        lines.append(Line("", false))
        var areas = "\(CompareText.areaName(.text)) \(s.text), \(CompareText.areaName(.format)) \(s.format), \(CompareText.areaName(.image)) \(s.images), "
        areas += "\(CompareText.areaName(.annotation)) \(s.annotations), \(CompareText.areaName(.page)) \(s.pages), \(CompareText.areaName(.document)) \(s.document)"
        lines.append(Line(areas, false))
        lines.append(Line(CompareText.legend, false))

        let removed = result.pages.filter { $0.isRemoved }
        let others = result.changes.filter { $0.area == .document }
        if !removed.isEmpty || !others.isEmpty { lines.append(Line("", false)) }
        for p in removed { lines.append(Line("\(CompareText.pageRemoved): \(p.oldIndex + 1)", false)) }
        for c in others.prefix(60) { lines.append(Line(ComparisonReport.line(c), false)) }
        if others.count > 60 { lines.append(Line("... \(others.count - 60)", false)) }
        if truncated { lines.append(Line(CompareText.marksCapped, false)) }
        return lines
    }

    // Per UTF-16 unit, as the C# walks the string: a character outside the BMP is two question marks.
    private static func latin1(_ text: String) -> String {
        String(decoding: text.utf16.map { $0 >= 0x20 && $0 <= 0xFF ? $0 : 0x3F }, as: UTF16.self)
    }
}
