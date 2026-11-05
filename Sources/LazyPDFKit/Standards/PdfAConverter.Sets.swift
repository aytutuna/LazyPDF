import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAConverter.Sets.cs: subset sets and TrueType encodings of fonts that are already
// embedded. The C# SortedDictionary<int, string> of the encodings is a Dictionary listed by key where it is walked.

extension PdfAConversionRun {
    static let maxCharSet = 32767

    // 6.3.5: part 1 wants a CIDSet or CharSet on a subset; a set that is there is rebuilt from the program when it misses a glyph the program
    // holds or the content shows, and dropped when it cannot be.
    func fixSubsetSets(_ descriptor: PdfDictionary, _ holder: PdfDictionary, _ pdfFont: PdfFont, _ used: SortedInts) throws -> Bool {
        let wanted = part == 1 && Self.isSubsetName(document.name(descriptor, "FontName"))
        let program = FontProgram.load(document, descriptor)
        var changed = false
        if pdfFont.isComposite {
            let set = document.stream(descriptor, "CIDSet")
            let cids = programCids(program, holder, used)
            let rewrite: Bool
            if let set {
                rewrite = !cidSetCovers(set, cids?.sorted ?? used.sorted)
            } else {
                rewrite = wanted
            }
            if rewrite {
                var made: PdfObject?
                if let cids { made = try document.add(Self.cidSetStream(cids.sorted)) }
                changed = Self.put(descriptor, "CIDSet", made) || changed
            }
        } else if document.name(holder, "Subtype") == "Type1" || document.name(holder, "Subtype") == "MMType1" {
            let listed = (document.resolve(descriptor["CharSet"]) as? PdfString).map { Set(PdfAChecker.charSetNames($0)) }
            let shown = Set(used.compactMap { pdfFont.glyphNameOf($0) }.filter { $0 != ".notdef" })
            let names = Self.programNames(program, shown)
            let rewrite: Bool
            if let listed {
                rewrite = !(names.map { Set($0) } ?? shown).isSubset(of: listed)
            } else {
                rewrite = wanted
            }
            if rewrite { changed = Self.put(descriptor, "CharSet", Self.charSet(names)) || changed }
        }
        return changed
    }

    private static func isSubsetName(_ name: String?) -> Bool {
        guard let units = name.map({ Array($0.utf16) }), units.count > 7, units[6] == 0x2B else { return false }
        return units[0..<6].allSatisfy { $0 >= 0x41 && $0 <= 0x5A }
    }

    private static func put(_ descriptor: PdfDictionary, _ key: String, _ value: PdfObject?) -> Bool {
        guard let value else { return descriptor.remove(key) }
        descriptor[key] = value
        return true
    }

    private func cidSetCovers(_ set: PdfStream, _ cids: [Int]) -> Bool {
        do {
            let bits = try document.data(set, 1 << 20)
            return cids.allSatisfy { $0 >= 0 && ($0 >> 3) < bits.count && (Int(bits[$0 >> 3]) & (0x80 >> ($0 & 7))) != 0 }
        } catch {
            return false
        }
    }

    // The CIDs of every glyph the program draws, the shown ones among them; nil when the program or its /CIDToGIDMap cannot be read.
    private func programCids(_ program: FontProgram?, _ holder: PdfDictionary, _ used: SortedInts) -> SortedInts? {
        var map: [UInt8]?
        if let stream = document.resolve(holder["CIDToGIDMap"]) as? PdfStream {
            do {
                map = try document.data(stream, 1 << 17)
            } catch {
                return nil
            }
        }
        let cids = SortedInts(used.sorted + [0])
        guard let program, Self.addGlyphCids(cids, program.cff, program.trueType, map) else { return nil }
        return cids
    }

    // An empty slot of a subset TrueType font is no glyph. With a map the CIDs are the entries that reach one.
    static func addGlyphCids(_ cids: SortedInts, _ cff: CffFont?, _ tt: TrueTypeFont?, _ map: [UInt8]?) -> Bool {
        if let cff {
            for glyph in 0..<cff.glyphCount { cids.insert(cff.cidForGlyph(glyph)) }
        } else if let tt {
            if let map {
                var cid = 0
                while 2 * cid + 1 < map.count {
                    let glyph = Int(map[2 * cid]) << 8 | Int(map[2 * cid + 1])
                    if glyph > 0 && tt.glyphData(glyph).length > 0 { cids.insert(cid) }
                    cid += 1
                }
            } else {
                for glyph in 0..<tt.glyphCount where tt.glyphData(glyph).length > 0 { cids.insert(glyph) }
            }
        } else {
            return false
        }
        return true
    }

