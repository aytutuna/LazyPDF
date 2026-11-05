import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfVersion.cs: one saved state of a file that was updated incrementally:
// the file cut at byte `end` is a complete PDF as it stood then. `number` counts from 1 for the oldest.

public struct PdfVersion: Equatable {
    public let number: Int
    public let end: Int

    public init(_ number: Int, _ end: Int) {
        self.number = number
        self.end = end
    }

    /// The versions in a document's bytes, oldest first: each cross-reference section the newest one leads
    /// back to, with the end of the "%%EOF" that closes it. A "%%EOF" counts only when the "startxref" before
    /// it names the section, so the first-page section of a linearized file, whose "startxref" is 0, is not a
    /// version. A rebuilt document has none.
    static func find(_ document: PdfDocument) -> [PdfVersion] {
        let bytes = document.source
        let startxref = "startxref".keywordBytes, eof = "%%EOF".keywordBytes
        var ends: [Int: Int] = [:]
        var from = 0
        while from < bytes.count {
            guard let at = bytes.indexOf(startxref, from: from) else { break }
            var pos = at + startxref.count
            from = pos
            var offset = 0
            while pos < bytes.count && PdfLexer.isWhiteSpace(Int(bytes[pos])) { pos += 1 }
            var digits = 0
            while pos < bytes.count && bytes[pos] >= 0x30 && bytes[pos] <= 0x39 && digits < 15 {
                digits += 1
                offset = offset * 10 + Int(bytes[pos] - 0x30)
                pos += 1
            }
            while pos < bytes.count && PdfLexer.isWhiteSpace(Int(bytes[pos])) { pos += 1 }
            if digits == 0 || !bytes.hasPattern(eof, at: pos) { continue }
            pos += eof.count
            if pos < bytes.count && bytes[pos] == 13 { pos += 1 }
            if pos < bytes.count && bytes[pos] == 10 { pos += 1 }
            ends[offset] = pos
        }

        var versions: [PdfVersion] = []
        for section in document.sectionOffsets.reversed() {
            if let end = ends[section], versions.last.map({ end > $0.end }) ?? true {
                versions.append(PdfVersion(versions.count + 1, end))
            }
        }
        return versions
    }
}
