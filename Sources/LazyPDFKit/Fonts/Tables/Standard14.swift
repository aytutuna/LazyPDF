import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Tables/Standard14.cs: one of the 14 standard fonts (ISO 32000-1 9.6.2.2)
// with the metrics of its Adobe AFM file. `find` also answers to the names other programs give them: Arial,
// TimesNewRomanPS-BoldMT.

/// A font's bounding box in glyph space (1000 units to the em).
public struct FontBox: Equatable {
    public var left: Int
    public var bottom: Int
    public var right: Int
    public var top: Int

    public init(left: Int, bottom: Int, right: Int, top: Int) {
        self.left = left
        self.bottom = bottom
        self.right = right
        self.top = top
    }
}

public final class Standard14 {
    private let widths: [String: Int]

    private init(_ f: [Substring], _ widths: [String: Int]) {
        func int(_ i: Int) -> Int {
            guard let value = Int(f[i]) else { preconditionFailure("Bad number in the Standard 14 table.") }
            return value
        }
        guard let angle = Double(f[10]) else { preconditionFailure("Bad number in the Standard 14 table.") }
        name = String(f[1])
        ascent = int(2)
        descent = int(3)
        bBox = FontBox(left: int(4), bottom: int(5), right: int(6), top: int(7))
        capHeight = int(8)
        xHeight = int(9)
        italicAngle = angle
        stemV = int(11)
        isFixedPitch = f[12] == "1"
        isBold = f[13] == "1"
        self.widths = widths
    }

    /// The BaseFont name: "Helvetica-Bold", "Times-Roman", "Symbol".
    public let name: String

    /// The AFM's Ascender and Descender (negative); the bounding box's top and bottom for Symbol and ZapfDingbats, which have none.
    public let ascent: Int

    public let descent: Int

    public let bBox: FontBox

    /// Zero where the AFM gives none (Symbol, ZapfDingbats).
    public let capHeight: Int

    public let xHeight: Int

    public let italicAngle: Double

    public let stemV: Int

    public let isFixedPitch: Bool

    public let isBold: Bool

    public var isItalic: Bool { italicAngle != 0 }

    public var isSerif: Bool { name.hasPrefix("Times") }

    /// Symbol and ZapfDingbats, whose encoding is built in and not a Latin one.
    public var isSymbolic: Bool { name == "Symbol" || name == "ZapfDingbats" }

    /// The /Flags of a FontDescriptor for the font (ISO 32000-1 9.8.2).
    public var flags: Int {
        (isFixedPitch ? 1 : 0) | (isSerif ? 2 : 0) | (isSymbolic ? 4 : 32) | (isItalic ? 64 : 0) | (isBold ? 1 << 18 : 0)
    }

    /// What a code shows when the font has no /Encoding: Symbol's and ZapfDingbats' own, else StandardEncoding.
    public var builtInEncoding: [String?] {
        switch name {
        case "Symbol": return PdfEncodings.symbol
        case "ZapfDingbats": return PdfEncodings.zapfDingbats
        default: return PdfEncodings.standard
        }
    }

    /// The advance of a glyph in 1/1000 em, or nil when the font has no glyph of that name.
    public func widthOf(_ glyphName: String) -> Int? {
        widths[glyphName]
    }

    private static let fonts = load()

    // Longest first: "TimesNewRoman" before "Times".
    private static let families = [
        ("TimesNewRoman", "Times"), ("Times", "Times"), ("Arial", "Helvetica"), ("Helvetica", "Helvetica"),
        ("CourierNew", "Courier"), ("Courier", "Courier"), ("Symbol", "Symbol"), ("ZapfDingbats", "ZapfDingbats"),
    ]

    public static var all: [Standard14] { fonts }

    /// The standard font a BaseFont name stands for, or nil. A subset tag (ABCDEF+) is ignored, so are
    /// case, spaces, and the "PS" and "MT" of the Windows names; "Arial Narrow" and "Arial Black" are other fonts and give nil.
    public static func find(_ baseFont: String) -> Standard14? {
        // UTF-16 units, as the C# string is: the length test and the cuts count the same.
        var name = Array(baseFont.utf16)
        if name.count > 7 && name[6] == 0x2B {
            name.removeFirst(7)
        }
        name.removeAll { $0 == 0x20 }
        for (prefix, family) in families {
            let prefixUnits = Array(prefix.utf16)
            guard name.count >= prefixUnits.count, matches(name, at: 0, prefixUnits) else {
                continue
            }
            var rest = Array(name[prefixUnits.count...]).filter { $0 != 0x2D && $0 != 0x2C }
            rest = strip(strip(rest, "PS"), "MT")
            if family == "Symbol" || family == "ZapfDingbats" {
                return rest.isEmpty ? byName(family) : nil
            }

            let bold = contains(rest, "Bold")
            let italic = contains(rest, "Italic") || contains(rest, "Oblique")
            for word in ["Bold", "Italic", "Oblique", "Roman", "Regular", "Normal"] {
                rest = strip(rest, word)
            }
            if !rest.isEmpty {
                return nil
            }

            let style: String
            switch (bold, italic) {
            case (false, false): style = family == "Times" ? "-Roman" : ""
            case (true, false): style = "-Bold"
            case (false, true): style = family == "Times" ? "-Italic" : "-Oblique"
            default: style = family == "Times" ? "-BoldItalic" : "-BoldOblique"
            }
            return byName(family + style)
        }
        return nil
    }

    private static func byName(_ name: String) -> Standard14? {
        fonts.first { $0.name == name }
    }

    // Ordinal, ignoring case: the words are ASCII, so folding A to Z is all there is to compare.
    private static func fold(_ unit: UInt16) -> UInt16 {
        unit >= 0x41 && unit <= 0x5A ? unit + 32 : unit
    }

    private static func matches(_ text: [UInt16], at start: Int, _ word: [UInt16]) -> Bool {
        guard start + word.count <= text.count else {
            return false
        }
        for i in word.indices where fold(text[start + i]) != fold(word[i]) {
            return false
        }
        return true
    }

    private static func contains(_ text: [UInt16], _ word: String) -> Bool {
        let units = Array(word.utf16)
        return text.indices.contains { matches(text, at: $0, units) }
    }

    private static func strip(_ text: [UInt16], _ word: String) -> [UInt16] {
        let units = Array(word.utf16)
        var result: [UInt16] = []
        var i = 0
        while i < text.count {
            if matches(text, at: i, units) {
                i += units.count
            } else {
                result.append(text[i])
                i += 1
            }
        }
        return result
    }

    private static func load() -> [Standard14] {
        var fonts: [Standard14] = []
        var header: [Substring] = []
        for line in TableBlob.inflateText(Standard14Data.fonts).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("F ") {
                header = line.split(separator: " ", omittingEmptySubsequences: false)
                continue
            }
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            var widths = [String: Int](minimumCapacity: (parts.count - 1) / 2)
            for i in stride(from: 1, to: parts.count - 1, by: 2) {
                guard let width = Int(parts[i + 1]) else { preconditionFailure("Bad width in the Standard 14 table.") }
                widths[String(parts[i])] = width
            }
            fonts.append(Standard14(header, widths))
        }
        return fonts
    }
}
