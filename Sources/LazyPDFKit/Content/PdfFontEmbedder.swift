import Foundation

// Twin of windows/LazyPDF.Core/Content/PdfFontEmbedder.cs: adds fonts to a document for drawing new text. A Standard
// 14 font is used when the text fits WinAnsi and no font file is wanted; anything else (Turkish ğ, ş, ı among it) is
// embedded from the file the `FontSource` gives, as a subset Type0 font with Identity-H, /W and /ToUnicode. Each call
// adds a font of its own holding just the characters of its texts, so give it all the text it is to draw.
// `FontSource` is the C# IFontSource and `Shaper` is IShaper.

public struct FontStyles: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let regular: FontStyles = []
    public static let bold = FontStyles(rawValue: 1)
    public static let italic = FontStyles(rawValue: 2)
}

/// Font file bytes and, for a .ttc collection, which font in it.
public struct FontFile {
    public let data: [UInt8]
    public let collectionIndex: Int

    public init(_ data: [UInt8], _ collectionIndex: Int = 0) {
        self.data = data
        self.collectionIndex = collectionIndex
    }
}

/// Where the app finds font files; Core reads none itself.
public protocol FontSource: AnyObject {
    /// The file of the closest font to `family` in `style`, or nil when there is none.
    func find(_ family: String, _ style: FontStyles) -> FontFile?
}

public final class PdfFontEmbedder {
    private static let winAnsiCodes = buildWinAnsi()

    private static let fallbackFamilies = [
        "Arial", "Segoe UI", "Microsoft YaHei", "Yu Gothic", "Malgun Gothic", "Arial Unicode MS", "PingFang SC", "Hiragino Sans", "Apple SD Gothic Neo",
    ]

    private static let hebrewFamilies = ["Segoe UI", "Arial", "Tahoma", "Times New Roman", "Arial Hebrew", "Arial Unicode MS"]
    private static let arabicFamilies = ["Segoe UI", "Tahoma", "Arial", "Times New Roman", "Geeza Pro", "Arial Unicode MS"]

    private let document: PdfDocument
    private let source: FontSource?
    private let shaper: Shaper
    private let builtIn: Bool
    private let language: String?

    /// The texts are shaped with `shaper` (the font source itself when it is a `Shaper` too, else the `CmapShaper`)
    /// and the glyphs it picks are what gets embedded; `language` is passed on to it.
    public init(_ document: PdfDocument, _ source: FontSource? = nil, _ shaper: Shaper? = nil, _ language: String? = nil) {
        self.document = document
        self.source = source
        let given = shaper ?? (source as? Shaper)
        self.shaper = given ?? CmapShaper()
        builtIn = given == nil
        self.language = language
    }

    /// A font that can draw `texts`, or nil when none can: no file from the source, a file that cannot be embedded,
    /// or a font file wanted and no source given. With `embed`, always embed a font file, even for text a Standard
    /// 14 font could draw.
    public func add(_ family: String, _ style: FontStyles, _ texts: [String], embed: Bool = false) throws -> PdfDrawFont? {
        if !embed, let standard = Self.findStandard(family, style), !standard.isSymbolic, texts.allSatisfy(Self.fits) {
            let dictionary = PdfDictionary()
            dictionary["Type"] = PdfName("Font")
            dictionary["Subtype"] = PdfName("Type1")
            dictionary["BaseFont"] = PdfName(standard.name)
            dictionary["Encoding"] = PdfName("WinAnsiEncoding")
            return PdfDrawFont(try document.add(dictionary), standard)
        }
        return try pick(scriptCandidates(family, texts), style, texts)
    }

    /// Like `add`, but for text the family has no glyphs for it tries `fallbackFamilies` and takes the first font that
    /// covers all of it, else the one that misses least. One font draws the whole text. Only the font chosen is added
    /// to the document; check `missing` on it.
    public func addCovering(_ family: String, _ style: FontStyles, _ texts: [String]) throws -> PdfDrawFont? {
        // Text that fits WinAnsi needs no fallback; nil lets the caller's Helvetica retry run.
        if texts.allSatisfy(Self.fits) { return try add(family, style, texts) }
        return try pick(distinct(scriptCandidates(family, texts) + Self.fallbackFamilies), style, texts)
    }

