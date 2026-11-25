import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionSyntax.cs: the operators of ISO 32000-1 Annex A with the operands each
// takes, and nothing else. A viewer is free to read an operator with other operands, or one it does not know, in its own
// way, and what it draws from them is never looked at, so content that strays from this table is content that is not
// understood.

enum RedactionSyntax {
    private static let maxMove = Double(1 << 22)

    // n number, s string, N name, a array, d name or dictionary.
    private static let signatures: [String: [Unicode.Scalar]] = build([
        ("", "b B b* B* f F f* h n s S q Q BT ET T* W W* EMC"),
        ("n", "w J j M i Tc Tw Tz TL Tr Ts g G"),
        ("nn", "m l Td TD d0"),
        ("nnn", "rg RG"),
        ("nnnn", "v y re k K"),
        ("nnnnnn", "c cm Tm d1"),
        ("N", "ri gs Do sh cs CS BMC MP"),
        ("Nn", "Tf"),
        ("Nd", "BDC DP"),
        ("an", "d"),
        ("s", "Tj '"),
        ("nns", "\""),
        ("a", "TJ"),
    ])

    // What a Type 3 glyph procedure may hold: shapes, colours and the bitmaps of a bitmap font (9.6.5).
    private static let glyph = Set("d0 d1 q Q cm w J j M d i ri m l c v y h re S s f F f* B B* b b* n W W* g G rg RG k K BI".split(separator: " ").map(String.init))

    private static func build(_ groups: [(String, String)]) -> [String: [Unicode.Scalar]] {
        var table: [String: [Unicode.Scalar]] = [:]
        for (signature, operators) in groups {
            for name in operators.split(separator: " ").map(String.init) {
                precondition(table[name] == nil, "RedactionSyntax lists \(name) twice.")
                table[name] = Array(signature.unicodeScalars)
            }
        }
        return table
    }

    /// Colour spaces a page uses without naming them (8.6.5.6).
    static let defaults: [(category: String, name: String)] = [("ColorSpace", "DefaultGray"), ("ColorSpace", "DefaultRGB"), ("ColorSpace", "DefaultCMYK")]

    /// Whether `key` is absent or holds exactly six numbers (8.3.3): any other array is read as the identity by one viewer
    /// and cut short by another.
    static func isMatrix(_ document: PdfDocument, _ dictionary: PdfDictionary, _ key: String) -> Bool {
        if !dictionary.containsKey(key) { return true }
        guard let array = document.resolve(dictionary[key]) as? PdfArray, array.items.count == 6 else { return false }
        return array.items.allSatisfy { document.resolve($0) is PdfNumber }
    }

    static func inGlyph(_ name: String) -> Bool { glyph.contains(name) }

    static func knows(_ name: String) -> Bool {
        signatures[name] != nil || name == "sc" || name == "scn" || name == "SC" || name == "SCN" || name == "BI"
    }

    /// Whether the bytes are whole tokens, see `RedactionLexer`; `breaks` are the offsets where content streams were joined.
    static func whole(_ data: [UInt8], _ operations: [ContentOperation], _ breaks: [Int] = []) -> Bool {
        var ends: [Int: Int] = [:]
        for op in operations where op.operator == "BI" { ends[op.start] = op.end }
        return RedactionLexer.whole(data, ends, breaks)
    }

    static func valid(_ op: ContentOperation) -> Bool {
        if op.operator == "BI" { return op.operands.isEmpty && op.image != nil }
        if op.operator == "sc" || op.operator == "scn" || op.operator == "SC" || op.operator == "SCN" {
            // Only scn and SCN take a pattern name (8.6.8).
            let named = (op.operator == "scn" || op.operator == "SCN") && !op.operands.isEmpty && op.operands[op.operands.count - 1] is PdfName
            let numbers = op.operands.count - (named ? 1 : 0)
            return !op.operands.isEmpty && op.operands.prefix(numbers).allSatisfy { $0 is PdfNumber }
        }
        guard let signature = signatures[op.operator], signature.count == op.operands.count else { return false }
        for (i, kind) in signature.enumerated() {
            let operand = op.operands[i]
            let fits: Bool
            switch kind {
            case "n": fits = operand is PdfNumber
            case "s": fits = operand is PdfString
            case "N": fits = operand is PdfName
            case "d": fits = operand is PdfName || operand is PdfDictionary
            default: fits = operand is PdfArray
            }
            if !fits { return false }
        }
        switch op.operator {
        case "cm", "Tm": return reachable(op.operands.dropFirst(4))
        case "Td", "TD": return reachable(op.operands[...])
        case "TJ": return (op.operands[0] as? PdfArray)?.items.allSatisfy { $0 is PdfNumber || $0 is PdfString } ?? false
        case "d": return (op.operands[0] as? PdfArray)?.items.allSatisfy { $0 is PdfNumber } ?? false
        default: return true
        }
    }

    // The scan adds up moves in double and a viewer in 32-bit floats, which hold integers exactly only up to 2^24. Two large
    // moves that cancel land in different places, so a move that large is not understood. A scale may be as large as it
    // likes: it has no sum to lose.
    private static func reachable(_ moves: ArraySlice<PdfObject>) -> Bool {
        moves.allSatisfy { m in
            guard let n = m as? PdfNumber else { return false }
            return n.value > -maxMove && n.value < maxMove
        }
    }

