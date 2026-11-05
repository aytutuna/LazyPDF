import Foundation

// Twin of windows/LazyPDF.Core/Content/PdfFont.Composite.cs: Type 0 fonts, a CMap cuts the string into codes and
// gives each a CID, the descendant CIDFont gives the CID a width and a glyph (9.7).

extension PdfFont {
    private static let maxCid = 0xFFFF
    private static let maxWidthEntries = 300_000

    // Adobe's character collections, and the Unicode CMaps that reach their CIDs (the half-width one is where the
    // single-byte codes of the Shift-JIS CMaps go). The vertical ones come last: they add the CIDs of the vertical
    // forms, which the horizontal maps never reach.
    private static let unicodeCMaps: [String: [String]] = [
        "Japan1": ["UniJIS-UCS2-H", "UniJIS-UCS2-HW-H", "UniJIS-UCS2-V"],
        "GB1": ["UniGB-UCS2-H", "UniGB-UCS2-V"],
        "CNS1": ["UniCNS-UCS2-H", "UniCNS-UCS2-V"],
        "Korea1": ["UniKS-UCS2-H", "UniKS-UCS2-V"],
    ]

    // Built on first use, as the C# Lazy does, and shared by every font.
    private static let cidTablesLock = NSLock()
    private static var cidTables: [String: [Int: Int]] = [:]

    private static func cidToUnicode(_ ordering: String) -> [Int: Int]? {
        guard let names = unicodeCMaps[ordering] else { return nil }
        cidTablesLock.lock()
        defer { cidTablesLock.unlock() }
        if let known = cidTables[ordering] { return known }
        let built = invert(names.map { CMap.predefined($0) })
        cidTables[ordering] = built
        return built
    }

    private static func invert(_ unicodeMaps: [CMap]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for unicodeMap in unicodeMaps {
            for code in 0x20...0xFFFF {
                if let cid = unicodeMap.cidOf(code, length: 2), cid > 0, map[cid] == nil { map[cid] = code }
            }
        }
        return map
    }

    func initializeComposite(_ cidFont: PdfDictionary) {
        self.cidFont = cidFont
        switch document.resolve(dictionary["Encoding"]) {
        case let name as PdfName: cmap = CMap.predefined(name.value)
        case let stream as PdfStream: cmap = tryReadCMap(stream) ?? cmap
        default: break
        }
        isVertical = cmap.isVertical
        if let info = document.dict(cidFont, "CIDSystemInfo"), let value = document.resolve(info["Ordering"]) as? PdfString {
            ordering = Latin1.string(value.bytes)
        }
        defaultWidth = document.number(cidFont, "DW") ?? 1000
        if let dw2 = document.array(cidFont, "DW2"), dw2.items.count >= 2,
           let vy = document.resolve(dw2.items[0]) as? PdfNumber, let w1 = document.resolve(dw2.items[1]) as? PdfNumber {
            defaultOriginY = vy.value
            defaultAdvance = w1.value
        }
        if let w = document.array(cidFont, "W") { readWidths(w) }
        if let w2 = document.array(cidFont, "W2") { readVerticalMetrics(w2) }
    }

    private func tryReadCMap(_ stream: PdfStream) -> CMap? {
        do {
            return try readCMap(stream)
        } catch {
            return nil
        }
    }

    private func readCMap(_ stream: PdfStream) throws -> CMap {
        var parent: CMap?
        switch document.resolve(stream.dictionary["UseCMap"]) {
        case let name as PdfName: parent = CMap.predefined(name.value)
        case let inner as PdfStream where inner !== stream: parent = CMap.parse(try document.data(inner, 16 << 20))
        default: break
        }
        return CMap.parse(try document.data(stream, 16 << 20), useCMap: parent)
    }

    private func num(_ value: PdfObject?) -> Double? {
        if let number = document.resolve(value) as? PdfNumber, number.value.isFinite { return number.value }
        return nil
    }

    // 9.7.4.3: "c [w1 w2 ...]" or "cfirst clast w".
    private func readWidths(_ array: PdfArray) {
        let items = array.items
        var budget = Self.maxWidthEntries
        var i = 0
        while i < items.count && budget > 0 {
            guard let first = num(items[i]) else {
                i += 1
                continue
            }
            if i + 1 < items.count, let list = document.resolve(items[i + 1]) as? PdfArray {
                var k = 0
                while k < list.items.count && first + Double(k) <= Double(Self.maxCid) && budget > 0 {
                    budget -= 1
                    if let width = num(list.items[k]) { cidWidths[Int(saturating32: first) + k] = width }
                    k += 1
                }
                i += 2
            } else if i + 2 < items.count {
                if let last = num(items[i + 1]), let width = num(items[i + 2]) {
                    var c = Int(saturating: Swift.max(first, 0))
                    while Double(c) <= Swift.min(last, Double(Self.maxCid)) && budget > 0 {
                        budget -= 1
                        cidWidths[c] = width
                        c += 1
                    }
                }
                i += 3
            } else {
                break
            }
        }
    }