    static func cidSetStream(_ cids: [Int]) -> PdfStream {
        var bits = [UInt8](repeating: 0, count: ((cids.max() ?? 0) >> 3) + 1)
        for cid in cids where cid >= 0 { bits[cid >> 3] |= UInt8(0x80 >> (cid & 7)) }
        let dictionary = PdfDictionary()
        dictionary["Filter"] = PdfName("FlateDecode")
        return PdfStream(dictionary, data: PdfFilterEncoders.flate(bits))
    }

    // Names of the glyphs the program holds and the content shows; nil for a program that does not list names. ISO 32000-1 Table 122 leaves .notdef out.
    private static func programNames(_ program: FontProgram?, _ shown: Set<String>) -> [String]? {
        var names = shown
        if let type1 = program?.type1 {
            names.formUnion(type1.glyphNames)
        } else if let cff = program?.cff, !cff.isCid {
            for glyph in 0..<cff.glyphCount {
                if let name = cff.glyphName(glyph) { names.insert(name) }
            }
        } else {
            return nil
        }
        names.remove(".notdef")
        return names.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }

    private static func charSet(_ names: [String]?) -> PdfObject? {
        guard let names else { return nil }
        var text = ""
        for name in names where name.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F && $0 != "/" && $0 != "(" && $0 != ")" }) {
            text += "/" + name
        }
        return text.utf16.count > maxCharSet ? nil : PdfString(bytes: Latin1.bytes(text), isHex: false)
    }

    // 9.6.6.4 and 6.2.11.6: a non-symbolic TrueType font names WinAnsi or MacRoman, and names of other glyphs go in /Differences, which
    // the standard allows only with AGL names and a (3,1) cmap. A code the content shows keeps its glyph; when that cannot be done within
    // the rules the font is left as it is and reported.
    func fixEncoding(_ font: PdfDictionary, _ holder: PdfDictionary, _ descriptor: PdfDictionary, _ pdfFont: PdfFont, _ used: SortedInts, _ subtype: String?) -> Bool {
        if subtype == "Type0" {
            if document.name(holder, "Subtype") != "CIDFontType2" || !descriptor.containsKey("FontFile2") || holder["CIDToGIDMap"] != nil { return false }
            holder["CIDToGIDMap"] = PdfName("Identity")
            return true
        }
        if subtype != "TrueType" { return false }
        let flags = document.integer(descriptor, "Flags") ?? 0
        let encoding = document.resolve(font["Encoding"])
        let parsed = FontProgram.load(document, descriptor)?.trueType
        let tt = parsed?.cff == nil ? parsed : nil
        let symbolic = (flags & 4) != 0 && (flags & 32) == 0
        if symbolic {
            if encoding == nil { return false }
            if Self.sameGlyphsByCode(tt, pdfFont, used) { return font.remove("Encoding") }
        }

        let baseName: String?
        switch encoding {
        case let name as PdfName: baseName = name.value
        case let dictionary as PdfDictionary: baseName = document.name(dictionary, "BaseEncoding")
        default: baseName = nil
        }
        let named = baseName == "WinAnsiEncoding" || baseName == "MacRomanEncoding"
        let read = (encoding as? PdfDictionary).map { readDifferences(document.array($0, "Differences")) } ?? [:]
        let listed = named ? read : [:]
        let unicodeCmap = tt == nil || tt?.hasCmap(3, 1) == true
        if symbolic && !unicodeCmap { return false }
        var differences = unicodeCmap ? listed.filter { Self.aglNames.contains($0.value) } : [:]
        let table = named ? baseName ?? "WinAnsiEncoding" : "WinAnsiEncoding"
        guard let names = PdfEncodings.byName(table) else { return false }
        if let tt {
            for code in used where code >= 0 && code < 256 {
                // Without a base encoding a non-symbolic font starts from StandardEncoding (9.6.6.4), where PdfFont assumes WinAnsi.
                let shown = baseName == nil && !symbolic ? read[code] ?? PdfEncodings.standard[code] : pdfFont.glyphNameOf(code)
                let old = Self.drawnGlyph(tt, shown, code)
                if old == 0 || old == Self.drawnGlyph(tt, differences[code] ?? names[code], code) { continue }
                guard unicodeCmap, let pin = Self.pinName(pdfFont, tt, old) else { return leftAsItIs(pdfFont, named && !symbolic) }
                differences[code] = pin
            }
        }
        let same = named && differences == listed
        if symbolic { descriptor["Flags"] = PdfNumber((flags & ~4) | 32) }
        if same { return symbolic }
        font["Encoding"] = differences.isEmpty ? PdfName(table) : Self.encodingDictionary(table, differences)
        return true
    }

    // A font with no named base is reported by the checker already; one with WinAnsi or MacRoman and /Differences that cannot go is reported here.
    private func leftAsItIs(_ pdfFont: PdfFont, _ named: Bool) -> Bool {
        if named { left.append(PdfAIssue(part == 1 ? "6.3.7" : "6.2.11.6", PdfAText.fontName(pdfFont.baseFont), PdfAText.trueTypeDifferences)) }
        return false
    }

    private static let aglNames: Set<String> = {
        var names = Set<String>()
        for line in TableBlob.inflateText(GlyphListData.agl).unicodeScalars.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            if fields.count > 1, let first = fields.first { names.insert(String(first)) }
        }
        return names
    }()

    // The names of Apple's Mac OS Roman that 9.6.6.4 goes through and PDF's MacRomanEncoding leaves out.
    private static let macCodes: [String: Int] = {
        var codes = PdfAConversionRun.codesByName(PdfEncodings.macRoman) ?? [:]
        let extra = ["notequal", "infinity", "lessequal", "greaterequal", "partialdiff", "summation", "product", "pi", "integral", "Omega", "radical", "approxequal", "Delta", "lozenge", "apple", "Euro"]
        let at = [0xAD, 0xB0, 0xB2, 0xB3, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBD, 0xC3, 0xC5, 0xC6, 0xD7, 0xF0, 0xDB]
        for i in 0..<extra.count where codes[extra[i]] == nil { codes[extra[i]] = at[i] }
        return codes
    }()

    // The glyph the reader draws for a code: the one the name reaches, else the code through the others.
    private static func drawnGlyph(_ tt: TrueTypeFont, _ name: String?, _ code: Int) -> Int {
        if let name {
            let glyph = byName(tt, name)
            if glyph > 0 { return glyph }
        }
        return byCode(tt, code)
    }

    // 9.6.6.4: the character of the name through the (3,1) cmap, and without one the Mac OS Roman code of the name through the (1,0) cmap;
    // a name that reaches no glyph that way is looked up in the 'post' table.
    private static func byName(_ tt: TrueTypeFont, _ name: String) -> Int {
        var glyph = 0
        if !tt.hasCmap(3, 1) && tt.hasCmap(1, 0) {
            if let mac = macCodes[name] { glyph = tt.glyphForCmap(1, 0, mac) }
        } else if let text = GlyphList.unicodeOf(name), let first = text.unicodeScalars.first {
            glyph = tt.glyphForCodePoint(Int(first.value))
        }
        return glyph > 0 ? glyph : tt.glyphForName(name)
    }

    private static func byCode(_ tt: TrueTypeFont, _ code: Int) -> Int {
        var glyph = tt.glyphForCmap(3, 0, code)
        if glyph == 0 { glyph = tt.glyphForCmap(3, 0, 0xF000 + code) }
        if glyph == 0 { glyph = tt.glyphForCmap(1, 0, code) }
        return glyph != 0 ? glyph : tt.glyphForCodePoint(code)
    }

    // A name that reaches the glyph through the Unicode cmap, or nil when the glyph has no character of its own there.
    private static func pinName(_ pdfFont: PdfFont, _ tt: TrueTypeFont, _ glyph: Int) -> String? {
        guard let text = pdfFont.program?.unicodeOf(glyph) else { return nil }
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 1 else { return nil }
        let codePoint = Int(scalars[0].value)
        let name = GlyphList.nameOf(codePoint)
        return tt.glyphForCodePoint(codePoint) == glyph && aglNames.contains(name) ? name : nil
    }

    // The reader finds a glyph by the name first (9.6.6.4); without an encoding the cmap by code decides, and it has to agree.
    private static func sameGlyphsByCode(_ tt: TrueTypeFont?, _ pdfFont: PdfFont, _ used: SortedInts) -> Bool {
        guard let tt else { return true }
        for code in used {
            guard let name = pdfFont.glyphNameOf(code) else { continue }
            let named = byName(tt, name)
            if named > 0 && named != byCode(tt, code) { return false }
        }
        return true
    }

    private func readDifferences(_ array: PdfArray?) -> [Int: String] {
        var result: [Int: String] = [:]
        var code = 0
        guard let array else { return result }
        for item in array.items {
            switch document.resolve(item) {
            case let number as PdfNumber:
                code = number.value.isNaN ? 0 : Int(Swift.min(Swift.max(number.value, 0), 256))
            case let glyph as PdfName:
                if code < 256 { result[code] = glyph.value }
                code += 1
            default:
                break
            }
        }
        return result
    }

    private static func encodingDictionary(_ baseName: String, _ differences: [Int: String]) -> PdfDictionary {
        var items: [PdfObject] = []
        var next = -1
        for (code, glyph) in differences.sorted(by: { $0.key < $1.key }) {
            if code != next { items.append(PdfNumber(code)) }
            items.append(PdfName(glyph))
            next = code + 1
        }
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("Encoding")
        dictionary["BaseEncoding"] = PdfName(baseName)
        dictionary["Differences"] = PdfArray(items)
        return dictionary
    }
}
