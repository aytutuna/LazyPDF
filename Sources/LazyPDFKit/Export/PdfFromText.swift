import Foundation

// Twin of windows/LazyPDF.Core/Export/PdfFromText.cs: plain text set on pages: wrapped at the margin, a form feed
// starting a new page, tabs as four spaces. The C# ArgumentException is thrown as `ArgumentException` and the
// InvalidOperationException as `InvalidOperationException`: the margin, the size and the font come from the user.

/// A PDF made from text: its bytes, page count and the code points the font had no glyph for.
public struct TextPdf {
    public let bytes: [UInt8]
    public let pages: Int
    public let missing: [Int]

    public init(_ bytes: [UInt8], _ pages: Int, _ missing: [Int]) {
        self.bytes = bytes
        self.pages = pages
        self.missing = missing
    }
}

public enum PdfFromText {
    private static let minSide = 36.0

    /// Text outside Latin-1 (Turkish ğ ş ı included) is drawn with an embedded subset of the family's font from `fonts`;
    /// text a Standard 14 font can draw needs no source. Throws `InvalidOperationException` (the message is
    /// `ExportText.noFont`) when no font can draw the text, and `ArgumentException` when the margin or size leaves no room
    /// on the page, and `CancellationError` when the calling task is cancelled.
    public static func create(_ text: String, fonts: FontSource? = nil, setup: PdfPageSetup? = nil, family: String = "Arial", size: Double = 11) throws -> TextPdf {
        let setup = setup ?? PdfPageSetup()
        let (width, height) = ExportPdf.paper(setup, landscape: setup.orientation == .landscape)
        let box = width - 2 * setup.margin, boxHeight = height - 2 * setup.margin
        if !(setup.margin >= 0) || !(size > 0) || box < minSide || boxHeight < minSide {
            throw ArgumentException("The margin or the size leaves no room on the page.")
        }

        // A form feed would pass for a line ending, so the text is cut at them first.
        var parts = ExportString.split(text, "\u{0C}").map(clean)
        if parts.count > 1, let last = parts.last, last.isEmpty { parts.removeLast() }
        let document = try ExportPdf.newDocument()
        guard let font = try PdfFontEmbedder(document, fonts).add(family, .regular, parts) else {
            throw InvalidOperationException(ExportText.noFont)
        }

        let lineHeight = font.lineHeight(size)
        let perPage = max(1, Int(saturating32: (boxHeight / lineHeight).rounded(.down)))
        var pages: [[String]] = []
        for part in parts {
            let lines = font.wrap(part, size, box)
            var at = 0
            while at < lines.count || at == 0 {
                pages.append(Array(lines[min(at, lines.count)..<min(lines.count, at + perPage)]))
                at += perPage
            }
        }

        try PageOperations.insertBlank(document, 0, width, height, pages.count)
        for i in 0..<pages.count {
            try Task.checkCancellation()
            let page = document.pages[i]
            let name = ContentResources.add(document, ContentResources.forEdit(document, page), "Font", font.reference, "F")
            let content = ContentWriter().beginText().font(name, size).moveText(setup.margin, height - setup.margin - font.ascent * size)
            var first = true
            var at = 0.0
            for line in pages[i] {
                // Right-to-left lines end at the right margin; each move is relative to the start of the line before.
                let x = font.isRightToLeft(line) ? box - font.width(line, size) : 0
                if x != at || !first { _ = content.moveText(x - at, first ? 0 : -lineHeight) }
                at = x
                first = false
                if !line.isEmpty { _ = content.show(font, line, size) }
            }
            _ = content.endText()
            page.dictionary["Contents"] = try document.add(PdfStream(PdfDictionary(), data: content.toArray()))
        }
        return TextPdf(try document.saveRewrite(), pages.count, font.missing)
    }

    // ReplaceLineEndings("\n"), tabs as four spaces, then every control character but the line feed dropped.
    private static func clean(_ part: String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(part.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            i += 1
            switch c.value {
            case 0x0D:
                if i < scalars.count && scalars[i] == "\n" { i += 1 }
                out.append("\n")
            case 0x0A, 0x85, 0x2028, 0x2029: out.append("\n")
            case 0x09: out.append(contentsOf: "    ".unicodeScalars)
            default:
                if c.properties.generalCategory != .control { out.append(c) }
            }
        }
        return String(out)
    }
}