    /// The resources an operation names, as (category, name).
    static func names(_ op: ContentOperation) -> [(category: String, name: String)] {
        if op.operands.count < (op.operator == "BDC" || op.operator == "DP" ? 2 : 1) && op.operator != "BI" { return [] }
        var operand: PdfObject?
        var category: String?
        switch op.operator {
        case "Do": (category, operand) = ("XObject", op.operands[0])
        case "gs": (category, operand) = ("ExtGState", op.operands[0])
        case "Tf": (category, operand) = ("Font", op.operands[0])
        case "sh": (category, operand) = ("Shading", op.operands[0])
        case "cs", "CS":
            if let name = op.operands[0] as? PdfName, !["DeviceGray", "DeviceRGB", "DeviceCMYK", "Pattern"].contains(name.value) {
                (category, operand) = ("ColorSpace", name)
            }
        case "sc", "scn", "SC", "SCN": (category, operand) = ("Pattern", op.operands[op.operands.count - 1])
        case "BDC", "DP": (category, operand) = ("Properties", op.operands[1])
        case "BI":
            if let image = op.image, let space = space(image) { (category, operand) = ("ColorSpace", space) }
        default: break
        }
        if let category, let name = operand as? PdfName { return [(category, name.value)] }
        return []
    }

    /// The colour space an inline image names, when it is not one of the device spaces that have abbreviations.
    private static func space(_ image: InlineImage) -> PdfName? {
        guard let name = (image.dictionary["CS"] ?? image.dictionary["ColorSpace"]) as? PdfName,
              !["G", "RGB", "CMYK", "DeviceGray", "DeviceRGB", "DeviceCMYK"].contains(name.value) else { return nil }
        return name
    }

    /// Whether the end of an inline image is the same in every reading. A filter is decoded to find the end, and the
    /// parser does not decode, so only unfiltered data is accepted: a viewer counts the samples, and the data must be as
    /// long as the dimensions say, with nothing but white space between it and the EI.
    static func fits(_ document: PdfDocument, _ op: ContentOperation, _ data: [UInt8], _ space: (String) -> PdfObject?) -> Bool {
        guard let image = op.image else { return false }
        if op.end < 2 || op.end > data.count || data[op.end - 2] != 0x45 || data[op.end - 1] != 0x49 { return false }
        let d = image.dictionary
        if d.containsKey("F") || d.containsKey("Filter") { return false }
        guard let width = (d["W"] ?? d["Width"]) as? PdfNumber, width.value > 0, width.value < 1e6,
              let height = (d["H"] ?? d["Height"]) as? PdfNumber, height.value > 0, height.value < 1e6 else { return false }
        var bits = 1, parts = 1
        if !(((d["IM"] ?? d["ImageMask"]) as? PdfBoolean)?.value == true) {
            guard let depth = (d["BPC"] ?? d["BitsPerComponent"]) as? PdfNumber, depth.value > 0, depth.value <= 16 else { return false }
            bits = Int(depth.value)
            parts = components(document, d["CS"] ?? d["ColorSpace"], space, 0)
        }
        // The C# multiplies unchecked in long; a product that does not fit is an image whose length no data can match.
        let row = Int(width.value).multipliedReportingOverflow(by: parts)
        let wide = row.partialValue.multipliedReportingOverflow(by: bits)
        let padded = wide.partialValue.addingReportingOverflow(7)
        let total = (padded.partialValue / 8).multipliedReportingOverflow(by: Int(height.value))
        if row.overflow || wide.overflow || padded.overflow || total.overflow { return false }
        let expected = total.partialValue
        if !(parts > 0 && image.data.count >= expected && image.data.count <= expected + 2) { return false }
        // A reader that looks for EI ends the image at one inside the data, whatever the dimensions say.
        return image.data[expected...].allSatisfy { $0 == 0 || $0 == 9 || $0 == 10 || $0 == 12 || $0 == 13 || $0 == 32 }
            && image.data.indexOf([0x45, 0x49]) == nil
    }

    private static func components(_ document: PdfDocument, _ space: PdfObject?, _ named: (String) -> PdfObject?, _ depth: Int) -> Int {
        if depth > 3 { return 0 }
        switch document.resolve(space) {
        case let name as PdfName:
            switch name.value {
            case "G", "DeviceGray": return 1
            case "RGB", "DeviceRGB": return 3
            case "CMYK", "DeviceCMYK": return 4
            default:
                guard let found = named(name.value) else { return 0 }
                return components(document, found, named, depth + 1)
            }
        case let array as PdfArray:
            guard let first = array.items.first, let kind = document.resolve(first) as? PdfName else { return 0 }
            let items = array.items
            switch kind.value {
            case "I", "Indexed", "CalGray", "Separation": return 1
            case "CalRGB", "Lab": return 3
            case "ICCBased":
                guard items.count > 1, let icc = document.resolve(items[1]) as? PdfStream else { return 0 }
                // (int)(long?? 0) of the C# truncates to 32 bits.
                return Int(Int32(truncatingIfNeeded: document.integer(icc.dictionary, "N") ?? 0))
            case "DeviceN":
                guard items.count > 1, let names = document.resolve(items[1]) as? PdfArray else { return 0 }
                return names.items.count
            default: return 0
            }
        default:
            return 0
        }
    }
}