    // The family asked for, then the fonts that carry the Hebrew or Arabic the texts hold.
    private func scriptCandidates(_ family: String, _ texts: [String]) -> [String] {
        var names = [family]
        if Scripts.hasArabic(texts) { names += Self.arabicFamilies }
        if Scripts.hasHebrew(texts) { names += Self.hebrewFamilies }
        return distinct(names)
    }

    private func distinct(_ names: [String]) -> [String] {
        var tried: Set<String> = []
        return names.filter { tried.insert($0.lowercased()).inserted }
    }

    private func pick(_ families: [String], _ style: FontStyles, _ texts: [String]) throws -> PdfDrawFont? {
        var best: (built: EmbeddedFont, measure: TrueTypeFont, lines: LineShaper)?
        for name in families {
            guard let file = source?.find(name, style), let found = embed(file, texts) else { continue }
            if best == nil || found.built.missing.count < best!.built.missing.count { best = found }
            if found.built.missing.isEmpty { break }
        }
        guard let chosen = best else { return nil }
        return PdfDrawFont(try addType0(chosen.built), chosen.built, chosen.measure, chosen.lines, builtIn)
    }

    private func embed(_ file: FontFile, _ texts: [String]) -> (built: EmbeddedFont, measure: TrueTypeFont, lines: LineShaper)? {
        guard let measure = TrueTypeFont.tryParse(file.data, file.collectionIndex) else { return nil }
        let lines = LineShaper(file, shaper, measure, language)
        var unicodeOf: [Int: String] = [:]
        var missing: Set<Int> = []
        for text in texts {
            for paragraph in PdfDrawFont.paragraphs(text) {
                if builtIn && !Scripts.needsBidi(paragraph) {
                    collectPlain(paragraph, measure, &unicodeOf, &missing)
                } else {
                    // The base direction may be set later, which changes which glyphs are mirrored.
                    for level in [BidiParagraph.auto, 0, 1] { collect(lines.shape(paragraph, level), &unicodeOf, &missing) }
                }
            }
        }
        // Glyphs that only ever stood for part of a cluster still need a value for the code to be mapped.
        for (gid, text) in unicodeOf where text.isEmpty { unicodeOf[gid] = "\u{200B}" }
        guard let built = EmbeddedFontBuilder.buildGlyphs(file.data, unicodeOf, missing.sorted(), file.collectionIndex).font else { return nil }
        return (built, measure, lines)
    }

    // Left-to-right text and the built-in shaper: the cmap glyph of each character.
    private func collectPlain(_ paragraph: String, _ measure: TrueTypeFont, _ unicodeOf: inout [Int: String], _ missing: inout Set<Int>) {
        for scalar in paragraph.unicodeScalars {
            let cp = Int(scalar.value)
            if cp < 0x20 || CmapShaper.isInvisible(cp) { continue }
            let gid = measure.glyphForCodePoint(cp)
            if gid <= 0 || gid >= measure.glyphCount { missing.insert(cp) } else { keep(&unicodeOf, gid, String(scalar)) }
        }
    }

    // Where two texts share a glyph the lower one wins, as in the cmap path.
    private func keep(_ unicodeOf: inout [Int: String], _ gid: Int, _ text: String) {
        if let known = unicodeOf[gid], !known.isEmpty, text.isEmpty || !text.utf16.lexicographicallyPrecedes(known.utf16) { return }
        unicodeOf[gid] = text
    }

    private struct Span: Hashable {
        let start: Int
        let end: Int
    }

    // The first glyph of a cluster gets the cluster's text; the others of a one-to-many cluster stand for
    // nothing of their own, and a mirrored glyph depicts the mirror character.
    private func collect(_ line: ShapedLine, _ unicodeOf: inout [Int: String], _ missing: inout Set<Int>) {
        var seen: Set<Span> = []
        for glyph in line.glyphs {
            let stretch = Array(line.units[glyph.start..<glyph.end])
            var text = String(decoding: Utf16Rune.all(stretch).filter { !CmapShaper.isInvisible($0.value) }.flatMap { stretch[$0.at..<($0.at + $0.length)] },
                              as: UTF16.self)
            if glyph.shaped.glyph <= 0 {
                for scalar in text.unicodeScalars { missing.insert(Int(scalar.value)) }
                continue
            }
            if !seen.insert(Span(start: glyph.start, end: glyph.end)).inserted { text = "" }
            else if glyph.mirrored {
                text = String(String.UnicodeScalarView(text.unicodeScalars.map { Unicode.Scalar(UInt32(BidiData.mirror(Int($0.value)))) ?? $0 }))
            }
            keep(&unicodeOf, glyph.shaped.glyph, text)
        }
    }

