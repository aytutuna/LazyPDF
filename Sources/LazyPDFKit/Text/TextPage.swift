import Foundation

// Twin of windows/LazyPDF.Core/Text/TextPage.cs: the text of one page, characters with their places, grouped into
// words, lines and blocks in reading order. Built from the page's content by `ContentInterpreter`; the result never
// changes and can be shared between threads. Coordinates are page user space, as in the content.

public final class TextPage {
    let geometry: PageGeometry
    let lock = NSLock()
    var extentKnown: (top: Double, bottom: Double)?
    private var textKnown: String?

    private init(pageIndex: Int, box: PdfRect, geometry: PageGeometry, chars: [TextChar], words: [TextWord], lines: [PageLine],
                 blocks: [TextBlock], truncated: Bool, annotations: Bool) {
        self.pageIndex = pageIndex
        self.box = box
        self.geometry = geometry
        self.chars = chars
        self.words = words
        self.lines = lines
        self.blocks = blocks
        isTruncated = truncated
        includesAnnotations = annotations
    }

    public let pageIndex: Int

    /// The crop box of the page.
    public let box: PdfRect

    /// The page ran past the interpreter's operation limit or 1,000,000 glyphs; the text stops there.
    public let isTruncated: Bool

    /// Built with `TextPageOptions.includeAnnotations`: some characters belong to appearance streams, and their
    /// operator indexes mean nothing in the page's own content.
    public let includesAnnotations: Bool

    /// For code that edits the content by operator index.
    func requirePageContent() {
        precondition(!includesAnnotations, TextPageText.annotationsIncluded)
    }

    public let chars: [TextChar]
    public let words: [TextWord]
    public let lines: [PageLine]
    public let blocks: [TextBlock]

    /// The whole page as text: lines separated by a line feed, blocks by a blank line, table cells by a tab.
    public var text: String {
        lock.lock()
        defer { lock.unlock() }
        if let known = textKnown { return known }
        let built = getText(TextRange(0, chars.count))
        textKnown = built
        return built
    }

    public static func create(_ document: PdfDocument, _ page: PdfPage, _ options: TextPageOptions? = nil) -> TextPage {
        create(ContentInterpreter(document), page, options)
    }

    /// As above with an interpreter the caller keeps, which saves it parsing fonts again for the next page.
    public static func create(_ interpreter: ContentInterpreter, _ page: PdfPage, _ options: TextPageOptions? = nil) -> TextPage {
        let options = options ?? TextPageOptions()
        let collector = TextCollector(options)
        let walk = interpreter.walkPatterns
        interpreter.walkPatterns = false
        interpreter.run(page, collector)
        var truncated = interpreter.isTruncated
        if options.includeAnnotations {
            for (form, matrix) in PageAppearances.of(interpreter.document, page, shownOnly: true) {
                // Each run starts with a fresh operation budget, so one that ran out ends the walk.
                if truncated || collector.isFull { break }
                interpreter.run(form, collector, matrix)
                truncated = truncated || interpreter.isTruncated
            }
        }
        interpreter.walkPatterns = walk
        truncated = truncated || collector.isFull
        if options.removeDuplicates { collector.removeDuplicates() }
        let geometry = PageGeometry(page)
        let lines = TextFlow(geometry).run(collector.glyphs)
        return assemble(page, geometry, lines, truncated, options.includeAnnotations)
    }

    private static func assemble(_ page: PdfPage, _ geometry: PageGeometry, _ layout: [FlowLine], _ truncated: Bool, _ annotations: Bool) -> TextPage {
        var chars: [TextChar] = []
        var words: [TextWord] = []
        var lines: [PageLine] = []
        var blocks: [TextBlock] = []
        var blockFirst = 0
        for (li, o) in layout.enumerated() {
            let first = chars.count
            for g in o.glyphs {
                chars.append(TextChar(index: chars.count, text: g.text, quad: g.quad, font: g.font, size: g.size, color: g.color, renderMode: g.mode,
                                      operatorIndex: g.op, form: g.form, element: g.element, offset: g.offset, mcid: g.mcid,
                                      isArtifact: g.artifact, isSpace: g.space, isImplied: g.implied, isRtl: (g.level & 1) == 1, line: li))
            }
            addWords(chars, first, li, &words)
            var box = QuadBox()
            var text = ""
            for i in first..<chars.count {
                box.add(chars[i].quad)
                text += chars[i].text
            }
            let quad = box.toQuad()
            lines.append(PageLine(index: li, range: TextRange(first, chars.count), text: text, bounds: quad.bounds, quad: quad, block: blocks.count,
                                  before: o.before, isVertical: o.vertical, isRtl: o.rtl))
            if li + 1 == layout.count || layout[li + 1].block != o.block {
                let range = TextRange(blockFirst, li + 1)
                var bounds = lines[blockFirst].bounds
                for k in (blockFirst + 1)..<(li + 1) { bounds = union(bounds, lines[k].bounds) }
                blocks.append(TextBlock(index: blocks.count, lines: range, bounds: bounds, isTable: o.table))
                blockFirst = li + 1
            }
        }
        return TextPage(pageIndex: page.index, box: page.cropBox, geometry: geometry, chars: chars, words: words, lines: lines, blocks: blocks,
                        truncated: truncated, annotations: annotations)
    }

