import Foundation

// Twin of windows/LazyPDF.Core/Signatures/SignatureScan.cs: signature dictionaries are found by their /ByteRange in
// the bytes themselves, not through the form, so a signature a later revision unhooked from its field is still
// seen. They are never in object streams (12.8.1).

/// A signature dictionary as it stands in the file bytes at `offset`, the start of its "n g obj".
struct FoundSignature {
    var number: Int
    var offset: Int
    var dictionary: PdfDictionary
}

enum SignatureScan {
    private static let maxFound = 512
    private static let headerReach = 1 << 20
    private static let key = Array("/ByteRange".utf8)

    static func find(_ file: [UInt8]) -> [FoundSignature] {
        var found: [FoundSignature] = []
        var seen = Set<Int>()
        let bytes = PdfArrayBytes(file)
        var from = 0
        while found.count < maxFound {
            guard let pos = file.indexOf(key, from: from) else { break }
            from = pos + key.count
            guard let start = objectStart(file, pos), seen.insert(start).inserted else { continue }
            do {
                let lexer = PdfLexer(bytes, position: start)
                let (number, _) = try lexer.readObjectHeader()
                if let dictionary = try lexer.readObject(allowStream: false) as? PdfDictionary, lexer.position > pos,
                   dictionary["ByteRange"] is PdfArray, (dictionary["Contents"] as? PdfString)?.isHex == true {
                    found.append(FoundSignature(number: number, offset: start, dictionary: dictionary))
                }
            } catch {
                // A "/ByteRange" inside stream data or a broken object is not a signature.
            }
        }
        return found
    }

    // The last "n g obj" before the dictionary.
    private static func objectStart(_ file: [UInt8], _ pos: Int) -> Int? {
        let low = max(0, pos - headerReach)
        var limit = pos
        let word = Array("obj".utf8)
        while true {
            var obj = limit - word.count
            while obj >= low && !file.hasPattern(word, at: obj) { obj -= 1 }
            if obj < low { return nil }
            var i = obj
            if i > low && file[i - 1] == UInt8(ascii: "d") { // endobj
                limit = obj
                continue
            }
            while i > low && PdfLexer.isWhiteSpace(Int(file[i - 1])) { i -= 1 }
            let generationEnd = i
            while i > low && file[i - 1] >= UInt8(ascii: "0") && file[i - 1] <= UInt8(ascii: "9") { i -= 1 }
            if i == generationEnd {
                limit = obj
                continue
            }
            while i > low && PdfLexer.isWhiteSpace(Int(file[i - 1])) { i -= 1 }
            let numberEnd = i
            while i > low && file[i - 1] >= UInt8(ascii: "0") && file[i - 1] <= UInt8(ascii: "9") { i -= 1 }
            if i == numberEnd {
                limit = obj
                continue
            }
            return i
        }
    }
}
