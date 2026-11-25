import Foundation

// Twin of windows/LazyPDF.Core/Ocr/OcrLayerContent.cs: the layer's content stream: one text object per line, in render
// mode 3, each word set by its own Tm and Tz so that its glyphs cover its box, and a space glyph filling the gap to the
// next word. The font size is the line's height and the baseline its bottom edge, so a selection covers the line.
// Reading it back goes through the same format.

/// A word of the text layer on the page as shown, in display points (origin top-left). With an angle, x and y+height
/// are where the baseline starts and the box is the upright one before the word is turned about that point.
struct PlacedWord {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let angle: Double

    init(_ text: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double, _ angle: Double = 0) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.angle = angle
    }
}

enum OcrLayerContent {
    static let key = "LazyPDFOcr"
    static let fontName = "LPOcrF"
    private static let minSize = 0.01
    private static let minSpace = 0.1
    private static let minAngle = 1e-6
    // A turn beyond this is not a skew; it also keeps writtenIn's match to one of the four rotations unambiguous.
    private static let maxAngle = Double.pi / 6

    // What the layer of a page can hold: maxWords words, about seven operations for each (a line of one word has the most).
    private static let maxSize = 16 << 20
    private static let maxOperations = 8 * PdfOcrLayer.maxWords

    /// Words in pixels to lines on the page as shown. A line takes the median top and bottom of its words, so its glyphs
    /// share a baseline.
    static func layout(_ words: [OcrWord], _ pixelWidth: Int, _ pixelHeight: Int, _ geometry: PageGeometry) -> [[PlacedWord]] {
        let sx = geometry.width / Double(pixelWidth), sy = geometry.height / Double(pixelHeight)
        let usable = words.prefix(PdfOcrLayer.maxWords)
            .filter { isFinite($0.box) }
            .map { OcrWord(clean($0.text), $0.box, $0.confidence, $0.angle) }
            .filter { !$0.text.isEmpty }
        var lines: [[PlacedWord]] = []
        for line in OcrText.lines(usable) {
            let row = line.words.filter { !$0.text.isEmpty }
            let angle = median(row.map { min(max($0.angle.isFinite ? $0.angle : 0, -maxAngle), maxAngle) })
            if angle != 0 {
                // A skewed line has no common top and bottom: each word keeps its own baseline start and the line its median height.
                let height = median(row.map { $0.box.height }) * sy
                if !(height > minSize) { continue }
                lines.append(row.map { PlacedWord($0.text, $0.box.x * sx, $0.box.bottom * sy - height, $0.box.width * sx, height, angle) })
                continue
            }
            let top = median(row.map { $0.box.y }) * sy, bottom = median(row.map { $0.box.bottom }) * sy
            if !(bottom - top > minSize) { continue }
            lines.append(row.map { PlacedWord($0.text, $0.box.x * sx, top, $0.box.width * sx, bottom - top) })
        }
        return lines
    }

    static func build(_ lines: [[PlacedWord]], _ geometry: PageGeometry, _ userUnit: Double, _ codes: GlyphlessCodes) -> [UInt8] {
        let writer = ContentWriter().save()
        for line in lines {
            guard let first = line.first else { continue }
            let size = first.height / userUnit
            writer.beginText().textRenderMode(3).font(fontName, size)
            for i in 0..<line.count {
                let word = line[i]
                place(writer, geometry, word, codes.bytes(OcrVisualOrder.flip(word.text)), word.width)
                if i + 1 < line.count {
                    let next = line[i + 1]
                    if word.angle == 0 {
                        let gap = nanMax(next.x - (word.x + word.width), minSpace * word.height)
                        let space = PlacedWord(word.text, word.x + word.width, word.y, word.width, word.height)
                        place(writer, geometry, space, codes.bytes(" "), gap)
                    } else {
                        let x = word.x + word.width * cos(word.angle), y = word.y - word.width * sin(word.angle)
                        let dx = next.x - x, dy = next.y + next.height - (y + word.height)
                        let gap = nanMax((dx * dx + dy * dy).squareRoot(), minSpace * word.height)
                        let space = PlacedWord(word.text, x, y, word.width, word.height, word.angle)
                        place(writer, geometry, space, codes.bytes(" "), gap)
                    }
                }
            }
            writer.endText()
        }
        return writer.restore().toArray()
    }

    // Tz stretches the half-em glyphs of the string across the width asked for.
    private static func place(_ writer: ContentWriter, _ geometry: PageGeometry, _ word: PlacedWord, _ encoded: [UInt8], _ width: Double) {
        let (x, y) = geometry.toUser(word.x, word.y + word.height)
        let c = cos(word.angle), s = sin(word.angle)
        let (rx, ry) = geometry.toUser(word.x + c, word.y + word.height - s)
        let (ux, uy) = geometry.toUser(word.x - s, word.y + word.height - c)
        let right = ((rx - x) * (rx - x) + (ry - y) * (ry - y)).squareRoot()
        let up = ((ux - x) * (ux - x) + (uy - y) * (uy - y)).squareRoot()
        let scale = 100 * width / (Double(GlyphlessFont.glyphWidth) / 1000.0 * word.height * Double(encoded.count / 2))
        writer.op("Tz", scale)
            .textMatrix(PdfMatrix((rx - x) / right, (ry - y) / right, (ux - x) / up, (uy - y) / up, x, y))
            .show(encoded)
    }

