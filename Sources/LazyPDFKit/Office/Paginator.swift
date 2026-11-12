import Foundation

// Twin of windows/LazyPDF.Core/Office/Layout/Paginator.cs: sets a LayoutDocument on pages. Sections and page breaks
// start pages; a paragraph breaks across pages with widow and orphan control; keep-with-next moves a chain of
// paragraphs together; space before is dropped at the top of a page that a full page ended. Header and footer bands
// are laid out last, when the page count is known. Cancellation is checked where the C# twin checks its token.

final class Paginator {
    static let maxPages = 10_000
    static let tolerance = 0.01
    private static let minArea = 36.0

    final class Page {
        let section: LayoutSection
        let top: Double
        let bottom: Double
        let hard: Bool
        let variant: PageVariant
        var y: Double
        var hasContent = false
        var boxes: [LayoutBox] = []

        init(_ section: LayoutSection, _ variant: PageVariant, _ top: Double, _ bottom: Double, _ hard: Bool) {
            self.section = section
            self.top = top
            self.bottom = bottom
            self.hard = hard
            self.variant = variant
            y = top
        }
    }

    private enum Measured {
        case paragraph(ParagraphLines)
        case table(TableLines)
        case pageBreak
    }

    private let document: LayoutDocument
    private let fonts: LayoutFonts
    var pages: [Page] = []
    private var rightToLeft = 0, complex = 0
    // The body area of each kind of page of the section being laid out, and how many pages it has so far.
    private var areas = [(top: Double, bottom: Double)](repeating: (0, 0), count: 3)
    private var sectionPages = 0

    init(_ document: LayoutDocument, _ fonts: LayoutFonts) {
        self.document = document
        self.fonts = fonts
    }

    func run() throws -> LayoutResult {
        if document.sections.isEmpty { throw ArgumentException("The document has no section.") }
        for section in document.sections { try layOut(section) }

        var result: [LayoutPage] = []
        for i in 0..<pages.count {
            try Task.checkCancellation()
            let page = pages[i]
            let geometry = page.section.page
            var boxes: [LayoutBox] = []
            let number = String(i + 1), total = String(pages.count)
            let pick: (LayoutField) -> String = { $0 == .pageNumber ? number : total }
            let header = try band(page.section.headerOf(page.variant), geometry, pick)
            let footer = try band(page.section.footerOf(page.variant), geometry, pick)
            Self.emit(&boxes, header.paragraphs, geometry, geometry.headerDistance)
            Self.emit(&boxes, footer.paragraphs, geometry, geometry.height - geometry.footerDistance - footer.height)
            boxes.append(contentsOf: page.boxes)
            result.append(LayoutPage(width: geometry.width, height: geometry.height, boxes: boxes))
        }
        return LayoutResult(pages: result, skipped: skipped(), missing: fonts.missing.sorted())
    }

    private func skipped() -> [SkippedFeature] {
        var all: [SkippedFeature] = []
        func add(_ kind: String, _ count: Int) {
            if count <= 0 { return }
            if let at = all.firstIndex(where: { $0.kind == kind }) { all[at].count += count } else { all.append(SkippedFeature(kind, count)) }
        }
        for s in document.skipped { add(s.kind, s.count) }
        add(SkippedKinds.rightToLeftText, rightToLeft)
        add(SkippedKinds.complexScript, complex)
        return all
    }

    private func band(_ source: [LayoutParagraph], _ geometry: LayoutGeometry, _ field: @escaping (LayoutField) -> String, count: Bool = false) throws -> (paragraphs: [ParagraphLines], height: Double) {
        let width = geometry.width - geometry.left - geometry.right
        var height = 0.0
        var paragraphs: [ParagraphLines] = []
        for paragraph in source {
            let lines = try ParagraphLayout.run(paragraph, fonts, width, geometry.height - geometry.top - geometry.bottom, field)
            if count { tally(lines) }
            paragraphs.append(lines)
            height += paragraph.before + lines.height + paragraph.after
        }
        return (paragraphs, height)
    }

    private func tally(_ lines: ParagraphLines) {
        if lines.rightToLeft { rightToLeft += 1 }
        if lines.complexScript { complex += 1 }
    }

