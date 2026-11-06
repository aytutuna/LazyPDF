import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAChecker.Fonts.cs: fonts (ISO 19005-1 6.3, 19005-2 6.2.11): embedding, subset
// sets, composite font parts, TrueType encodings and, for level U, a path to Unicode. Only fonts that show a glyph are held
// to these rules, and widths against the font program are compared as the glyphs are met in the content (noteGlyph).

extension PdfAChecker {
    static let latinEncodings = ["WinAnsiEncoding", "MacRomanEncoding", "MacExpertEncoding", "StandardEncoding"]

    func needsToUnicode(_ font: PdfFont) -> Bool { level.needsUnicode() && !font.hasToUnicode && !hasStandardText(font) }

    func checkFonts() {
        for font in fonts { checkFont(font) }
    }

    private func checkFont(_ font: PdfDictionary) {
        let subtype = document.name(font, "Subtype")
        let pdfFont = PdfFont.get(document, font)
        let place = PdfAText.fontName(pdfFont.baseFont)
        if needsToUnicode(pdfFont) { add(c("6.3.8", "6.2.11.7.2"), place, PdfAText.noUnicode) }
        if subtype == "Type3" { return }

        var holder = font
        if subtype == "Type0" {
            checkComposite(font, place)
            if let kids = document.array(font, "DescendantFonts"), let first = kids.items.first, let descendant = document.resolve(first) as? PdfDictionary {
                holder = descendant
            }
        }
        guard let descriptor = document.dict(holder, "FontDescriptor"),
              descriptor.containsKey("FontFile") || descriptor.containsKey("FontFile2") || descriptor.containsKey("FontFile3") else {
            // Parts 2 and later exempt a font that is only used with text rendering mode 3 (6.2.11.4.1).
            if isPart1 || renderedFonts.contains(ObjectIdentifier(font)) { add(c("6.3.4", "6.2.11.4.1"), place, PdfAText.fontNotEmbedded) }
            return
        }
        guard let program = FontProgram.load(document, descriptor) else {
            add(c("6.3.4", "6.2.11.4.1"), place, PdfAText.fontProgramUnreadable)
            return
        }
        if let file3 = document.stream(descriptor, "FontFile3") {
            // OpenType font files came with PDF 1.6.
            let kind = document.name(file3.dictionary, "Subtype")
            if !(kind == "Type1C" || kind == "CIDFontType0C" || (kind == "OpenType" && !isPart1)) {
                add(c("6.3.4", "6.2.11.4.1"), place, PdfAText.fontFileSubtype)
            }
        }

        checkSubsetSets(pdfFont, descriptor, holder, program, place)
        if subtype == "Type0" { return }
        if !font.containsKey("Widths") || !font.containsKey("FirstChar") { add(c("6.3.6", "6.2.11.5"), place, PdfAText.noWidths) }
        if subtype == "TrueType" { checkTrueTypeEncoding(font, descriptor, program, place) }
    }

    private func checkComposite(_ font: PdfDictionary, _ place: String) {
        let clause = c("6.3.3", "6.2.11.3")
        let encoding = document.resolve(font["Encoding"])
        let notKnown: Bool
        if let name = encoding as? PdfName {
            notKnown = CMap.predefined(name.value).isFallback
        } else {
            notKnown = !(encoding is PdfStream)
        }
        if notKnown { add(clause, place, PdfAText.cMapNotKnown) }
        guard let kids = document.array(font, "DescendantFonts"), let first = kids.items.first, let cid = document.resolve(first) as? PdfDictionary else { return }
        if document.dict(cid, "CIDSystemInfo") == nil { add(clause, place, PdfAText.noSystemInfo) }
        let embedded = document.dict(cid, "FontDescriptor")?.containsKey("FontFile2") == true
        if document.name(cid, "Subtype") == "CIDFontType2" && embedded && cid["CIDToGIDMap"] == nil {
            add(c("6.3.3.2", "6.2.11.3.2"), place, PdfAText.noCidToGid)
        }
    }

    // 6.3.5 / 6.2.11.4.2: a CIDSet or CharSet that is there lists every glyph the font program holds, the ones shown among them. Part 1
    // speaks of subsets only and asks for one in each; from part 2 any embedded font that has one is held to it.
    private func checkSubsetSets(_ pdfFont: PdfFont, _ descriptor: PdfDictionary, _ holder: PdfDictionary, _ program: FontProgram, _ place: String) {
        if isPart1 && !isSubset(descriptor, holder) { return }
        let used = uses(pdfFont.dictionary) ?? SortedInts()
        let clause = c("6.3.5", "6.2.11.4.2")
        let required = isPart1
        if holder !== pdfFont.dictionary {
            if let set = document.stream(descriptor, "CIDSet") {
                if !listsAll(set, used.sorted + programCids(holder, program)) { add(clause, place, PdfAText.cidSetIncomplete) }
            } else if required {
                add(clause, place, PdfAText.cidSetMissing)
            }
        } else if document.name(holder, "Subtype") == "Type1" || document.name(holder, "Subtype") == "MMType1" {
            guard let charSet = document.resolve(descriptor["CharSet"]) as? PdfString else {
                if required { add(clause, place, PdfAText.charSetMissing) }
                return
            }
            let listed = Set(Self.charSetNames(charSet))
            let shown = used.compactMap { pdfFont.glyphNameOf($0) }
            if (shown + programGlyphNames(program)).contains(where: { $0 != ".notdef" && !listed.contains($0) }) {
                add(clause, place, PdfAText.charSetIncomplete)
            }
        }
    }

