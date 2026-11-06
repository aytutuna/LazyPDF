import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/TagStats.cs: what is true of the whole document and decides how each page is
// read: the body text size and the lines that repeat as running headers and footers.

final class TagStats {
    private(set) var bodySize = 10.0
    private(set) var bodyBold = false

    /// Band and folded text of lines that repeat on enough pages to be a header or footer.
    private(set) var repeated = Set<String>()

    static func collect(_ document: PdfDocument, _ interpreter: ContentInterpreter) throws -> TagStats {
        let stats = TagStats()
        // In the order the sizes were first met: the C# Dictionary enumerates so, and a tie for the commonest size goes to the first.
        var sizes: [(size: Double, glyphs: Int, bold: Int)] = []
        var sizeAt: [Double: Int] = [:]
        var seen: [String: Int] = [:]
        for page in document.pages {
            try Task.checkCancellation()
            let text = TextPage.create(interpreter, page)
            let geometry = PageGeometry(page)
            var onPage = Set<String>()
            for source in text.lines {
                let line = TagLine(text, source, geometry)
                if line.size > 0 {
                    let length = line.text.utf16.count
                    if let at = sizeAt[line.size] {
                        sizes[at].glyphs += length
                        if line.bold { sizes[at].bold += length }
                    } else {
                        sizeAt[line.size] = sizes.count
                        sizes.append((line.size, length, line.bold ? length : 0))
                    }
                }
                if let band = TagText.band(line, geometry.height), let signature = TagText.signature(line.text) {
                    onPage.insert(band + "|" + signature)
                }
            }
            for key in onPage { seen[key, default: 0] += 1 }
        }

        if var body = sizes.first {
            for candidate in sizes.dropFirst() where candidate.glyphs > body.glyphs { body = candidate }
            stats.bodySize = body.size
            stats.bodyBold = body.bold * 2 > body.glyphs
        }
        let pages = document.pages.count
        let needed = pages < 3 ? 2 : (pages + 1) / 2
        for (key, count) in seen where count >= needed { stats.repeated.insert(key) }
        return stats
    }
}