    private func layOut(_ section: LayoutSection) throws {
        let g = section.page
        if !(g.width >= 72 && g.width <= 14400) || !(g.height >= 72 && g.height <= 14400) || !(g.top >= 0) || !(g.bottom >= 0) || !(g.left >= 0) || !(g.right >= 0)
            || g.width - g.left - g.right < Self.minArea || g.height - g.top - g.bottom < Self.minArea {
            throw PdfReadException(.unsupported, "The page size or margins leave no room for text.")
        }
        let width = g.width - g.left - g.right
        // A band shared by several kinds of page is counted once.
        var counted: [ObjectIdentifier] = []
        func firstTime(_ source: [LayoutParagraph]) -> Bool {
            guard let head = source.first else { return false }
            if counted.contains(ObjectIdentifier(head)) { return false }
            counted.append(ObjectIdentifier(head))
            return true
        }
        for v in 0..<3 {
            let variant = PageVariant(rawValue: v)!
            let used = variant == .standard || (variant == .first ? section.titlePage : section.evenAndOdd)
            let header = section.headerOf(variant)
            let footer = section.footerOf(variant)
            let headerHeight = try band(header, g, { _ in "1" }, count: used && firstTime(header)).height
            let footerHeight = try band(footer, g, { _ in "1" }, count: used && firstTime(footer)).height
            var top = headerHeight > 0 ? max(g.top, g.headerDistance + headerHeight) : g.top
            var bottom = footerHeight > 0 ? min(g.height - g.bottom, g.height - g.footerDistance - footerHeight) : g.height - g.bottom
            // A band that would leave no body gives way to the margins.
            if bottom - top < Self.minArea { (top, bottom) = (g.top, g.height - g.bottom) }
            areas[v] = (top, bottom)
        }
        sectionPages = 0

        let body = areas[0].bottom - areas[0].top
        var blocks: [Measured] = []
        for block in section.blocks {
            try Task.checkCancellation()
            if let paragraph = block as? LayoutParagraph {
                let lines = try ParagraphLayout.run(paragraph, fonts, width, body)
                tally(lines)
                blocks.append(.paragraph(lines))
            } else if let table = block as? LayoutTable {
                blocks.append(.table(try TableLayout.measure(table, fonts, width, body, { tally($0) })))
            } else {
                blocks.append(.pageBreak)
            }
        }

        try newPage(section, hard: true)
        for i in 0..<blocks.count {
            try Task.checkCancellation()
            switch blocks[i] {
            case .paragraph(let lines): try place(blocks, i, lines, section)
            case .table(let table): try placeTable(table, section)
            case .pageBreak: try newPage(section, hard: true)
            }
        }
    }

    func newPage(_ section: LayoutSection, hard: Bool) throws {
        if pages.count >= Self.maxPages { throw PdfReadException(.unsupported, "The document has too many pages.") }
        // The first page of a section and the even pages count by the page's place in the document.
        let variant: PageVariant = section.titlePage && sectionPages == 0 ? .first
            : section.evenAndOdd && (pages.count + 1) % 2 == 0 ? .even : .standard
        sectionPages += 1
        let area = areas[variant.rawValue]
        pages.append(Page(section, variant, area.top, area.bottom, hard))
    }

    private func place(_ blocks: [Measured], _ index: Int, _ lines: ParagraphLines, _ section: LayoutSection) throws {
        let paragraph = lines.source
        if paragraph.pageBreakBefore && pages[pages.count - 1].hasContent { try newPage(section, hard: true) }
        if paragraph.keepWithNext { try keepTogether(blocks, index, section) }

        var placed = 0
        let count = lines.lines.count
        while placed < count {
            let page = pages[pages.count - 1]
            let before = placed == 0 && (page.hasContent || page.hard) ? paragraph.before : 0
            let room = page.bottom - page.y - before + Self.tolerance
            var fit = 0
            var used = 0.0
            while placed + fit < count && used + lines.lines[placed + fit].height <= room {
                used += lines.lines[placed + fit].height
                fit += 1
            }

            var take = fit
            if placed + fit < count {
                if paragraph.widowControl {
                    if count - placed - take == 1 && take > 1 { take -= 1 }
                    if placed == 0 && take == 1 && page.hasContent { take = 0 }
                }
                if take == 0 && !page.hasContent { take = 1 }
                if take == 0 {
                    try newPage(section, hard: false)
                    continue
                }
            } else {
                take = count - placed
            }

            page.y += before
            for k in placed..<(placed + take) {
                Self.emitLine(&page.boxes, lines.lines[k], section.page.left, page.y)
                page.y += lines.lines[k].height
            }
            page.hasContent = true
            placed += take
            if placed < count { try newPage(section, hard: false) }
        }
        pages[pages.count - 1].y += paragraph.after
    }

