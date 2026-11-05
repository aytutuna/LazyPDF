import Foundation

// Twin of windows/LazyPDF.Core/Signatures/PdfRevisions.cs: the revisions of a file found by their "%%EOF" lines, not
// by following the cross-reference chain: a "startxref" that names the start of a cross-reference table or stream and
// is closed by "%%EOF" ends a revision. The first-page section of a linearized file (offset 0) and such lines inside
// stream data do not count.

/// One saved state of a file: the bytes up to `end` are a complete PDF as it stood then. `number` counts from 1.
public struct PdfRevision: Equatable {
    public let number: Int
    public let end: Int

    public init(_ number: Int, _ end: Int) {
        self.number = number
        self.end = end
    }
}

public enum PdfRevisions {
    private static let maxRevisions = 100_000

    /// The revisions, oldest first. Empty when the bytes hold no complete one.
    public static func list(_ file: [UInt8]) -> [PdfRevision] {
        var ends: [Int] = []
        var from = 0
        let keyword = Array("startxref".utf8)
        let eof = Array("%%EOF".utf8)
        while ends.count < maxRevisions {
            guard let at = file.indexOf(keyword, from: from) else { break }
            var pos = at + keyword.count
            from = pos
            while pos < file.count && PdfLexer.isWhiteSpace(Int(file[pos])) { pos += 1 }
            var offset = 0
            var digits = 0
            while pos < file.count && file[pos] >= UInt8(ascii: "0") && file[pos] <= UInt8(ascii: "9") {
                let before = digits
                digits += 1
                if before >= 12 { break }
                offset = offset * 10 + Int(file[pos] - UInt8(ascii: "0"))
                pos += 1
            }
            while pos < file.count && PdfLexer.isWhiteSpace(Int(file[pos])) { pos += 1 }
            if digits == 0 || offset <= 0 || offset >= file.count || !file.hasPattern(eof, at: pos) { continue }
            if !startsSection(file, offset) { continue }
            pos += eof.count
            if pos < file.count && file[pos] == 13 { pos += 1 }
            if pos < file.count && file[pos] == 10 { pos += 1 }
            if ends.isEmpty || pos > ends[ends.count - 1] { ends.append(pos) }
        }
        return ends.enumerated().map { PdfRevision($0.offset + 1, $0.element) }
    }

    /// The file cut at the end of `revision`.
    public static func extract(_ file: [UInt8], _ revision: PdfRevision) -> [UInt8] {
        precondition(revision.end <= file.count, "revision")
        return Array(file[0..<revision.end])
    }

    // A table starts with "xref", a stream with "n g obj".
    private static func startsSection(_ file: [UInt8], _ offset: Int) -> Bool {
        var start = offset
        while start < file.count && PdfLexer.isWhiteSpace(Int(file[start])) { start += 1 }
        if file.hasPattern(Array("xref".utf8), at: start) { return true }
        let lexer = PdfLexer(PdfArrayBytes(file), position: start)
        do {
            _ = try lexer.readObjectHeader()
            guard let dictionary = try lexer.readObject(allowStream: false) as? PdfDictionary else { return false }
            return (dictionary["Type"] as? PdfName)?.value == "XRef"
        } catch {
            return false
        }
    }
}