    /// The geometry the stream was written in: the rotation under which its first text matrix runs along the display's
    /// x axis, give or take a skew. After the page's /Rotate changes, lines and heights are only meaningful in that frame; `current` is
    /// returned when no rotation fits.
    static func writtenIn(_ document: PdfDocument, _ page: PdfPage, _ stream: PdfStream, _ current: PageGeometry) throws -> PageGeometry {
        guard let tm = try operations(document, stream).first(where: { $0.operator == "Tm" && $0.operands.count == 6 }) else {
            return current
        }
        let a = tm.number(0) ?? 1, b = tm.number(1) ?? 0, norm = (a * a + b * b).squareRoot()
        for rotate in [current.rotation, 0, 90, 180, 270] {
            let candidate = PageGeometry(page.cropBox, rotate, page.userUnit)
            let (x0, y0) = candidate.toUser(0, 0)
            let (x1, y1) = candidate.toUser(1, 0)
            let dx = x1 - x0, dy = y1 - y0, length = (dx * dx + dy * dy).squareRoot()
            if (dx * a + dy * b) / (length * norm) > 0.8 { return candidate }
        }
        return current
    }

    /// The lines of a layer stream. Words are in display points; a stream that does not follow the format gives what
    /// could be read.
    static func read(_ document: PdfDocument, _ page: PdfPage, _ stream: PdfStream, _ geometry: PageGeometry) throws -> [[PlacedWord]] {
        var lines: [[PlacedWord]] = []
        var font: PdfFont?
        var size = 0.0, scale = 100.0
        var matrix = PdfMatrix.identity
        var words = 0
        for op in try operations(document, stream) {
            if words >= PdfOcrLayer.maxWords { break }
            switch op.operator {
            case "BT":
                lines.append([])
            case "Tf":
                if op.operands.count == 2, let name = op.operands[0] as? PdfName {
                    font = fontOf(document, page, name.value)
                    size = op.number(1) ?? 0
                }
            case "Tz":
                scale = op.number(0) ?? 100
            case "Tm":
                if op.operands.count == 6 {
                    matrix = PdfMatrix(op.number(0) ?? 1, op.number(1) ?? 0, op.number(2) ?? 0, op.number(3) ?? 1, op.number(4) ?? 0, op.number(5) ?? 0)
                }
            case "Tj":
                guard !lines.isEmpty, op.operands.count == 1, let s = op.operands[0] as? PdfString, s.bytes.count >= 2 else { break }
                if s.bytes.count == 2 && s.bytes[0] == 0 && s.bytes[1] == 0x20 { break }
                let width = Double(GlyphlessFont.glyphWidth) / 1000.0 * size * Double(s.bytes.count / 2) * scale / 100
                let (x1, y1) = (matrix.e, matrix.f)
                let (x2, y2) = (matrix.e + matrix.a * width + matrix.c * size, matrix.f + matrix.b * width + matrix.d * size)
                let text = font?.toText(s.bytes) ?? bigEndianUnicode(s.bytes)
                let (ox, oy) = geometry.toDisplay(x1, y1)
                let (rx, ry) = geometry.toDisplay(x1 + matrix.a * width, y1 + matrix.b * width)
                let angle = atan2(oy - ry, rx - ox)
                if abs(angle) < minAngle {
                    let box = geometry.toDisplay(PdfRect(x1, y1, x2, y2))
                    lines[lines.count - 1].append(PlacedWord(OcrVisualOrder.flip(text), box.x, box.y, box.width, box.height))
                } else {
                    let (ux, uy) = geometry.toDisplay(x1 + matrix.c * size, y1 + matrix.d * size)
                    let height = ((ux - ox) * (ux - ox) + (uy - oy) * (uy - oy)).squareRoot()
                    let wide = ((rx - ox) * (rx - ox) + (ry - oy) * (ry - oy)).squareRoot()
                    lines[lines.count - 1].append(PlacedWord(OcrVisualOrder.flip(text), ox, oy - height, wide, height, angle))
                }
                words += 1
            default:
                break
            }
        }
        lines.removeAll { $0.isEmpty }
        return lines
    }

    // A stream that inflates past the size or holds more operations is a PdfReadException, not a layer.
    private static func operations(_ document: PdfDocument, _ stream: PdfStream) throws -> [ContentOperation] {
        try ContentParser.parse(document.data(stream, maxSize), maxOperations)
    }

    static func fontOf(_ document: PdfDocument, _ page: PdfPage, _ name: String) -> PdfFont? {
        document.dict(document.dict(page.resources, "Font"), name).map { PdfFont.get(document, $0) }
    }

