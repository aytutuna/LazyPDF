import Foundation

// Twin of windows/LazyPDF.Core/Content/PdfFontEmbedder.cs: adds fonts to a document for drawing new text. A Standard
// 14 font is used when the text fits WinAnsi and no font file is wanted; anything else (Turkish ğ, ş, ı among it) is
// embedded from the file the `FontSource` gives, as a subset Type0 font with Identity-H, /W and /ToUnicode. Each call
// adds a font of its own holding just the characters of its texts, so give it all the text it is to draw.
// `FontSource` is the C# IFontSource.

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

    private let document: PdfDocument
    private let source: FontSource?

    public init(_ document: PdfDocument, _ source: FontSource? = nil) {
        self.document = document
        self.source = source
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
        guard let file = source?.find(family, style) else { return nil }
        guard let built = EmbeddedFontBuilder.build(file.data, texts, file.collectionIndex).font,
              let measure = TrueTypeFont.tryParse(file.data, file.collectionIndex) else { return nil }
        return PdfDrawFont(try addType0(built), built, measure)
    }

    /// Like `add`, but for text the family has no glyphs for it tries `fallbackFamilies` and takes the first font that
    /// covers all of it, else the one that misses least. One font draws the whole text. Only the font chosen is added
    /// to the document; check `missing` on it.
    public func addCovering(_ family: String, _ style: FontStyles, _ texts: [String]) throws -> PdfDrawFont? {
        // Text that fits WinAnsi needs no fallback; nil lets the caller's Helvetica retry run.
        if texts.allSatisfy(Self.fits) { return try add(family, style, texts) }
        var best: (built: EmbeddedFont, measure: TrueTypeFont)?
        var tried: Set<String> = []
        for name in [family] + Self.fallbackFamilies where tried.insert(name.lowercased()).inserted {
            guard let file = source?.find(name, style) else { continue }
            guard let built = EmbeddedFontBuilder.build(file.data, texts, file.collectionIndex).font,
                  let measure = TrueTypeFont.tryParse(file.data, file.collectionIndex) else { continue }
            if best == nil || built.missing.count < best!.built.missing.count { best = (built, measure) }
            if built.missing.isEmpty { break }
        }
        guard let chosen = best else { return nil }
        return PdfDrawFont(try addType0(chosen.built), chosen.built, chosen.measure)
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

        var map: [(key: Int, value: String)] = []
        for (code, codePoint) in font.toUnicode().sorted(by: { $0.key < $1.key }) {
            if let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: codePoint)) { map.append((code, String(scalar))) }
        }
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

    init(_ reference: PdfReference, _ standard: Standard14) {
        self.reference = reference
        self.standard = standard
        embedded = nil
        measure = nil
        ascent = Double(standard.ascent) / 1000.0
        descent = Double(standard.descent) / 1000.0
    }

    init(_ reference: PdfReference, _ embedded: EmbeddedFont, _ measure: TrueTypeFont) {
        self.reference = reference
        standard = nil
        self.embedded = embedded
        self.measure = measure
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

    /// The string as the bytes a `Tj` shows: one byte a character, or two for an embedded font.
    public func encode(_ text: String) -> [UInt8] {
        if let embedded { return embedded.encode(text) }
        return text.unicodeScalars.filter { $0.value >= 0x20 }.map { UInt8(truncatingIfNeeded: PdfFontEmbedder.winAnsiCode(Int($0.value))) }
    }

    /// The width of the text set in `size` points, kerning not applied.
    public func width(_ text: String, _ size: Double) -> Double {
        var units = 0.0
        for scalar in text.unicodeScalars where scalar.value >= 0x20 { units += advance(Int(scalar.value)) }
        return units * size / 1000
    }

    private func advance(_ codePoint: Int) -> Double {
        if let measure { return Double(measure.getAdvance(measure.glyphForCodePoint(codePoint))) * 1000.0 / Double(measure.unitsPerEm) }
        let code = PdfFontEmbedder.winAnsiCode(codePoint)
        guard let name = PdfEncodings.winAnsi[code] else { return 0 }
        return Double(standard?.widthOf(name) ?? 0)
    }

    /// Breaks the text into lines no wider than `maxWidth`: at spaces, a word wider than the box at the character, and
    /// at every newline. A line keeps no trailing space.
    public func wrap(_ text: String, _ size: Double, _ maxWidth: Double) -> [String] {
        var lines: [String] = []
        for paragraph in Self.paragraphs(text) {
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
        }
        return lines
    }

    // string.ReplaceLineEndings("\n").Split('\n'): CR LF, CR, LF, FF, NEL, LS and PS all end a paragraph.
    private static func paragraphs(_ text: String) -> [String] {
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
