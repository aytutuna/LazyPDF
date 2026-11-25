import Foundation

// Twin of windows/LazyPDF.Core/Editing/FontCodec.cs: what a font already in the file can show, the bytes and width of
// each character it has a glyph for, read back from its encoding or CMap. A font cut down to a subset has glyphs for the
// characters the file uses and no more; a composite font whose program is whole (no subset tag, a TrueType program with
// the identity mapping) can also take characters through its own cmap. Text keys are compared as UTF-16 units, as the
// C# strings are, not as Swift strings, which treat canonically equivalent text as equal.

/// The bytes a character is shown with, its width in 1/1000 em, and whether word spacing applies to it.
struct FontCode {
    let bytes: [UInt8]
    let width: Double
    let isSpace: Bool
}

final class FontCodec {
    private let document: PdfDocument
    private var codes: [[UInt16]: FontCode]?
    private var added: [Int: (text: String, width: Double)] = [:]

    let font: PdfFont

    init(_ document: PdfDocument, _ font: PdfFont) {
        self.document = document
        self.font = font
    }

    var hasAdditions: Bool { !added.isEmpty }

    func tryGet(_ text: String) -> FontCode? {
        let known = codes ?? scan()
        codes = known
        return known[Array(text.utf16)]
    }

    /// The code and width for a character of the embedded program that no code of the file's font reaches; nil when the font is cut down or not a font this can extend.
    func tryExtend(_ text: String) -> FontCode? {
        guard !text.isEmpty, let tt = canExtend(), text.unicodeScalars.count == 1, let first = text.unicodeScalars.first else { return nil }
        let codePoint = Int(first.value)
        let gid = tt.glyphForCodePoint(codePoint)
        if gid <= 0 || gid > 0xFFFF { return nil }
        if tt.getBounds(gid) == nil && !(text.utf16.first?.isWhiteSpace ?? false) { return nil }
        let width = (Double(tt.getAdvance(gid)) * 1000.0 / Double(tt.unitsPerEm) * 1000).rounded(.toNearestOrEven) / 1000
        let code = FontCode(bytes: [UInt8(truncatingIfNeeded: gid >> 8), UInt8(truncatingIfNeeded: gid)], width: width, isSpace: false)
        added[gid] = (text, width)
        var known = codes ?? scan()
        known[Array(text.utf16)] = code
        codes = known
        return code
    }

    private func descendant() -> PdfDictionary? {
        guard let first = document.array(font.dictionary, "DescendantFonts")?.items.first else { return nil }
        return document.resolve(first) as? PdfDictionary
    }

    private func canExtend() -> TrueTypeFont? {
        guard font.isComposite, font.name == font.baseFont, let program = font.program?.trueType, program.cff == nil else { return nil }
        if document.name(font.dictionary, "Encoding") != "Identity-H" { return nil }
        guard let descendant = descendant() else { return nil }
        if document.name(descendant, "Subtype") != "CIDFontType2" { return nil }
        if let map = document.resolve(descendant["CIDToGIDMap"]), (map as? PdfName)?.value != "Identity" { return nil }
        return program
    }

    /// Writes the widths and text of the characters taken from the program into the font dictionary.
    func writeAdditions() {
        if added.isEmpty { return }
        guard let descendant = descendant() else { return }
        let widths: PdfArray
        if let known = document.resolve(descendant["W"]) as? PdfArray {
            widths = known
        } else {
            widths = PdfArray([])
            descendant["W"] = widths
        }
        let sorted = added.sorted { $0.key < $1.key }
        for (gid, entry) in sorted {
            widths.items.append(PdfNumber(gid))
            widths.items.append(PdfArray([PdfNumber(entry.width)]))
        }
        guard let map = document.stream(font.dictionary, "ToUnicode") else { return }
        let data: [UInt8]
        do {
            data = try document.data(map, 16 << 20)
        } catch {
            return
        }
        guard let end = Self.lastIndex(of: Array("endcmap".utf8), in: data) else { return }
        var section = ""
        var from = 0
        while from < sorted.count {
            let chunk = sorted[from..<Swift.min(from + 100, sorted.count)]
            section += "\(chunk.count) beginbfchar\n"
            for (gid, entry) in chunk {
                let code = String(gid, radix: 16, uppercase: true)
                let hex = entry.text.utf16.map { unit -> String in
                    let digits = String(unit, radix: 16, uppercase: true)
                    return String(repeating: "0", count: 4 - digits.count) + digits
                }.joined()
                section += "<\(String(repeating: "0", count: Swift.max(0, 4 - code.count)) + code)> <\(hex)>\n"
            }
            section += "endbfchar\n"
            from += 100
        }
        map.dictionary["Filter"] = PdfName("FlateDecode")
        map.dictionary.remove("DecodeParms")
        map.data = PdfFilterEncoders.flate(Array(data[..<end]) + Latin1.bytes(section) + Array(data[end...]))
    }