    // The names a /CharSet lists: the text between the slashes, trimmed, the empty ones left out.
    static func charSetNames(_ charSet: PdfString) -> [String] {
        Latin1.string(charSet.bytes).unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
            .map { PdfDate.trimmed(String(String.UnicodeScalarView($0))) }.filter { !$0.isEmpty }
    }

    // A subset name starts with six capital letters and a plus sign (ISO 32000-1 9.6.4).
    private func isSubset(_ descriptor: PdfDictionary, _ holder: PdfDictionary) -> Bool {
        Self.isSubsetName(document.name(descriptor, "FontName") ?? document.name(holder, "BaseFont"))
    }

    static func isSubsetName(_ name: String?) -> Bool {
        guard let units = name.map({ Array($0.utf16) }), units.count > 7, units[6] == 0x2B else { return false }
        return units[0..<6].allSatisfy { $0 >= 0x41 && $0 <= 0x5A }
    }

    private func listsAll(_ set: PdfStream, _ cids: [Int]) -> Bool {
        do {
            let bits = try document.data(set, 1 << 20)
            return cids.allSatisfy { $0 >= 0 && ($0 >> 3) < bits.count && (Int(bits[$0 >> 3]) & (0x80 >> ($0 & 7))) != 0 }
        } catch {
            return false
        }
    }

    // The CIDs of the glyphs a program draws: the empty slots of a subset TrueType font do not count.
    private func programCids(_ cidFont: PdfDictionary, _ program: FontProgram) -> [Int] {
        var cids: [Int] = []
        if let cff = program.cff {
            for gid in stride(from: 1, to: cff.glyphCount, by: 1) { cids.append(cff.cidForGlyph(gid)) }
        } else if let tt = program.trueType {
            var map: [UInt8]?
            if let stream = document.resolve(cidFont["CIDToGIDMap"]) as? PdfStream {
                map = try? document.data(stream, 1 << 17)
            }
            if let map {
                var cid = 0
                while 2 * cid + 1 < map.count {
                    let gid = Int(map[2 * cid]) << 8 | Int(map[2 * cid + 1])
                    if gid > 0 && tt.glyphData(gid).length > 0 { cids.append(cid) }
                    cid += 1
                }
            } else {
                for gid in stride(from: 1, to: tt.glyphCount, by: 1) where tt.glyphData(gid).length > 0 { cids.append(gid) }
            }
        }
        return cids
    }

    private func programGlyphNames(_ program: FontProgram) -> [String] {
        if let type1 = program.type1 { return Array(type1.glyphNames.prefix(Self.maxFontCodes)) }
        if let cff = program.cff {
            let count = Swift.max(0, Swift.min(cff.glyphCount, Self.maxFontCodes) - 1)
            return (0..<count).map { cff.glyphName($0 + 1) ?? ".notdef" }
        }
        return []
    }

    // 6.3.7 / 6.2.11.6: a symbolic TrueType font has no /Encoding and a (3,0) or (1,0) cmap; the other kind names WinAnsi or MacRoman.
    private func checkTrueTypeEncoding(_ font: PdfDictionary, _ descriptor: PdfDictionary, _ program: FontProgram, _ place: String) {
        let clause = c("6.3.7", "6.2.11.6")
        let flags = document.integer(descriptor, "Flags") ?? 0
        let encoding = document.resolve(font["Encoding"])
        let baseName: String?
        switch encoding {
        case let name as PdfName: baseName = name.value
        case let dictionary as PdfDictionary: baseName = document.name(dictionary, "BaseEncoding")
        default: baseName = nil
        }
        let symbolic = (flags & 4) != 0 && (flags & 32) == 0
        if symbolic {
            if encoding != nil { add(clause, place, PdfAText.symbolicEncoding) }
            if let tt = program.trueType, !(tt.hasCmap(3, 0) || tt.hasCmap(1, 0)) { add(clause, place, PdfAText.symbolicCmap) }
        } else if baseName != "WinAnsiEncoding" && baseName != "MacRomanEncoding" {
            add(clause, place, PdfAText.trueTypeEncoding)
        }
    }

    private func hasStandardText(_ font: PdfFont) -> Bool {
        if font.isComposite {
            guard let name = document.resolve(font.dictionary["Encoding"]) as? PdfName, name.value != "Identity-H", name.value != "Identity-V" else { return false }
            return !CMap.predefined(name.value).isFallback
        }
        if font.isSymbolic { return false }
        switch document.resolve(font.dictionary["Encoding"]) {
        case let name as PdfName:
            return Self.latinEncodings.contains(name.value)
        case let encoding as PdfDictionary:
            if let baseName = document.name(encoding, "BaseEncoding"), !Self.latinEncodings.contains(baseName) { return false }
            let differences = (document.array(encoding, "Differences")?.items ?? []).compactMap { document.resolve($0) as? PdfName }
            return differences.allSatisfy { GlyphList.unicodeOf($0.value) != nil }
        default:
            return (font.flags & 32) != 0
        }
    }
}