    // A chain of keep-with-next paragraphs and the first lines of the one after it move to a fresh page when
    // they would not fit in what is left of this one, if they fit on a page of their own.
    private func keepTogether(_ blocks: [Measured], _ index: Int, _ section: LayoutSection) throws {
        let page = pages[pages.count - 1]
        if !page.hasContent { return }
        var need = 0.0
        var k = index
        while k < blocks.count, case .paragraph(let member) = blocks[k], member.source.keepWithNext {
            need += member.source.before + member.height + member.source.after
            k += 1
        }
        if k < blocks.count, case .paragraph(let next) = blocks[k] {
            let lead = min(next.lines.count, next.source.widowControl ? 2 : 1)
            var leadHeight = 0.0
            for line in next.lines.prefix(lead) { leadHeight += line.height }
            need += next.source.before + leadHeight
        } else if k < blocks.count, case .table(let table) = blocks[k], !table.rows.isEmpty {
            need += table.rows[0].height
        }
        if need > page.bottom - page.y + Self.tolerance && need <= page.bottom - page.top { try newPage(section, hard: false) }
    }

    private static func emit(_ boxes: inout [LayoutBox], _ paragraphs: [ParagraphLines], _ geometry: LayoutGeometry, _ top: Double) {
        var y = top
        for paragraph in paragraphs {
            y += paragraph.source.before
            for line in paragraph.lines {
                emitLine(&boxes, line, geometry.left, y)
                y += line.height
            }
            y += paragraph.source.after
        }
    }

    // Highlights go under the text and underlines and strikes over it. A piece is a stretch of one style;
    // tabs, line breaks and the spaces that end the line draw nothing and split the pieces.
    static func emitLine(_ boxes: inout [LayoutBox], _ line: LayoutLine, _ originX: Double, _ top: Double) {
        guard let ink = line.atoms.lastIndex(where: { !$0.isBlank || $0.isTab }) else { return }
        var highlights: [LayoutBox] = []
        var texts: [LayoutBox] = []
        var over: [LayoutBox] = []
        var pictures: [LayoutBox] = []
        let baseline = top + line.baseline
        var from = 0
        while from <= ink {
            let first = line.atoms[from]
            if let picture = first.picture {
                var y = baseline - first.pictureHeight - first.run.shift
                var height = first.pictureHeight
                var source = picture
                // Under exact spacing the picture can reach above the line; Word cuts it off at the line top.
                if y < top {
                    let cut = top - y
                    height -= cut
                    let visible = 1 - picture.cropTop - picture.cropBottom
                    source = LayoutPicture(picture.file, picture.width, picture.height, cropLeft: picture.cropLeft,
                                           cropTop: picture.cropTop + visible * cut / first.pictureHeight,
                                           cropRight: picture.cropRight, cropBottom: picture.cropBottom)
                    y = top
                }
                if height > 0.01 {
                    pictures.append(.image(PlacedImage(x: originX + first.x, y: y, width: first.width, height: height, source: source)))
                }
                from += 1
                continue
            }
            if first.isTab || first.isNewline || first.isZeroWidth {
                from += 1
                continue
            }
            var to = from
            while to + 1 <= ink && sameStyle(first, line.atoms[to + 1]) { to += 1 }
            let last = line.atoms[to]
            var text = String.UnicodeScalarView()
            var extra = 0.0
            for k in from...to {
                text.append(Unicode.Scalar(UInt32(line.atoms[k].code))!)
                if line.atoms[k].extra > 0 { extra = line.atoms[k].extra }
            }
            let run = first.run
            let x = originX + first.x, width = last.x + last.width + last.extra - first.x
            let shift = run.shift, size = first.size, bar = size * 0.05
            if let highlight = run.highlight {
                highlights.append(.rect(PlacedRect(x: x, y: baseline - shift - first.runFace.ascent * size, width: width,
                                                   height: (first.runFace.ascent + first.runFace.descent) * size, color: highlight)))
            }
            texts.append(.text(PlacedText(x: x, baseline: baseline - shift, text: String(text), family: first.face.family, style: first.face.style,
                                          size: size, color: run.color, spaceExtra: extra)))
            if run.underline { over.append(.rect(PlacedRect(x: x, y: baseline - shift + size * 0.1, width: width, height: bar, color: run.color))) }
            if run.strike { over.append(.rect(PlacedRect(x: x, y: baseline - shift - size * 0.3, width: width, height: bar, color: run.color))) }
            from = to + 1
        }
        boxes.append(contentsOf: highlights)
        boxes.append(contentsOf: pictures)
        boxes.append(contentsOf: texts)
        boxes.append(contentsOf: over)
    }

    private static func sameStyle(_ a: Atom, _ b: Atom) -> Bool {
        !b.isTab && !b.isNewline && !b.isZeroWidth && b.picture == nil && a.face === b.face && a.size == b.size && a.run.color == b.run.color
            && a.run.underline == b.run.underline && a.run.strike == b.run.strike && a.run.highlight == b.run.highlight && a.run.shift == b.run.shift
    }
}