    private static func lastIndex(of needle: [UInt8], in data: [UInt8]) -> Int? {
        if data.count < needle.count { return nil }
        var i = data.count - needle.count
        while i >= 0 {
            if Array(data[i..<i + needle.count]) == needle { return i }
            i -= 1
        }
        return nil
    }

    private func toUnicode() -> CMap? {
        guard let stream = document.stream(font.dictionary, "ToUnicode") else { return nil }
        do {
            return CMap.parse(try document.data(stream, 16 << 20))
        } catch {
            return nil
        }
    }

    private static func isControl(_ unit: UInt16) -> Bool { unit < 0x20 || (unit >= 0x7F && unit < 0xA0) }

    private func scan() -> [[UInt16]: FontCode] {
        var codes: [[UInt16]: FontCode] = [:]
        // A whole program reaches glyphs the file never mentions; those have no width or text entry yet and go through tryExtend.
        let mapped = canExtend() != nil ? toUnicode() : nil
        func add(_ ch: FontChar) {
            guard let unicode = ch.unicode, !unicode.isEmpty, !unicode.utf16.contains(where: Self.isControl) else { return }
            if let mapped, (mapped.unicodeOf(ch.code, length: ch.length)?.isEmpty ?? true) { return }
            let blank = unicode.utf16.allSatisfy { $0.isWhiteSpace }
            if ch.width <= 0 && !blank { return }
            if !font.canDraw(ch) { return }
            var bytes = [UInt8](repeating: 0, count: Swift.max(0, ch.length))
            for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: ch.code >> (8 * (bytes.count - 1 - i))) }
            let key = Array(unicode.utf16)
            if codes[key] == nil { codes[key] = FontCode(bytes: bytes, width: ch.width, isSpace: ch.isSpace) }
        }
        if !font.isComposite {
            for c in 0..<256 { add(font.read([UInt8(c)][...]).character) }
            return codes
        }
        var buffer: [UInt8] = [0, 0, 0, 0]
        for hi in 0..<256 {
            buffer = [UInt8(hi), 0, 0, 0]
            let (used, ch) = font.read(buffer[...])
            if used == 1 {
                add(ch)
                continue
            }
            if used != 2 { continue }
            for lo in 0..<256 {
                buffer[1] = UInt8(lo)
                let (n, each) = font.read(buffer[...])
                if n == 2 { add(each) }
            }
        }
        return codes
    }
}

/// Picks a system font for characters the file's font cannot show, by the names and flags of the one that is there.
enum FontMatch {
    /// Family names to try, best first, and the style.
    static func `for`(_ font: PdfFont) -> (families: [String], style: FontStyles) {
        let name = font.name
        let scalars = Array(name.unicodeScalars)
        var family = scalars
        if let cut = scalars.firstIndex(where: { $0 == "-" || $0 == "," }), cut > 0 { family = Array(scalars[..<cut]) }
        for suffix in ["PSMT", "MT", "PS"] {
            let tail = Array(suffix.unicodeScalars)
            if family.count > tail.count + 2 && Array(family.suffix(tail.count)) == tail {
                family = Array(family.dropLast(tail.count))
                break
            }
        }
        let spaced = split(family)
        var style: FontStyles = []
        if font.isBold { style.insert(.bold) }
        if font.isItalic { style.insert(.italic) }
        let narrow = has(name, "narrow", ignoringCase: true) || has(name, "condensed", ignoringCase: true) || has(name, "Cond", ignoringCase: false)
        var families: [String] = []
        if narrow && !has(spaced, "Narrow", ignoringCase: false) { families.append(spaced + " Narrow") }
        families.append(spaced)
        families.append(font.isFixedPitch ? "Courier New" : font.isSerif ? "Times New Roman" : "Arial")
        var distinct: [String] = []
        for each in families where !distinct.contains(where: { Array($0.utf16) == Array(each.utf16) }) { distinct.append(each) }
        return (distinct, style)
    }

    // string.Contains with StringComparison.Ordinal or OrdinalIgnoreCase, on UTF-16 units; the needle is ASCII.
    private static func has(_ text: String, _ needle: String, ignoringCase: Bool) -> Bool {
        func fold(_ unit: UInt16) -> UInt16 { ignoringCase && unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit }
        let units = text.utf16.map(fold)
        let target = needle.utf16.map(fold)
        if target.count > units.count { return false }
        for i in 0...(units.count - target.count) where Array(units[i..<i + target.count]) == target { return true }
        return false
    }

    private static func split(_ name: [Unicode.Scalar]) -> String {
        var result = String.UnicodeScalarView()
        for i in 0..<name.count {
            if i > 0 && name[i].properties.generalCategory == .uppercaseLetter && name[i - 1].properties.generalCategory == .lowercaseLetter {
                result.append(" ")
            }
            result.append(name[i])
        }
        return String(result)
    }
}
