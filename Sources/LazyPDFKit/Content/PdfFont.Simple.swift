import Foundation

// Twin of windows/LazyPDF.Core/Content/PdfFont.Simple.cs: simple fonts, one byte a character, the encoding gives
// each code a glyph name (9.6.6).

extension PdfFont {
    private static let maxDifferences = 4096

    var names: [String?] {
        if let known = glyphNames { return known }
        let built = buildNames()
        glyphNames = built
        return built
    }

    func initializeSimple() {
        var scale = 1.0
        if isType3 {
            if let matrix = PdfMatrix.fromArray(document.array(dictionary, "FontMatrix"), { self.document.resolve($0) }), matrix.a != 0 { fontMatrix = matrix }
            scale = fontMatrix.a * 1000
            fontBBox = document.rect(dictionary, "FontBBox")
            if let box = fontBBox {
                ascent = box.top * fontMatrix.d * 1000
                descent = box.bottom * fontMatrix.d * 1000
            }
        }
        missingWidth = (document.number(descriptor, "MissingWidth") ?? 0) * scale
        firstChar = Swift.min(Swift.max(document.integer(dictionary, "FirstChar") ?? 0, 0), 255)
        if let array = document.array(dictionary, "Widths") {
            var list = [Double](repeating: 0, count: Swift.min(array.items.count, 256))
            for i in 0..<list.count {
                if let number = document.resolve(array.items[i]) as? PdfNumber, number.value.isFinite { list[i] = number.value * scale }
            }
            widths = list
        }
    }

    func readSimple(_ code: UInt8) -> (used: Int, character: FontChar) {
        let index = Int(code)
        if let known = simple[index] { return (1, known) }
        let width = simpleWidth(index)
        let made = FontChar(code: index, length: 1, cid: index, width: width, unicode: simpleUnicode(index), isSpace: index == 32,
                            verticalAdvance: -1000, originX: width / 2, originY: 880)
        simple[index] = made
        return (1, made)
    }

    private func simpleWidth(_ code: Int) -> Double {
        if let widths {
            let index = code - firstChar
            return index >= 0 && index < widths.count ? widths[index] : missingWidth
        }
        if isType3 { return missingWidth }
        let name = names[code]
        if let name, let standard = std14?.widthOf(name) { return Double(standard) }
        if let program {
            if let own = program.width(code, name) { return own }
            if let tt = program.trueType, tt.cff == nil {
                let gid = trueTypeGlyph(tt, code)
                if gid > 0 { return Double(tt.getAdvance(gid)) * 1000.0 / Double(tt.unitsPerEm) }
            }
        }
        // No widths and no font to ask: the metrics a viewer would substitute.
        if std14 == nil, let name, let substitute = self.substitute()?.widthOf(name) { return Double(substitute) }
        return missingWidth
    }

    private func substitute() -> Standard14? {
        let family = isFixedPitch ? "Courier" : isSerif ? "Times" : "Helvetica"
        return Standard14.find(isBold ? family + "-Bold" : family == "Times" ? "Times-Roman" : family)
    }

    private func simpleUnicode(_ code: Int) -> String? {
        if let mapped = mappedText(code, 1) { return mapped }
        let name = names[code]
        if let name, let fromName = GlyphList.unicodeOf(name) { return fromName }
        guard let program else { return nil }
        if let tt = program.trueType, tt.cff == nil {
            let gid = trueTypeGlyph(tt, code)
            return gid > 0 ? program.unicodeOf(gid) : nil
        }
        if let builtIn = program.builtInName(code) { return GlyphList.unicodeOf(builtIn) }
        return nil
    }

    // 9.6.6.4: a symbolic font's cmap is read by code, (3,0) at 0xF000 and up, or (1,0).
    func trueTypeGlyph(_ tt: TrueTypeFont, _ code: Int) -> Int {
        if let name = names[code], let text = GlyphList.unicodeOf(name), let first = text.unicodeScalars.first {
            let glyph = tt.glyphForCodePoint(Int(first.value))
            if glyph > 0 { return glyph }
        }
        var gid = tt.glyphForCmap(3, 0, code)
        if gid == 0 { gid = tt.glyphForCmap(3, 0, 0xF000 + code) }
        if gid == 0 { gid = tt.glyphForCmap(1, 0, code) }
        if gid == 0 { gid = tt.glyphForCodePoint(code) }
        return gid
    }

    private func buildNames() -> [String?] {
        var result = [String?](repeating: nil, count: 256)
        var table: [String?]?
        var differences: PdfArray?
        switch document.resolve(dictionary["Encoding"]) {
        case let encoding as PdfName:
            table = PdfEncodings.byName(encoding.value)
        case let encoding as PdfDictionary:
            if let baseName = document.name(encoding, "BaseEncoding") { table = PdfEncodings.byName(baseName) }
            differences = document.array(encoding, "Differences")
        default: break
        }
        table = table ?? defaultEncoding()
        if let table {
            for i in 0..<256 { result[i] = table[i] }
        }
        if let differences {
            var code = 0
            for item in differences.items.prefix(Self.maxDifferences) {
                switch document.resolve(item) {
                case let number as PdfNumber:
                    code = Int(saturating32: Swift.min(Swift.max(number.value, -1), 1000))
                case let glyph as PdfName:
                    if code >= 0 && code < 256 { result[code] = glyph.value }
                    code += 1
                default: break
                }
            }
        }
        return result
    }

    // 9.6.6.1: with no base encoding a symbolic or embedded font uses its own.
    private func defaultEncoding() -> [String?]? {
        if let standard = std14, standard.isSymbolic { return standard.builtInEncoding }
        if isEmbedded, let program, subtype != "TrueType" {
            var own = [String?](repeating: nil, count: 256)
            for i in 0..<256 { own[i] = program.builtInName(i) }
            if own.contains(where: { $0 != nil }) { return own }
        }
        if subtype == "TrueType" { return isSymbolic && isEmbedded ? nil : PdfEncodings.winAnsi }
        return PdfEncodings.standard
    }
}