    // 9.7.4.3: "c [w1 vx vy ...]" or "cfirst clast w1 vx vy".
    private func readVerticalMetrics(_ array: PdfArray) {
        let items = array.items
        var budget = Self.maxWidthEntries
        var i = 0
        while i < items.count && budget > 0 {
            guard let first = num(items[i]) else {
                i += 1
                continue
            }
            if i + 1 < items.count, let list = document.resolve(items[i + 1]) as? PdfArray {
                var k = 0
                while k + 2 < list.items.count && first + Double(k / 3) <= Double(Self.maxCid) && budget > 0 {
                    budget -= 1
                    if let a = num(list.items[k]), let x = num(list.items[k + 1]), let y = num(list.items[k + 2]) {
                        cidVertical[Int(saturating32: first) + k / 3] = (a, x, y)
                    }
                    k += 3
                }
                i += 2
            } else if i + 4 < items.count {
                if let last = num(items[i + 1]), let a = num(items[i + 2]), let x = num(items[i + 3]), let y = num(items[i + 4]) {
                    var c = Int(saturating: Swift.max(first, 0))
                    while Double(c) <= Swift.min(last, Double(Self.maxCid)) && budget > 0 {
                        budget -= 1
                        cidVertical[c] = (a, x, y)
                        c += 1
                    }
                }
                i += 5
            } else {
                break
            }
        }
    }

    func readComposite(_ bytes: ArraySlice<UInt8>) -> (used: Int, character: FontChar) {
        var (code, length) = cmap.nextCode(bytes)
        if length <= 0 || length > bytes.count {
            length = 1
            code = Int(bytes[bytes.startIndex])
        }
        let key = (length << 32) | Int(UInt32(truncatingIfNeeded: code))
        if let known = composite[key] { return (length, known) }
        let cid = cmap.cidOf(code, length: length) ?? 0
        let width = cidWidths[cid] ?? defaultWidth
        let vertical = cidVertical[cid] ?? (defaultAdvance, width / 2, defaultOriginY)
        let character = FontChar(code: code, length: length, cid: cid, width: width, unicode: compositeUnicode(code, length, cid),
                                 isSpace: length == 1 && code == 32, verticalAdvance: vertical.advance, originX: vertical.x, originY: vertical.y)
        if composite.count < Self.maxCached { composite[key] = character }
        return (length, character)
    }

    private func compositeUnicode(_ code: Int, _ length: Int, _ cid: Int) -> String? {
        if let mapped = mappedText(code, length) { return mapped }
        if let name = cmap.name, name.hasPrefix("Uni"), let direct = cmap.unicodeOf(code, length: length), !direct.isEmpty { return direct }
        if cid == 0 { return nil }
        if let table = Self.cidToUnicode(ordering), let codePoint = table[cid] {
            guard let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: codePoint)) else { return nil }
            return String(scalar)
        }
        guard let program else { return nil }
        if let tt = program.trueType, tt.cff == nil {
            let gid = glyphOf(cid)
            return gid > 0 ? program.unicodeOf(gid) : nil
        }
        if let cff = program.cff {
            let gid = cff.isCid ? cff.glyphForCid(cid) : cid
            if gid > 0, let glyphName = cff.glyphName(gid) { return GlyphList.unicodeOf(glyphName) }
            return nil
        }
        return nil
    }

    // /CIDToGIDMap of a CIDFontType2: identity unless a stream says otherwise (9.7.4.2).
    func glyphOf(_ cid: Int) -> Int {
        if !cidToGidLoaded {
            cidToGidLoaded = true
            if let map = document.resolve(cidFont?["CIDToGIDMap"]) as? PdfStream {
                do {
                    let data = try document.data(map, 1 << 18)
                    var table: [UInt16] = []
                    table.reserveCapacity(data.count / 2)
                    var i = 0
                    while i + 1 < data.count {
                        table.append(UInt16(data[i]) << 8 | UInt16(data[i + 1]))
                        i += 2
                    }
                    cidToGid = table
                } catch {
                }
            }
        }
        guard let table = cidToGid else { return cid }
        // A negative CID can come out of a CMap range that wraps; the C# indexes with it.
        return cid >= 0 && cid < table.count ? Int(table[cid]) : 0
    }
}
