import Foundation

// Twin of windows/LazyPDF.Core/Signatures/SignedRanges.cs: the byte range of a signature checked against the file:
// four numbers, the first range from 0, the gap exactly the hex string of /Contents in the signature's own object,
// the second range running to the end of a revision.

struct SignedRanges {
    var gapStart: Int
    var gapEnd: Int
    var end: Int
    var revision: PdfRevision
    var contents: [UInt8]

    private static let blankSlack = 8

    func digest(_ file: [UInt8], _ algorithm: HashAlgorithmName) -> [UInt8] {
        SignatureCrypto.hash(algorithm, Array(file[0..<gapStart]) + Array(file[gapEnd..<end]))
    }

    /// The ranges, or nil when they are not what a signature may cover.
    static func check(_ file: [UInt8], _ found: FoundSignature, _ revisions: [PdfRevision]) -> SignedRanges? {
        guard let array = found.dictionary["ByteRange"] as? PdfArray, array.items.count == 4 else { return nil }
        var numbers = [Int](repeating: 0, count: 4)
        for i in 0..<4 {
            guard let number = array.items[i] as? PdfNumber, number.isInteger, let value = number.integer, value >= 0 else { return nil }
            numbers[i] = value
        }
        if numbers.contains(where: { $0 > file.count }) { return nil }
        let a = numbers[1], b = numbers[2], end = numbers[2] + numbers[3]
        if numbers[0] != 0 || a <= found.offset || b <= a + 1 || end > file.count || end <= b - 1 { return nil }
        if file[a] != UInt8(ascii: "<") || file[b - 1] != UInt8(ascii: ">") { return nil }

        guard let decoded = decodeHex(Array(file[(a + 1)..<(b - 1)])), let declared = found.dictionary["Contents"] as? PdfString,
              declared.bytes == decoded else { return nil }
        if file.indexOf(Array("endobj".utf8), from: b) == nil { return nil }

        // The second range ends where a revision does, give or take the blank bytes around its "%%EOF" that
        // PdfRevisions leaves out or other tools add, and the signature's object is inside that revision and not an earlier one.
        for (i, revision) in revisions.enumerated() {
            let low = min(end, revision.end), high = max(end, revision.end)
            if high - low > blankSlack || !file[low..<high].allSatisfy({ PdfLexer.isWhiteSpace(Int($0)) }) { continue }
            let start = i == 0 ? 0 : revisions[i - 1].end
            if found.offset < start || found.offset >= end { return nil }
            return SignedRanges(gapStart: a, gapEnd: b, end: end, revision: revision, contents: decoded)
        }
        return nil
    }

    private static func decodeHex(_ hex: [UInt8]) -> [UInt8]? {
        if hex.count % 2 != 0 { return nil }
        var result = [UInt8](repeating: 0, count: hex.count / 2)
        for i in 0..<result.count {
            let high = nibble(hex[2 * i]), low = nibble(hex[2 * i + 1])
            if high < 0 || low < 0 { return nil }
            result[i] = UInt8(high << 4 | low)
        }
        return result
    }

    private static func nibble(_ c: UInt8) -> Int {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(c - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(c - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(c - UInt8(ascii: "A")) + 10
        default: return -1
        }
    }
}