    private static func findStandard(_ family: String, _ style: FontStyles) -> Standard14? {
        let bold = style.contains(.bold) ? "Bold" : ""
        for italic in style.contains(.italic) ? ["Italic", "Oblique"] : [""] {
            let suffix = bold + italic
            if let found = Standard14.find(suffix.isEmpty ? family : "\(family)-\(suffix)") { return found }
        }
        return nil
    }

    private static func fits(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value < 0x20 || winAnsiCodes[Int($0.value)] != nil }
    }

    private static func buildWinAnsi() -> [Int: Int] {
        var map: [Int: Int] = [:]
        let table = PdfEncodings.winAnsi
        for code in 32..<256 {
            // The unused codes read as bullet in the table and must not claim it.
            if code == 127 || code == 129 || code == 141 || code == 143 || code == 144 || code == 157 { continue }
            if let name = table[code], let first = GlyphList.unicodeOf(name)?.unicodeScalars.first, map[Int(first.value)] == nil {
                map[Int(first.value)] = code
            }
        }
        // Codes 160 and 173 show the space and hyphen glyphs, so the names alone never reach these.
        if map[0xA0] == nil { map[0xA0] = 160 }
        if map[0xAD] == nil { map[0xAD] = 173 }
        return map
    }

    static func winAnsiCode(_ codePoint: Int) -> Int { winAnsiCodes[codePoint] ?? 0x3F }

    private func addType0(_ font: EmbeddedFont) throws -> PdfReference {
        let fontFile = PdfDictionary()
        fontFile["Length1"] = PdfNumber(font.program.count)
        if font.isCff { fontFile["Subtype"] = PdfName("OpenType") }
        let file = try document.add(Self.flate(fontFile, font.program))

        let d = font.descriptor
        let descriptor = PdfDictionary()
        descriptor["Type"] = PdfName("FontDescriptor")
        descriptor["FontName"] = PdfName(font.baseFont)
        descriptor["Flags"] = PdfNumber(d.flags)
        descriptor["FontBBox"] = PdfArray(d.fontBBox.map { PdfNumber($0) })
        descriptor["ItalicAngle"] = PdfNumber(d.italicAngle)
        descriptor["Ascent"] = PdfNumber(d.ascent)
        descriptor["Descent"] = PdfNumber(d.descent)
        descriptor["CapHeight"] = PdfNumber(d.capHeight)
        descriptor["StemV"] = PdfNumber(d.stemV)
        descriptor[font.isCff ? "FontFile3" : "FontFile2"] = file

        var widths: [PdfObject] = []
        for run in font.widths {
            widths.append(PdfNumber(run.firstCid))
            widths.append(PdfArray(run.widths.map { PdfNumber($0) }))
        }
        let info = PdfDictionary()
        info["Registry"] = PdfString(bytes: Array("Adobe".utf8), isHex: false)
        info["Ordering"] = PdfString(bytes: Array("Identity".utf8), isHex: false)
        info["Supplement"] = PdfNumber(0)
        let cid = PdfDictionary()
        cid["Type"] = PdfName("Font")
        cid["Subtype"] = PdfName(font.isCff ? "CIDFontType0" : "CIDFontType2")
        cid["BaseFont"] = PdfName(font.baseFont)
        cid["CIDSystemInfo"] = info
        cid["FontDescriptor"] = try document.add(descriptor)
        cid["DW"] = PdfNumber(font.defaultWidth)
        cid["W"] = PdfArray(widths)
        if !font.isCff { cid["CIDToGIDMap"] = PdfName("Identity") }

        let map = font.unicodeOfCode.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
        let toUnicode = try document.add(Self.flate(PdfDictionary(), try ToUnicodeCMap.write(map)))

        let type0 = PdfDictionary()
        type0["Type"] = PdfName("Font")
        type0["Subtype"] = PdfName("Type0")
        type0["BaseFont"] = PdfName(font.baseFont)
        type0["Encoding"] = PdfName("Identity-H")
        type0["DescendantFonts"] = PdfArray([try document.add(cid)])
        type0["ToUnicode"] = toUnicode
        return try document.add(type0)
    }

    private static func flate(_ dictionary: PdfDictionary, _ data: [UInt8]) -> PdfStream {
        dictionary["Filter"] = PdfName("FlateDecode")
        return PdfStream(dictionary, data: PdfFilterEncoders.flate(data))
    }
}

