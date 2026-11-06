import Foundation

// Twin of windows/LazyPDF.Core/Optimize/OptimizeFonts.cs: trims fully embedded TrueType programs to the glyphs the
// document shows. A program is trimmed only when every font that uses it is listed in page, form or pattern
// resources and nowhere else (the form's /DR, a field's /DA, anything later editing could use), and every table
// that lists it was walked to the end. A program shared with a subset-tagged font is left alone.

final class OptimizeFonts {
    private final class Program {
        let stream: PdfStream
        var fonts: [PdfDictionary] = []
        var blocked = false
        var tagged = false

        init(_ stream: PdfStream) { self.stream = stream }
    }

    private final class Uses: OptimizeWalk {
        var codes: [ObjectIdentifier: Set<Int>] = [:]

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            codes[ObjectIdentifier(glyph.font.dictionary), default: []].insert(glyph.font.isComposite ? glyph.character.cid : glyph.character.code)
        }
    }

    private let document: PdfDocument

    init(_ document: PdfDocument) {
        self.document = document
    }

    func run() -> (trimmed: Int, partial: Bool) {
        var partial = false
        let (listed, outside) = listedFonts()
        var seen = Set<ObjectIdentifier>()
        var fonts: [(font: PdfDictionary, number: Int, program: PdfStream)] = []
        func consider(_ font: PdfDictionary, _ number: Int) {
            guard let subtype = document.name(font, "Subtype"), subtype == "TrueType" || subtype == "Type0",
                  seen.insert(ObjectIdentifier(font)).inserted, let program = programOf(font) else { return }
            fonts.append((font, number, program))
        }
        var numbers: [ObjectIdentifier: Int] = [:]
        for (number, value) in PdfGraph.objects(document) {
            if let indirect = value as? PdfDictionary { numbers[ObjectIdentifier(indirect)] = number }
        }
        // A font written directly has no number to be referred to by, and is blocked unless a /Font table lists it.
        for font in PdfGraph.allDictionaries(document) { consider(font, numbers[ObjectIdentifier(font)] ?? 0) }
        if fonts.isEmpty { return (0, false) }

        let uses = Uses(document)
        uses.walk()
        var programs: [ObjectIdentifier: Program] = [:]
        var order: [Program] = []
        for (font, number, stream) in fonts {
            let entry: Program
            if let known = programs[ObjectIdentifier(stream)] {
                entry = known
            } else {
                entry = Program(stream)
                programs[ObjectIdentifier(stream)] = entry
                order.append(entry)
            }
            entry.fonts.append(font)
            if Self.hasSubsetTag(document.name(font, "BaseFont") ?? "") { entry.tagged = true }
            if !uses.complete || outside.contains(number) {
                entry.blocked = true
            } else if let owners = listed[ObjectIdentifier(font)] {
                if !owners.allSatisfy({ uses.reached($0) }) { entry.blocked = true }
            } else {
                entry.blocked = true
            }
        }

        var trimmed = 0
        for program in order {
            if program.tagged { continue }
            if program.blocked {
                partial = true
            } else if trim(program, uses) {
                trimmed += 1
            }
        }
        return (trimmed, partial)
    }

    private static func hasSubsetTag(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        return scalars.count >= 7 && scalars[0..<6].allSatisfy { $0.value >= 65 && $0.value <= 90 } && scalars[6] == "+"
    }

    // The font dictionaries named by a /Resources /Font dictionary with the resource dictionaries that hold it, and the numbers of objects referred to from anywhere else.
    private func listedFonts() -> (listed: [ObjectIdentifier: [PdfDictionary]], outside: Set<Int>) {
        var tables: [ObjectIdentifier: [PdfDictionary]] = [:]
        var tableOrder: [PdfDictionary] = []
        for dictionary in PdfGraph.allDictionaries(document) {
            guard let resources = document.dict(dictionary, "Resources"), let fonts = document.dict(resources, "Font") else { continue }
            if tables[ObjectIdentifier(fonts)] == nil { tableOrder.append(fonts) }
            tables[ObjectIdentifier(fonts), default: []].append(resources)
        }
        var listed: [ObjectIdentifier: [PdfDictionary]] = [:]
        var outside = Set<Int>()
        for (_, value) in PdfGraph.objects(document) {
            for container in PdfGraph.containersOf(value) {
                var children: [PdfObject] = []
                var owners: [PdfDictionary]?
                if let d = container as? PdfDictionary {
                    children = d.entries.map { $0.value }
                    owners = tables[ObjectIdentifier(d)]
                } else if let array = container as? PdfArray {
                    children = array.items
                }
                for child in children {
                    guard let reference = child as? PdfReference else { continue }
                    if let owners, let font = document.get(reference.number) as? PdfDictionary {
                        listed[ObjectIdentifier(font), default: []] += owners
                    } else {
                        outside.insert(reference.number)
                    }
                }
            }
        }
        for table in tableOrder {
            let owners = tables[ObjectIdentifier(table)] ?? []
            for (_, item) in table.entries {
                if let direct = item as? PdfDictionary { listed[ObjectIdentifier(direct), default: []] += owners }
            }
        }
        return (listed, outside)
    }

    private func programOf(_ font: PdfDictionary) -> PdfStream? {
        var holder: PdfDictionary? = font
        if document.name(font, "Subtype") == "Type0" {
            holder = document.resolve(document.array(font, "DescendantFonts")?.items.first) as? PdfDictionary
            if document.name(holder, "Subtype") != "CIDFontType2" { return nil }
        }
        return document.stream(document.dict(holder, "FontDescriptor"), "FontFile2")
    }

    private func trim(_ program: Program, _ uses: Uses) -> Bool {
        let stream = program.stream
        let data: [UInt8]
        do {
            data = try document.data(stream)
        } catch {
            return false
        }
        if data.count < 12 || (data[0] == 0x74 && data[1] == 0x74 && data[2] == 0x63) { return false }
        guard let font = TrueTypeFont.tryParse(data), !font.isCff, font.hasTable("glyf"), font.subsettingAllowed, font.embeddingAllowed else { return false }
        var glyphs = Set<Int>()
        for dictionary in program.fonts {
            let codes = uses.codes[ObjectIdentifier(dictionary)] ?? []
            if document.name(dictionary, "Subtype") == "Type0" {
                composite(dictionary, codes, &glyphs)
            } else {
                simple(dictionary, font, codes, &glyphs)
            }
        }
        guard let trimmed = TrueTypeTrim.trim(data, glyphs), Double(trimmed.count) <= Double(data.count) * 0.9 else { return false }
        let packed = PdfFilterEncoders.flate(trimmed, .smallestSize)
        if packed.count >= document.rawData(stream).count { return false }
        stream.data = packed
        stream.dictionary["Filter"] = PdfName("FlateDecode")
        stream.dictionary.remove("DecodeParms")
        stream.dictionary["Length1"] = PdfNumber(trimmed.count)
        return true
    }

    private func composite(_ font: PdfDictionary, _ cids: Set<Int>, _ glyphs: inout Set<Int>) {
        guard let descendant = document.resolve(document.array(font, "DescendantFonts")?.items.first) as? PdfDictionary else { return }
        var map: [UInt8]?
        if let s = document.resolve(descendant["CIDToGIDMap"]) as? PdfStream { map = safeData(s) }
        for cid in cids.sorted() {
            guard let map else {
                glyphs.insert(cid)
                continue
            }
            if cid >= 0 && 2 * cid + 1 < map.count { glyphs.insert(Int(map[2 * cid]) << 8 | Int(map[2 * cid + 1])) }
        }
    }

    private func safeData(_ stream: PdfStream) -> [UInt8]? {
        try? document.data(stream)
    }

    // Every glyph any reading of the encoding could pick for a code: more than needed, never fewer.
    private func simple(_ font: PdfDictionary, _ tt: TrueTypeFont, _ codes: Set<Int>, _ glyphs: inout Set<Int>) {
        var differences: [Int: String] = [:]
        if let encoding = document.resolve(font["Encoding"]) as? PdfDictionary, let list = document.array(encoding, "Differences") {
            var at = 0
            for item in list.items.prefix(4096) {
                if let n = document.resolve(item) as? PdfNumber {
                    // (int) of a double saturates and reads NaN as 0 in .NET.
                    at = n.value.isNaN ? 0 : Int(Swift.max(-2147483648, Swift.min(2147483647, n.value)))
                } else if let name = document.resolve(item) as? PdfName {
                    differences[at] = name.value
                    at += 1
                }
            }
        }
        for code in codes.sorted() {
            var names: [String] = []
            if let named = differences[code] { names.append(named) }
            for table in [PdfEncodings.winAnsi, PdfEncodings.macRoman, PdfEncodings.standard] {
                if code >= 0 && code < 256, let glyphName = table[code] { names.append(glyphName) }
            }
            var found = [
                tt.glyphForCmap(3, 0, code), tt.glyphForCmap(3, 0, 0xF000 + code), tt.glyphForCmap(3, 0, 0xF100 + code),
                tt.glyphForCmap(3, 0, 0xF200 + code), tt.glyphForCmap(1, 0, code), tt.glyphForCodePoint(code),
            ]
            for name in names {
                found.append(tt.glyphForName(name))
                let mac = PdfEncodings.codeOf(PdfEncodings.macRoman, name)
                if mac >= 0 { found.append(tt.glyphForCmap(1, 0, mac)) }
                if let text = GlyphList.unicodeOf(name), let first = text.unicodeScalars.first {
                    found.append(tt.glyphForCodePoint(Int(first.value)))
                }
            }
            for g in found where g > 0 { glyphs.insert(g) }
        }
    }
}
