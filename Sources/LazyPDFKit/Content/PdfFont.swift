import Foundation

// Twin of windows/LazyPDF.Core/Content/PdfFont.cs: a font dictionary understood (ISO 32000-1 9): Type1, MMType1,
// TrueType, Type3 and Type0 over CIDFontType0 and CIDFontType2. It turns the bytes of a shown string into
// characters with a width and a Unicode value. A broken font never throws: widths fall back to the Standard 14
// metrics, then the descriptor's /MissingWidth, and text that cannot be traced is nil.
//
// The C# class is partial; the parts are extensions in this folder (stored properties stay in this declaration,
// internal instead of private). `get` keeps its fonts weakly where the C# ConditionalWeakTable ties each font to its
// dictionary: Swift cannot hang a value on a dictionary, and a strong table would hold every document it saw.

/// One character of a shown string. Widths and vertical metrics are in 1/1000 em (for a Type 3 font, in glyph space
/// scaled the same way by its /FontMatrix).
public struct FontChar: Equatable {
    /// The code as read from the string.
    public let code: Int

    /// How many bytes it took.
    public let length: Int

    /// The CID of a composite font; the code for a simple one.
    public let cid: Int

    /// The horizontal advance.
    public let width: Double

    /// The text it stands for, nil when nothing could be worked out.
    public let unicode: String?

    /// A single-byte code 32, the one word spacing applies to (9.3.3).
    public let isSpace: Bool

    /// The advance when the font writes vertically (usually negative).
    public let verticalAdvance: Double

    /// Where a vertical font puts the glyph origin from the horizontal one, x.
    public let originX: Double

    /// The same, y.
    public let originY: Double

    public init(code: Int, length: Int, cid: Int, width: Double, unicode: String?, isSpace: Bool,
                verticalAdvance: Double, originX: Double, originY: Double) {
        self.code = code
        self.length = length
        self.cid = cid
        self.width = width
        self.unicode = unicode
        self.isSpace = isSpace
        self.verticalAdvance = verticalAdvance
        self.originX = originX
        self.originY = originY
    }
}

public final class PdfFont {
    static let maxCached = 100_000
    private static let maxFonts = 4096

    private final class Entry {
        weak var font: PdfFont?

        init(_ font: PdfFont) {
            self.font = font
        }
    }

    private static let cacheLock = NSLock()
    private static var cache: [ObjectIdentifier: Entry] = [:]

    let document: PdfDocument
    let std14: Standard14?
    private var programValue: FontProgram?
    private var programLoaded = false
    private var toUnicode: CMap?

    private init(_ document: PdfDocument, _ dictionary: PdfDictionary) {
        let base = document.name(dictionary, "BaseFont") ?? ""
        let scalars = Array(base.unicodeScalars)
        let plain: String
        if scalars.count > 7 && scalars[6] == "+" && scalars[0..<6].allSatisfy({ $0.value >= 0x41 && $0.value <= 0x5A }) {
            plain = String(String.UnicodeScalarView(scalars[7...]))
        } else {
            plain = base
        }
        let declared = document.name(dictionary, "Subtype")
        self.document = document
        self.dictionary = dictionary
        baseFont = base
        name = plain
        if let declared, ["Type1", "MMType1", "TrueType", "Type3", "Type0"].contains(declared) {
            subtype = declared
        } else {
            subtype = dictionary["DescendantFonts"] != nil ? "Type0" : "Type1"
        }
        std14 = Standard14.find(plain)
        initialize()
    }

    /// The font for a font dictionary of `document`; the same instance each time while anything holds it.
    public static func get(_ document: PdfDocument, _ dictionary: PdfDictionary) -> PdfFont {
        let key = ObjectIdentifier(dictionary)
        cacheLock.lock()
        if let known = cache[key]?.font, known.dictionary === dictionary {
            cacheLock.unlock()
            return known
        }
        cacheLock.unlock()
        let font = PdfFont(document, dictionary)
        cacheLock.lock()
        if cache.count >= maxFonts { cache = cache.filter { $0.value.font != nil } }
        cache[key] = Entry(font)
        cacheLock.unlock()
        return font
    }

    public let dictionary: PdfDictionary

    /// Type1, MMType1, TrueType, Type3 or Type0.
    public let subtype: String

    /// /BaseFont as written, with any subset tag.
    public let baseFont: String

    /// /BaseFont without the six-letter subset tag (9.6.4).
    public let name: String

    public var isComposite: Bool { subtype == "Type0" }
    public var isType3: Bool { subtype == "Type3" }

    /// The font writes top to bottom (/WMode 1 in its CMap).
    public internal(set) var isVertical = false

    public private(set) var isEmbedded = false
    public var hasToUnicode: Bool { toUnicode != nil }
    public private(set) var descriptor: PdfDictionary?

    /// The /FontDescriptor /Flags; for a Standard 14 font without a descriptor, the flags its metrics imply.
    public private(set) var flags = 0

    public var isFixedPitch: Bool { (flags & 1) != 0 }
    public var isSerif: Bool { (flags & 2) != 0 }
    public var isSymbolic: Bool { (flags & 4) != 0 && (flags & 32) == 0 }
    public private(set) var isItalic = false
    public private(set) var isBold = false

    /// In 1/1000 em; the descent is negative.
    public internal(set) var ascent = 800.0
    public internal(set) var descent = -200.0
    public private(set) var capHeight = 0.0