/// A font added by `PdfFontEmbedder`: its reference for a /Font resource, the encoding of text for `Tj`, and
/// measurements for laying text out.
public final class PdfDrawFont {
    private let standard: Standard14?
    private let embedded: EmbeddedFont?
    private let measure: TrueTypeFont?
    private let lines: LineShaper?
    // The built-in shaper draws it, so text without right-to-left characters needs neither bidi nor shaping.
    private let plain: Bool

    init(_ reference: PdfReference, _ standard: Standard14) {
        self.reference = reference
        self.standard = standard
        embedded = nil
        measure = nil
        lines = nil
        plain = false
        ascent = Double(standard.ascent) / 1000.0
        descent = Double(standard.descent) / 1000.0
    }

    init(_ reference: PdfReference, _ embedded: EmbeddedFont, _ measure: TrueTypeFont, _ lines: LineShaper, _ plain: Bool) {
        self.reference = reference
        standard = nil
        self.embedded = embedded
        self.measure = measure
        self.lines = lines
        self.plain = plain
        ascent = Double(embedded.descriptor.ascent) / 1000.0
        descent = Double(embedded.descriptor.descent) / 1000.0
    }

    /// The font object, to put in a /Font resource.
    public let reference: PdfReference

    public var isEmbedded: Bool { embedded != nil }

    /// Code points of the text the font has no glyph for; they draw as .notdef.
    public var missing: [Int] { embedded?.missing ?? [] }

    /// In em; the descent is negative.
    public let ascent: Double
    public let descent: Double

    public func lineHeight(_ size: Double) -> Double { (ascent - descent) * size * 1.15 }

    /// The string as the bytes a `Tj` shows: one byte a character, or two a glyph for an embedded font. Text with
    /// right-to-left characters comes out in display order, shaped; the line's own first strong character sets the
    /// base direction.
    public func encode(_ text: String) -> [UInt8] {
        if embedded != nil {
            guard let line = shaped(text) else { return encodePlain(text) }
            return line.glyphs.flatMap { codeOf(line, $0) }
        }
        return text.unicodeScalars.filter { $0.value >= 0x20 }.map { UInt8(truncatingIfNeeded: PdfFontEmbedder.winAnsiCode(Int($0.value))) }
    }

    /// The width of the text set in `size` points, kerning not applied.
    public func width(_ text: String, _ size: Double) -> Double {
        if let line = shaped(text) { return line.width * size / 1000 }
        var units = 0.0
        for scalar in text.unicodeScalars where scalar.value >= 0x20 && !(embedded != nil && CmapShaper.isInvisible(Int(scalar.value))) {
            units += advance(Int(scalar.value))
        }
        return units * size / 1000
    }