    static func addStream(_ document: PdfDocument, _ content: [UInt8], _ language: String) throws -> PdfReference {
        let marker = PdfDictionary()
        marker["Lang"] = PdfString(bytes: ascii(language), isHex: false)
        let dictionary = PdfDictionary()
        dictionary[key] = marker
        dictionary["Filter"] = PdfName("FlateDecode")
        return try document.add(PdfStream(dictionary, data: PdfFilterEncoders.flate(content)))
    }

    /// The font objects (ISO 32000-1 9.7): Type0 over a CIDFontType2 that has the one empty glyph.
    static func addFont(_ document: PdfDocument, _ codes: GlyphlessCodes) throws -> PdfReference {
        let program = GlyphlessFont.program
        let programDictionary = PdfDictionary()
        programDictionary["Length1"] = PdfNumber(program.count)
        programDictionary["Filter"] = PdfName("FlateDecode")
        let file = try document.add(PdfStream(programDictionary, data: PdfFilterEncoders.flate(program)))

        // The map is already deflated, by hand, in the font class.
        let mapDictionary = PdfDictionary()
        mapDictionary["Filter"] = PdfName("FlateDecode")
        let map = try document.add(PdfStream(mapDictionary, data: GlyphlessFont.cidToGidMap))

        let unicodeDictionary = PdfDictionary()
        unicodeDictionary["Filter"] = PdfName("FlateDecode")
        let toUnicode = try document.add(PdfStream(unicodeDictionary, data: PdfFilterEncoders.flate(ascii(codes.toUnicodeCMap()))))

        // The descent is -1, not the program's 0: PDFKit reads no text from a font whose descriptor and hhea both say 0.
        let descriptor = PdfDictionary()
        descriptor["Type"] = PdfName("FontDescriptor")
        descriptor["FontName"] = PdfName(GlyphlessFont.fontName)
        descriptor["Flags"] = PdfNumber(5)
        descriptor["FontBBox"] = numbers(0, 0, Double(GlyphlessFont.glyphWidth), Double(GlyphlessFont.unitsPerEm))
        descriptor["ItalicAngle"] = PdfNumber(0)
        descriptor["Ascent"] = PdfNumber(GlyphlessFont.unitsPerEm)
        descriptor["Descent"] = PdfNumber(-1)
        descriptor["CapHeight"] = PdfNumber(GlyphlessFont.unitsPerEm)
        descriptor["StemV"] = PdfNumber(80)
        descriptor["FontFile2"] = file

        let system = PdfDictionary()
        system["Registry"] = PdfString(bytes: Array("Adobe".utf8), isHex: false)
        system["Ordering"] = PdfString(bytes: Array("Identity".utf8), isHex: false)
        system["Supplement"] = PdfNumber(0)

        let cidFont = PdfDictionary()
        cidFont["Type"] = PdfName("Font")
        cidFont["Subtype"] = PdfName("CIDFontType2")
        cidFont["BaseFont"] = PdfName(GlyphlessFont.fontName)
        cidFont["CIDSystemInfo"] = system
        cidFont["FontDescriptor"] = try document.add(descriptor)
        cidFont["DW"] = PdfNumber(GlyphlessFont.glyphWidth)
        cidFont["CIDToGIDMap"] = map

        let font = PdfDictionary()
        font["Type"] = PdfName("Font")
        font["Subtype"] = PdfName("Type0")
        font["BaseFont"] = PdfName(GlyphlessFont.fontName)
        font["Encoding"] = PdfName("Identity-H")
        font["DescendantFonts"] = PdfArray([try document.add(cidFont)])
        font["ToUnicode"] = toUnicode
        return try document.add(font)
    }

    /// A Swift string holds no lone surrogate, so the C# step that turns one into U+FFFD has nothing to do here.
    static func clean(_ text: String) -> String {
        OcrText.cleanLine(String(String.UnicodeScalarView(text.unicodeScalars.map { $0 == "\t" ? " " : $0 })))
    }

    // Encoding.ASCII: a character beyond 7 bits is written as '?' and read as U+FFFD.
    static func ascii(_ text: String) -> [UInt8] {
        text.unicodeScalars.map { $0.value < 0x80 ? UInt8(truncatingIfNeeded: $0.value) : 0x3F }
    }

    static func asciiString(_ bytes: [UInt8]) -> String {
        String(String.UnicodeScalarView(bytes.map { $0 < 0x80 ? Unicode.Scalar($0) : "\u{FFFD}" }))
    }

    // Encoding.BigEndianUnicode: an odd last byte and a lone surrogate are read as U+FFFD.
    private static func bigEndianUnicode(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        var i = 0
        while i + 1 < bytes.count {
            units.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
            i += 2
        }
        if i < bytes.count { units.append(0xFFFD) }
        return String(units: units)
    }

    private static func numbers(_ values: Double...) -> PdfArray { PdfArray(values.map { PdfNumber($0) }) }

    private static func isFinite(_ box: OcrBox) -> Bool { box.x.isFinite && box.y.isFinite && box.width.isFinite && box.height.isFinite }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted { compareDoubles($0, $1) < 0 }
        if sorted.isEmpty { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
