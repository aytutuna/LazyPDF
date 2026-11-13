// Twin of windows/LazyPDF.Core/Text/BidiData.cs: Bidi_Class, paired brackets and mirroring from the tables in BidiTables.swift.

/// Bidi_Class values of UAX #9, in the order scripts/gen_bidi.py numbers them.
enum BidiType: UInt8 {
    case l, r, al, en, es, et, an, cs, nsm, bn, b, s, ws, on
    case lre, lro, rle, rlo, pdf, lri, rli, fsi, pdi
}

enum BidiData {
    static func typeOf(_ cp: Int) -> BidiType {
        if cp < 0 || cp > 0x10FFFF { return .l }
        var lo = 0
        var hi = ranges.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if Int(ranges[mid]) >> 5 <= cp { lo = mid } else { hi = mid - 1 }
        }
        return BidiType(rawValue: UInt8(ranges[lo] & 31)) ?? .l
    }

    /// The paired bracket of `cp`, with `opening` telling which end it is; 0 for any other character.
    static func pairedBracket(_ cp: Int) -> (bracket: Int, opening: Bool) {
        guard let i = find(brackets, 3, cp) else { return (0, false) }
        return (Int(brackets[i + 1]), brackets[i + 2] == 1)
    }

    /// The character whose glyph is the mirror image of `cp`, or `cp` when there is none.
    static func mirror(_ cp: Int) -> Int {
        guard let i = find(mirrors, 2, cp) else { return cp }
        return Int(mirrors[i + 1])
    }

    private static func find(_ table: [Int32], _ stride: Int, _ key: Int) -> Int? {
        var lo = 0
        var hi = table.count / stride - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let v = Int(table[mid * stride])
            if v == key { return mid * stride }
            if v < key { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }
}
