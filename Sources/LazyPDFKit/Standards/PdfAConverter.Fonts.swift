import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAConverter.Fonts.cs: fonts: a font that is not embedded is replaced in place by an
// embedded subset, keeping the codes the content uses, and the faults of an embedded one (widths, subset sets, encodings, a
// missing /ToUnicode) are corrected. The C# SortedDictionary<int, ...> is a Dictionary listed by key where it is walked.

extension PdfAConversionRun {
    func fixFonts(_ before: PdfAChecker) throws {
        var embedded = 0, corrected = 0
        for font in before.fonts {
            var pdfFont = PdfFont.get(document, font)
            let subtype = document.name(font, "Subtype")
            let used = before.uses(font) ?? SortedInts()
            if subtype == "Type3" {
                if wantsToUnicode(before, font, pdfFont, used), try addToUnicode(font, pdfFont, used) { corrected += 1 }
                reportUnicodeHoles(font, used)
                continue
            }
            var holder = font
            if subtype == "Type0", let kids = document.array(font, "DescendantFonts"), let first = kids.items.first, let cid = document.resolve(first) as? PdfDictionary {
                holder = cid
            }
            let described = document.dict(holder, "FontDescriptor")
            guard let descriptor = described, descriptor.containsKey("FontFile") || descriptor.containsKey("FontFile2") || descriptor.containsKey("FontFile3") else {
                let done = try (subtype == "Type0" ? embedComposite(font, holder, pdfFont, used) : embedSimple(font, pdfFont, used))
                if done { embedded += 1 } else { reportUnicodeHoles(font, used) }
                continue
            }
            var changed = fixEncoding(font, holder, descriptor, pdfFont, used, subtype)
            if changed { pdfFont = snapshot(font) }
            changed = fixWidths(font, holder, pdfFont, used) || changed
            changed = try fixSubsetSets(descriptor, holder, pdfFont, used) || changed
            if wantsToUnicode(before, font, pdfFont, used) { changed = try addToUnicode(font, pdfFont, used) || changed }
            if changed { corrected += 1 }
            reportUnicodeHoles(font, used)
        }
        if embedded > 0 { self.changed(PdfAText.fontsEmbedded(embedded)) }
        if corrected > 0 { self.changed(PdfAText.fontsCorrected(corrected)) }
    }

    private static func choose(_ font: PdfFont) -> (family: String, style: FontStyles) {
        var style: FontStyles = []
        if font.isBold { style.insert(.bold) }
        if font.isItalic { style.insert(.italic) }
        if let std = Standard14.find(font.name) {
            style = []
            if std.isBold { style.insert(.bold) }
            if std.isItalic { style.insert(.italic) }
            let family: String
            if std.name.hasPrefix("Helvetica") {
                family = "Arial"
            } else if std.name.hasPrefix("Times") {
                family = "Times New Roman"
            } else if std.name.hasPrefix("Courier") {
                family = "Courier New"
            } else {
                family = std.name
            }
            return (family, style)
        }
        let first = String(String.UnicodeScalarView(font.name.unicodeScalars.prefix { $0 != "-" && $0 != "," }))
        let name = first.replacingOccurrences(of: "PS", with: "", options: .literal).replacingOccurrences(of: "MT", with: "", options: .literal)
        return (!name.isEmpty ? name : generic(font), style)
    }

    private static func isSymbolic(_ font: PdfFont) -> Bool { Standard14.find(font.name)?.isSymbolic ?? false }

    private static func generic(_ font: PdfFont) -> String { font.isFixedPitch ? "Courier New" : font.isSerif ? "Times New Roman" : "Arial" }

    private func findFile(_ font: PdfFont, _ family: String, _ style: FontStyles) -> FontFile? {
        fonts?.find(family, style) ?? fonts?.find(Self.generic(font), style)
    }

    // One code point, or nil: a glyph for "fi" is not the one for "f", so text of several characters cannot be drawn from a single glyph.
    private static func singleCodePoint(_ text: String) -> Int? {
        let scalars = Array(text.unicodeScalars)
        return scalars.count == 1 ? Int(scalars[0].value) : nil
    }