    // One glyph a character from the cmap. Joiners take no space, as with the shaper.
    private func encodePlain(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf16.count * 2)
        guard let measure, let embedded else { return bytes }
        for scalar in text.unicodeScalars {
            let cp = Int(scalar.value)
            if cp < 0x20 || CmapShaper.isInvisible(cp) { continue }
            let gid = measure.glyphForCodePoint(cp)
            let code = gid < measure.glyphCount ? embedded.glyphCodes[gid] ?? 0 : 0
            bytes.append(UInt8(truncatingIfNeeded: code >> 8))
            bytes.append(UInt8(truncatingIfNeeded: code))
        }
        return bytes
    }

    /// The line shaped and in display order; nil when the font is not embedded or the text is plain and needs no shaping.
    func shaped(_ text: String, _ baseLevel: Int = BidiParagraph.auto) -> ShapedLine? {
        guard let lines, !(plain && baseLevel != 1 && !Scripts.needsBidi(text)) else { return nil }
        return lines.shape(text, baseLevel)
    }

    /// One run in a direction the caller resolved; nil when it is plain and needs no shaping.
    func run(_ text: String, _ rightToLeft: Bool) -> ShapedLine? {
        guard let lines, !(plain && !rightToLeft && !Scripts.needsBidi(text)) else { return nil }
        return lines.shapeRun(text, rightToLeft: rightToLeft)
    }

    func runWidth(_ text: String, _ rightToLeft: Bool, _ size: Double) -> Double {
        if let line = run(text, rightToLeft) { return line.width * size / 1000 }
        return width(text, size)
    }

    /// The width in 1/1000 em that /W gives the code; a shaped advance that differs is made up in the `TJ` adjustments.
    func codeWidth(_ glyph: Int) -> Double {
        guard let measure else { return 0 }
        return (Double(measure.getAdvance(glyph)) * 1000.0 / Double(measure.unitsPerEm)).rounded(.toNearestOrEven)
    }

    /// The character code of a glyph of the shaped text. A mirrored bracket the font was not built with, because the
    /// text had no right-to-left character, is drawn with the glyph the character itself has.
    func codeOf(_ line: ShapedLine, _ glyph: LineGlyph) -> [UInt8] {
        var code = embedded?.glyphCodes[glyph.shaped.glyph] ?? 0
        if code == 0 && glyph.mirrored, let measure, let rune = Utf16Rune.at(line.units, glyph.start) {
            code = embedded?.glyphCodes[measure.glyphForCodePoint(rune.value)] ?? 0
        }
        return [UInt8(truncatingIfNeeded: code >> 8), UInt8(truncatingIfNeeded: code)]
    }

    private func advance(_ codePoint: Int) -> Double {
        if let measure { return Double(measure.getAdvance(measure.glyphForCodePoint(codePoint))) * 1000.0 / Double(measure.unitsPerEm) }
        let code = PdfFontEmbedder.winAnsiCode(codePoint)
        guard let name = PdfEncodings.winAnsi[code] else { return 0 }
        return Double(standard?.widthOf(name) ?? 0)
    }

    /// Breaks the text into lines no wider than `maxWidth`: at spaces, a word wider than the box at the character, and
    /// at every newline. A line keeps no trailing space. Lines are broken on the logical text. When a line would start
    /// in another direction than its paragraph, which is the first strong character's unless `rightToLeft` says, it
    /// gets a direction mark in front so that it is laid out the paragraph's way.
    public func wrap(_ text: String, _ size: Double, _ maxWidth: Double, rightToLeft: Bool? = nil) -> [String] {
        var lines: [String] = []
        for paragraph in Self.paragraphs(text) {
            let first = lines.count
            var line = ""
            for word in paragraph.unicodeScalars.split(separator: " ", omittingEmptySubsequences: false).map({ String(String.UnicodeScalarView($0)) }) {
                let joined = line.isEmpty ? word : line + " " + word
                if width(joined, size) <= maxWidth {
                    line = joined
                    continue
                }
                if !line.isEmpty {
                    lines.append(Self.trimEnd(line))
                    line = ""
                }
                for scalar in word.unicodeScalars {
                    let next = line + String(scalar)
                    if !line.isEmpty && width(next, size) > maxWidth {
                        lines.append(line)
                        line = ""
                    }
                    line.unicodeScalars.append(scalar)
                }
            }
            lines.append(Self.trimEnd(line))
            if isEmbedded && (rightToLeft != nil || Scripts.needsBidi(paragraph)) { direct(&lines, first, rightToLeft ?? isRightToLeft(paragraph)) }
        }
        return lines
    }

    private func direct(_ lines: inout [String], _ first: Int, _ rightToLeft: Bool) {
        for i in first..<lines.count where isRightToLeft(lines[i]) != rightToLeft {
            lines[i] = (rightToLeft ? "\u{200F}" : "\u{200E}") + lines[i]
        }
    }

    /// Whether the first strong character of the text is right to left, which makes it a right-to-left paragraph.
    public func isRightToLeft(_ text: String) -> Bool { Scripts.needsBidi(text) && BidiParagraph(text).level == 1 }

    // string.ReplaceLineEndings("\n").Split('\n'): CR LF, CR, LF, FF, NEL, LS and PS all end a paragraph.
    static func paragraphs(_ text: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 10 && previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = v == 13
            if v == 10 || v == 13 || v == 12 || v == 0x85 || v == 0x2028 || v == 0x2029 {
                result.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        result.append(String(current))
        return result
    }

    private static func trimEnd(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }
}