    private static func addWords(_ chars: [TextChar], _ first: Int, _ line: Int, _ words: inout [TextWord]) {
        var start = -1
        for i in first...chars.count {
            let space = i == chars.count || chars[i].isSpace
            if !space {
                if start < 0 { start = i }
                continue
            }
            if start < 0 { continue }
            var text = ""
            var bounds = chars[start].quad.bounds
            for k in start..<i {
                text += chars[k].text
                chars[k].word = words.count
                bounds = union(bounds, chars[k].quad.bounds)
            }
            words.append(TextWord(index: words.count, range: TextRange(start, i), text: text, bounds: bounds, line: line))
            start = -1
        }
    }

    private static func union(_ a: PdfRect, _ b: PdfRect) -> PdfRect {
        PdfRect(min(a.left, b.left), min(a.bottom, b.bottom), max(a.right, b.right), max(a.top, b.top))
    }

    /// The text of a run of characters. White space at the ends of lines is dropped. With `joinHyphens` a hyphen that
    /// ends a line and follows a letter is taken out and the line is joined to the next one; a hyphen before a capital
    /// stays (a compound name).
    public func getText(_ range: TextRange, joinHyphens: Bool = false) -> String {
        let start = min(max(range.start, 0), chars.count), end = min(max(range.end, start), chars.count)
        var sb: [UInt16] = []
        var pending: [UInt16] = []
        var line = -1
        var atStart = true
        for i in start..<end {
            let c = chars[i]
            if c.line != line {
                pending.removeAll(keepingCapacity: true)
                if line >= 0 && !sb.isEmpty && !c.isSpace {
                    let before = lines[c.line].before
                    if !(joinHyphens && before == .line && Self.tryJoin(&sb, c)) { sb.append(contentsOf: Self.separator(before)) }
                }
                line = c.line
                atStart = true
            }
            if c.isSpace {
                if !atStart { pending.append(contentsOf: c.text.utf16) }
                continue
            }
            if c.text.isEmpty { continue }
            if c.text == "\u{AD}" && i + 1 < end && chars[i + 1].line == line { continue }
            sb.append(contentsOf: pending)
            sb.append(contentsOf: c.text.utf16)
            pending.removeAll(keepingCapacity: true)
            atStart = false
        }
        return String(units: sb)
    }

    private static func separator(_ before: TextBreak) -> [UInt16] {
        switch before {
        case .tab: return [0x09]
        case .line: return [0x0A]
        case .block: return [0x0A, 0x0A]
        case .none: return []
        }
    }

    private static func tryJoin(_ sb: inout [UInt16], _ next: TextChar) -> Bool {
        guard sb.count >= 2, let letter = next.text.utf16.first else { return false }
        let hyphen = sb[sb.count - 1]
        if !(hyphen == 0x2D || hyphen == 0xAD || hyphen == 0x2010 || hyphen == 0x2011) || !sb[sb.count - 2].isLetter || !letter.isLetter { return false }
        if hyphen == 0xAD || letter.isLower { sb.removeLast() }
        return true
    }

    /// The boxes that cover a run of characters, one for each stretch of a line without a break in it, for painting a
    /// selection or a search hit. Spaces at the ends of a stretch are left out.
    public func quads(_ range: TextRange) -> [TextQuad] {
        let start = min(max(range.start, 0), chars.count), end = min(max(range.end, start), chars.count)
        var result: [TextQuad] = []
        var box = QuadBox()
        var pendingFrom = -1
        var previous: TextChar?

        func flush() {
            if !box.isEmpty { result.append(box.toQuad()) }
            box = QuadBox()
            pendingFrom = -1
            previous = nil
        }

        for i in start..<end {
            let c = chars[i]
            if let p = previous {
                let center = c.quad.center
                if c.line != p.line || p.quad.distanceTo(center.x, center.y) > c.size { flush() }
            }
            if c.isSpace {
                if !box.isEmpty && pendingFrom < 0 { pendingFrom = i }
                previous = c
                continue
            }
            if pendingFrom >= 0 {
                for k in pendingFrom..<i { box.add(chars[k].quad) }
                pendingFrom = -1
            }
            box.add(c.quad)
            previous = c
        }
        flush()
        return result
    }

    /// The characters of a word.
    public func wordRange(_ word: Int) -> TextRange { words[word].range }

    public func lineRange(_ line: Int) -> TextRange { lines[line].range }
}