    private static let unicodeCmaps = [(3, 10), (3, 1), (0, 0), (0, 1), (0, 2), (0, 3), (0, 4), (0, 6)]

    private static func isSymbolFile(_ file: FontFile) -> Bool {
        guard let tt = TrueTypeFont.tryParse(file.data, file.collectionIndex) else { return false }
        return tt.hasCmap(3, 0) && !unicodeCmaps.contains { tt.hasCmap($0.0, $0.1) }
    }

    // A font that cannot show every code the content uses is not replaced: an embedded font with .notdef in it would pass
    // the validator and still lose the text, so the original stays and is reported.
    private func embedSimple(_ font: PdfDictionary, _ pdfFont: PdfFont, _ used: SortedInts) throws -> Bool {
        let (family, style) = Self.choose(pdfFont)
        guard let file = findFile(pdfFont, family, style) else { return false }
        var unicode: [Int: String] = [:]
        let bare = pdfFont.hasToUnicode ? withoutToUnicode(font) : nil
        for code in 0..<256 {
            if code < 32 && !used.contains(code) { continue }
            if let text = Self.textOf(pdfFont, bare, [UInt8(code)]) { unicode[code] = text }
        }
        // A symbol file has glyphs at the code (or 0xF000 above it) of its own encoding whatever they stand for, so a code is looked up
        // under the code the font's built-in encoding gives its glyph name; any other file is asked for the text.
        let builtIn = Self.isSymbolic(pdfFont) && Self.isSymbolFile(file) ? Self.codesByName(Standard14.find(pdfFont.name)?.builtInEncoding) : nil
        var options: [Int: Int] = [:]
        for (code, text) in unicode.sorted(by: { $0.key < $1.key }) {
            if let builtIn {
                if let glyph = pdfFont.glyphNameOf(code), let own = builtIn[glyph] { options[code] = own }
            } else if let single = Self.singleCodePoint(text) {
                options[code] = single
            }
        }
        var wanted = String.UnicodeScalarView()
        for (_, codePoint) in options.sorted(by: { $0.key < $1.key }) {
            if let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: codePoint)) { wanted.append(scalar) }
        }
        guard !wanted.isEmpty, let built = EmbeddedFontBuilder.build(file.data, [String(wanted)], file.collectionIndex).font else { return false }

        var cidOf: [Int: Int] = [:]
        for (code, codePoint) in options {
            if let cid = built.codes[codePoint] { cidOf[code] = cid }
        }
        if used.contains(where: { cidOf[$0] == nil }) { return false }
        let map = CMapEntries(cidOf)
        let cidFont = try buildCidFont(built, pdfFont.name, Self.builtCids(built))
        let type0 = PdfDictionary()
        type0["Type"] = PdfName("Font")
        type0["Subtype"] = PdfName("Type0")
        type0["BaseFont"] = PdfName(built.baseFont)
        type0["Encoding"] = try document.add(map.toStream())
        let cidReference = try document.add(cidFont)
        type0["DescendantFonts"] = PdfArray([cidReference])
        type0["ToUnicode"] = try document.add(try toUnicodeStream(unicode, 1))
        Self.replace(font, type0)
        return true
    }

    private func embedComposite(_ font: PdfDictionary, _ cid: PdfDictionary, _ pdfFont: PdfFont, _ used: SortedInts) throws -> Bool {
        if !isIdentity(font) || document.name(cid, "Subtype") != "CIDFontType2" { return false }
        let (family, style) = Self.choose(pdfFont)
        guard let file = findFile(pdfFont, family, style) else { return false }
        var unicode: [Int: String] = [:]
        let bare = pdfFont.hasToUnicode ? withoutToUnicode(font) : nil
        for value in used {
            if let text = Self.textOf(pdfFont, bare, [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]), Self.singleCodePoint(text) != nil {
                unicode[value] = text
            }
        }
        if unicode.isEmpty || unicode.count != used.count { return false }
        let sorted = unicode.sorted { $0.key < $1.key }
        var all = ""
        for (_, text) in sorted { all += text }
        guard let built = EmbeddedFontBuilder.build(file.data, [all], file.collectionIndex).font, !built.isCff else { return false }
        if unicode.values.contains(where: { text in text.unicodeScalars.first.map { built.codes[Int($0.value)] == nil } ?? true }) { return false }

        var gid = [UInt8](repeating: 0, count: ((sorted.last?.key ?? 0) + 1) * 2)
        var widthOf: [Int: Int] = [:]
        for run in built.widths {
            for (i, width) in run.widths.enumerated() { widthOf[run.firstCid + i] = width }
        }
        var widths: [Int: Double] = [:]
        for (value, text) in sorted {
            guard let first = text.unicodeScalars.first, let code = built.codes[Int(first.value)] else { continue }
            gid[2 * value] = UInt8(truncatingIfNeeded: code >> 8)
            gid[2 * value + 1] = UInt8(truncatingIfNeeded: code)
            widths[value] = Double(widthOf[code] ?? 0)
        }
        let fresh = try buildCidFont(built, pdfFont.name, widths.keys.sorted())
        cid["BaseFont"] = PdfName(built.baseFont)
        if let descriptor = fresh["FontDescriptor"] { cid["FontDescriptor"] = descriptor }
        let toGid = PdfDictionary()
        toGid["Filter"] = PdfName("FlateDecode")
        cid["CIDToGIDMap"] = try document.add(PdfStream(toGid, data: PdfFilterEncoders.flate(gid)))
        cid["W"] = Self.widthArray(widths)
        font["BaseFont"] = PdfName(built.baseFont)
        if !pdfFont.hasToUnicode || toUnicodeGaps(font, pdfFont, used) { font["ToUnicode"] = try document.add(try toUnicodeStream(unicode, 2)) }
        return true
    }

    static func codesByName(_ encoding: [String?]?) -> [String: Int]? {
        guard let encoding else { return nil }
        var codes: [String: Int] = [:]
        for (code, name) in encoding.enumerated() {
            if let name, codes[name] == nil { codes[name] = code }
        }
        return codes
    }

    private static func builtCids(_ built: EmbeddedFont) -> SortedInts {
        let cids = SortedInts()
        for run in built.widths {
            for cid in run.firstCid..<(run.firstCid + run.widths.count) { cids.insert(cid) }
        }
        let tt = TrueTypeFont.tryParse(built.program)
        _ = addGlyphCids(cids, tt?.cff, tt, nil)
        return cids
    }

    // The CIDSet names the CIDs of the glyphs in the program, which for a subset include the parts of composite glyphs.
    private func buildCidFont(_ built: EmbeddedFont, _ name: String, _ cidSet: SortedInts) throws -> PdfDictionary {
        try buildCidFont(built, name, cidSet.sorted)
    }

    private func buildCidFont(_ built: EmbeddedFont, _ name: String, _ cidSet: [Int]) throws -> PdfDictionary {
        let fontFile = PdfDictionary()
        fontFile["Length1"] = PdfNumber(built.program.count)
        if built.isCff { fontFile["Subtype"] = PdfName("OpenType") }
        fontFile["Filter"] = PdfName("FlateDecode")
        let file = try document.add(PdfStream(fontFile, data: PdfFilterEncoders.flate(built.program)))

        let d = built.descriptor
        let descriptor = PdfDictionary()
        descriptor["Type"] = PdfName("FontDescriptor")
        descriptor["FontName"] = PdfName(built.baseFont)
        descriptor["Flags"] = PdfNumber(d.flags)
        descriptor["FontBBox"] = PdfArray(d.fontBBox.map { PdfNumber($0) as PdfObject })
        descriptor["ItalicAngle"] = PdfNumber(d.italicAngle)
        descriptor["Ascent"] = PdfNumber(d.ascent)
        descriptor["Descent"] = PdfNumber(d.descent)
        descriptor["CapHeight"] = PdfNumber(d.capHeight)
        descriptor["StemV"] = PdfNumber(d.stemV)
        descriptor[built.isCff ? "FontFile3" : "FontFile2"] = file
        if built.isSubset { descriptor["CIDSet"] = try document.add(Self.cidSetStream(cidSet + [0])) }

        var widths: [PdfObject] = []
        for run in built.widths {
            widths.append(PdfNumber(run.firstCid))
            widths.append(PdfArray(run.widths.map { PdfNumber($0) as PdfObject }))
        }
        let info = PdfDictionary()
        info["Registry"] = PdfString(bytes: Array("Adobe".utf8), isHex: false)
        info["Ordering"] = PdfString(bytes: Array("Identity".utf8), isHex: false)
        info["Supplement"] = PdfNumber(0)
        let cid = PdfDictionary()
        cid["Type"] = PdfName("Font")
        cid["Subtype"] = PdfName(built.isCff ? "CIDFontType0" : "CIDFontType2")
        cid["BaseFont"] = PdfName(built.baseFont)
        cid["CIDSystemInfo"] = info
        cid["FontDescriptor"] = try document.add(descriptor)
        cid["DW"] = PdfNumber(built.defaultWidth)
        cid["W"] = PdfArray(widths)
        if !built.isCff { cid["CIDToGIDMap"] = PdfName("Identity") }
        return cid
    }

    /// Puts the keys of `source` in `target` and takes the others out, so references to the font stay good.
    private static func replace(_ target: PdfDictionary, _ source: PdfDictionary) {
        for (key, _) in target.entries { target.remove(key) }
        for (key, value) in source.entries { target[key] = value }
    }

    private func toUnicodeStream(_ map: [Int: String], _ codeBytes: Int) throws -> PdfStream {
        let dictionary = PdfDictionary()
        dictionary["Filter"] = PdfName("FlateDecode")
        let entries = map.sorted { $0.key < $1.key }.filter { !$0.value.isEmpty }.map { (key: $0.key, value: $0.value) }
        return PdfStream(dictionary, data: PdfFilterEncoders.flate(try ToUnicodeCMap.write(entries, codeBytes: codeBytes)))
    }

    private static func widthArray(_ widths: [Int: Double]) -> PdfArray {
        var items: [PdfObject] = []
        var run: PdfArray?
        var next = -1
        for (cid, width) in widths.sorted(by: { $0.key < $1.key }) {
            let current: PdfArray
            if let known = run, cid == next {
                current = known
            } else {
                current = PdfArray([])
                items.append(PdfNumber(cid))
                items.append(current)
                run = current
            }
            current.items.append(PdfNumber((width * 1000).rounded(.toNearestOrEven) / 1000))
            next = cid + 1
        }
        return PdfArray(items)
    }

    // Widths the content shows are set to what the font program has, as the standard wants them to agree.
    func fixWidths(_ font: PdfDictionary, _ holder: PdfDictionary, _ pdfFont: PdfFont, _ used: SortedInts) -> Bool {
        if pdfFont.isType3 { return false }
        var fixes: [Int: Double] = [:]
        for key in used {
            let program = pdfFont.isComposite ? pdfFont.programCidWidth(key) : pdfFont.programWidth(key)
            let declared = pdfFont.isComposite ? pdfFont.cidWidths[key] ?? (document.number(holder, "DW") ?? 1000) : Self.readWidth(pdfFont, key)
            if let own = program, abs(own - declared) > 1 { fixes[key] = (own * 1000).rounded(.toNearestOrEven) / 1000 }
        }
        let missing = !pdfFont.isComposite && (!font.containsKey("Widths") || !font.containsKey("FirstChar"))
        if fixes.isEmpty && !missing { return false }
        if pdfFont.isComposite {
            var all = pdfFont.cidWidths
            for (cid, width) in fixes { all[cid] = width }
            holder["W"] = Self.widthArray(all)
            return true
        }
        let first = Swift.min(missing ? 32 : Swift.min(Swift.max(document.integer(font, "FirstChar") ?? 0, 0), 255), fixes.keys.min() ?? 255)
        let last = Swift.max(missing ? 255 : Swift.min(Swift.max(document.integer(font, "LastChar") ?? 255, 0), 255), fixes.keys.max() ?? 0)
        var widths: [PdfObject] = []
        if first <= last {
            for code in first...last {
                var width = fixes[code] ?? Self.readWidth(pdfFont, code)
                if missing && fixes[code] == nil, let own = pdfFont.programWidth(code) { width = own }
                widths.append(PdfNumber((width * 1000).rounded(.toNearestOrEven) / 1000))
            }
        }
        font["FirstChar"] = PdfNumber(first)
        font["LastChar"] = PdfNumber(last)
        font["Widths"] = PdfArray(widths)
        return true
    }

    private static func readWidth(_ font: PdfFont, _ code: Int) -> Double {
        font.read([UInt8(truncatingIfNeeded: code)][...]).character.width
    }

    // 6.2.11.7.2: every code the font shows needs text that is not U+0000, U+FEFF or U+FFFE.
    private static func hasText(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return !text.unicodeScalars.contains { $0.value == 0 || $0.value == 0xFEFF || $0.value == 0xFFFE }
    }

    private func wantsToUnicode(_ before: PdfAChecker, _ font: PdfDictionary, _ pdfFont: PdfFont, _ used: SortedInts) -> Bool {
        before.needsToUnicode(pdfFont) || level.needsUnicode() && pdfFont.hasToUnicode && toUnicodeGaps(font, pdfFont, used)
    }

    private func isIdentity(_ font: PdfDictionary) -> Bool {
        guard let name = document.resolve(font["Encoding"]) as? PdfName else { return false }
        return name.value == "Identity-H" || name.value == "Identity-V"
    }

    // The uses of a composite font are CIDs, which are its codes only under an Identity CMap. Under another the codes are found by reading
    // each of one and two bytes through the CMap, so a code of three or four bytes is not met.
    private func usedCodes(_ font: PdfDictionary, _ pdfFont: PdfFont, _ used: SortedInts) -> [[UInt8]] {
        if !pdfFont.isComposite { return used.map { [UInt8(truncatingIfNeeded: $0)] } }
        if isIdentity(font) { return used.map { [UInt8(truncatingIfNeeded: $0 >> 8), UInt8(truncatingIfNeeded: $0)] } }
        var codes: [[UInt8]] = []
        for first in 0..<256 {
            let a = UInt8(first)
            let one = pdfFont.read([a, 0, 0, 0][...])
            if one.used == 1 {
                if one.character.cid > 0 && used.contains(one.character.cid) { codes.append([a]) }
                continue
            }
            for second in 0..<256 {
                let two = pdfFont.read([a, UInt8(second), 0, 0][...])
                if two.used == 2 && two.character.cid > 0 && used.contains(two.character.cid) { codes.append([a, UInt8(second)]) }
            }
        }
        return codes
    }

    // The int of the bytes, which wraps past 31 bits as the C# fold does.
    private static func value(_ code: [UInt8]) -> Int {
        var value: Int32 = 0
        for b in code { value = (value &<< 8) | Int32(b) }
        return Int(value)
    }

    private func toUnicodeGaps(_ font: PdfDictionary, _ pdfFont: PdfFont, _ used: SortedInts) -> Bool {
        guard let stream = document.stream(font, "ToUnicode") else { return false }
        let map: CMap
        do {
            map = CMap.parse(try document.data(stream, 16 << 20))
        } catch {
            return true
        }
        return usedCodes(font, pdfFont, used).contains { code in
            !Self.hasText(map.unicodeOf(Self.value(code), length: code.count) ?? map.unicodeOf(Self.value(code), length: 0))
        }
    }

    // Level U: the codes the font shows get text the reader can trace, from the map the font has or else from its encoding. The map is
    // written again without the entries the standard rejects; a code left with no text is reported by reportUnicodeHoles.
    private func addToUnicode(_ font: PdfDictionary, _ pdfFont: PdfFont, _ used: SortedInts) throws -> Bool {
        let bare = pdfFont.hasToUnicode ? withoutToUnicode(font) : nil
        let codes = pdfFont.isComposite ? usedCodes(font, pdfFont, used) : (0..<256).map { [UInt8($0)] }
        var map: [Int: String] = [:]
        for code in codes {
            if let text = Self.textOf(pdfFont, bare, code) { map[Self.value(code)] = text }
        }
        if map.isEmpty { return font.remove("ToUnicode") }
        font["ToUnicode"] = try document.add(try toUnicodeStream(map, codes.map { $0.count }.max() ?? 1))
        return true
    }

    // The validator passes a font with a Latin encoding whatever codes the content shows and whatever its map holds, so a code with no text is reported here.
    func reportUnicodeHoles(_ font: PdfDictionary, _ used: SortedInts) {
        if !level.needsUnicode() { return }
        let current = snapshot(font)
        if usedCodes(font, current, used).contains(where: { Self.textOf(current, nil, $0) == nil }) {
            left.append(PdfAIssue("6.2.11.7.2", PdfAText.fontName(current.baseFont), PdfAText.noUnicode))
        }
    }

    // The text of a code from the font's /ToUnicode, or from its encoding where the map has none or a text the standard rejects.
    private static func textOf(_ font: PdfFont, _ bare: PdfFont?, _ code: [UInt8]) -> String? {
        var character = font.read(code[...]).character
        if !hasText(character.unicode), let bare { character = bare.read(code[...]).character }
        return hasText(character.unicode) ? character.unicode : nil
    }

    private func withoutToUnicode(_ font: PdfDictionary) -> PdfFont { snapshot(font, "ToUnicode") }

    // A copy, because a PdfFont keeps what it read from its dictionary the first time.
    func snapshot(_ font: PdfDictionary, _ without: String? = nil) -> PdfFont {
        let copy = PdfDictionary()
        for (key, value) in font.entries where key != without { copy[key] = value }
        return PdfFont.get(document, copy)
    }

    /// An embedded one-byte CMap sending each code to a CID: `cidchar` entries, 100 to a section.
    private struct CMapEntries {
        let cids: [Int: Int]

        init(_ cids: [Int: Int]) {
            self.cids = cids
        }

        func toStream() -> PdfStream {
            var sb = ""
            sb += "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
            sb += "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> def\n"
            sb += "/CMapName /LazyPDF-Byte def\n/CMapType 1 def\n"
            sb += "1 begincodespacerange\n<00> <FF>\nendcodespacerange\n"
            let sorted = cids.sorted { $0.key < $1.key }
            var at = 0
            while at < sorted.count {
                let section = sorted[at..<Swift.min(at + 100, sorted.count)]
                sb += "\(section.count) begincidchar\n"
                for (code, cid) in section {
                    var hex = String(code, radix: 16, uppercase: true)
                    while hex.count < 2 { hex = "0" + hex }
                    sb += "<\(hex)> \(cid)\n"
                }
                sb += "endcidchar\n"
                at += 100
            }
            sb += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"

            let dictionary = PdfDictionary()
            dictionary["Type"] = PdfName("CMap")
            dictionary["CMapName"] = PdfName("LazyPDF-Byte")
            let info = PdfDictionary()
            info["Registry"] = PdfString(bytes: Array("Adobe".utf8), isHex: false)
            info["Ordering"] = PdfString(bytes: Array("Identity".utf8), isHex: false)
            info["Supplement"] = PdfNumber(0)
            dictionary["CIDSystemInfo"] = info
            dictionary["Filter"] = PdfName("FlateDecode")
            return PdfStream(dictionary, data: PdfFilterEncoders.flate(Array(sb.utf8)))
        }
    }
}