    /// The glyph space to text space matrix: 0.001 scale, or the /FontMatrix of a Type 3 font.
    public internal(set) var fontMatrix = PdfMatrix(0.001, 0, 0, 0.001, 0, 0)

    /// The /FontBBox in glyph space, when the font or its descriptor gives one.
    public internal(set) var fontBBox: PdfRect?

    var program: FontProgram? {
        if programLoaded { return programValue }
        programLoaded = true
        programValue = FontProgram.load(document, descriptor)
        return programValue
    }

    // Simple fonts (PdfFont.Simple)
    var widths: [Double]?
    var firstChar = 0
    var missingWidth = 0.0
    var glyphNames: [String?]?
    var simple = [FontChar?](repeating: nil, count: 256)

    // Composite fonts (PdfFont.Composite)
    var cmap = CMap.predefined("Identity-H")
    var cidFont: PdfDictionary?
    var ordering = ""
    var defaultWidth = 1000.0
    var defaultOriginY = 880.0
    var defaultAdvance = -1000.0
    var cidWidths: [Int: Double] = [:]
    var cidVertical: [Int: (advance: Double, x: Double, y: Double)] = [:]
    var cidToGid: [UInt16]?
    var cidToGidLoaded = false
    var composite: [Int: FontChar] = [:]

    private func initialize() {
        var holder = dictionary
        if isComposite {
            let descendants = document.array(dictionary, "DescendantFonts")
            if let descendants, let first = descendants.items.first, let own = document.resolve(first) as? PdfDictionary { holder = own }
        }
        descriptor = document.dict(holder, "FontDescriptor")
        isEmbedded = descriptor.map { $0.containsKey("FontFile") || $0.containsKey("FontFile2") || $0.containsKey("FontFile3") } ?? false
        flags = document.integer(descriptor, "Flags").map { Int(Int32(truncatingIfNeeded: $0)) } ?? std14?.flags ?? 32
        let angle = document.number(descriptor, "ItalicAngle") ?? std14?.italicAngle ?? 0
        let lowered = name.lowercased()
        isItalic = (flags & 64) != 0 || angle != 0 || lowered.contains("italic") || lowered.contains("oblique")
        isBold = (flags & (1 << 18)) != 0 || lowered.contains("bold") || (document.number(descriptor, "FontWeight") ?? 0) >= 700 || std14?.isBold == true
        if let own = document.rect(descriptor, "FontBBox") {
            fontBBox = own
        } else if let s = std14 {
            fontBBox = PdfRect(Double(s.bBox.left), Double(s.bBox.bottom), Double(s.bBox.right), Double(s.bBox.top))
        }
        capHeight = document.number(descriptor, "CapHeight") ?? std14.map { Double($0.capHeight) } ?? 0
        var ascent = document.number(descriptor, "Ascent") ?? std14.map { Double($0.ascent) } ?? 0
        var descent = document.number(descriptor, "Descent") ?? std14.map { Double($0.descent) } ?? 0
        if ascent == 0 && descent == 0, let box = fontBBox {
            ascent = box.top
            descent = box.bottom
        }
        if ascent != 0 || descent != 0 {
            self.ascent = ascent
            self.descent = descent > 0 ? -descent : descent
        }
        defer { loadToUnicode() }
        if isComposite {
            initializeComposite(holder)
        } else {
            initializeSimple()
        }
    }

    // Apart from the metrics, so that a damaged map costs the text and nothing else.
    private func loadToUnicode() {
        do {
            if let stream = document.stream(dictionary, "ToUnicode") { toUnicode = CMap.parse(try document.data(stream, 16 << 20)) }
        } catch {
        }
    }

    // A ToUnicode map is often written at another code width than the font reads, so a miss at the exact width falls
    // back to the numeric code at any width.
    func mappedText(_ code: Int, _ length: Int) -> String? {
        if let exact = toUnicode?.unicodeOf(code, length: length), !exact.isEmpty { return exact }
        if let any = toUnicode?.unicodeOf(code, length: 0), !any.isEmpty { return any }
        return nil
    }

    /// Reads the first character of `bytes`; returns the bytes it took (0 for empty input).
    public func read(_ bytes: ArraySlice<UInt8>) -> (used: Int, character: FontChar) {
        guard let first = bytes.first else {
            return (0, FontChar(code: 0, length: 0, cid: 0, width: 0, unicode: nil, isSpace: false, verticalAdvance: 0, originX: 0, originY: 0))
        }
        return isComposite ? readComposite(bytes) : readSimple(first)
    }

    public func decode(_ bytes: ArraySlice<UInt8>) -> [FontChar] {
        var result: [FontChar] = []
        result.reserveCapacity(bytes.count)
        var rest = bytes
        while !rest.isEmpty {
            let (used, c) = read(rest)
            result.append(c)
            rest = rest.dropFirst(used)
        }
        return result
    }

    public func decode(_ bytes: [UInt8]) -> [FontChar] { decode(bytes[...]) }

    /// The string as text; characters that could not be traced are left out.
    public func toText(_ bytes: ArraySlice<UInt8>) -> String {
        var text = ""
        for c in decode(bytes) { text += c.unicode ?? "" }
        return text
    }

    public func toText(_ bytes: [UInt8]) -> String { toText(bytes[...]) }
}
