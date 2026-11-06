import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAChecker.File.cs: file structure: header, trailer, cross-reference form and the
// syntax of streams (ISO 19005-1 6.1, 19005-2 6.1). These look at the bytes, because the reader tolerates what the
// standard does not.

extension PdfAChecker {
    func checkFile() {
        let data = document.source
        if document.repairs.contains(where: { $0.hasPrefix("Cut ") }) { add("6.1.2", PdfAText.header, PdfAText.bytesBeforeHeader) }
        checkHeader(data)
        checkTrailer(data)
        if Self.hasBadHexString(data) { add("6.1.6", PdfAText.trailer, PdfAText.hexString) }
        if document.xrefRebuilt { add("6.1.4", PdfAText.xref, PdfAText.xrefDamaged) }
        if isPart1 {
            if document.xrefIsStream { add("6.1.4", PdfAText.xref, PdfAText.xrefStream) }
            if document.entries.values.contains(where: { $0.kind == .compressed }) { add("6.1.4", PdfAText.xref, PdfAText.objectStreams) }
        } else {
            checkObjectStreams()
        }
    }

    // Nothing refers to an object stream as a value, so the walk of the objects never meets one; the strings in it are read here.
    // The streams are taken in the order the file lists their members, as the C# walks its entries.
    private func checkObjectStreams() {
        var listed = Set<Int>()
        let numbers = document.entryOrder.compactMap { document.entries[$0] }.filter { $0.kind == .compressed }.map { $0.streamNumber }.filter { listed.insert($0).inserted }
        for number in numbers {
            if overBudget { return }
            guard let stream = document.get(number) as? PdfStream else { continue }
            do {
                let data = try document.data(stream, Self.maxStreamBytes)
                work += data.count
                if Self.hasBadHexString(data) { add("6.1.6", PdfAText.objectName(number), PdfAText.hexString) }
            } catch {
            }
        }
    }

    private func checkHeader(_ data: [UInt8]) {
        guard let eol = data.firstIndex(where: { $0 == 10 || $0 == 13 }), eol <= 32 else {
            add("6.1.2", PdfAText.header, PdfAText.headerMissing)
            return
        }
        let version = PdfDate.trimmed(Latin1.string(Array(data[Swift.min(5, eol)..<eol])))
        let digits = Array(version.unicodeScalars)
        let good: Bool
        if part == 4 {
            good = version == "2.0"
        } else {
            good = digits.count == 3 && digits[0] == "1" && digits[1] == "." && digits[2].value >= 0x30 && digits[2].value <= 0x37
        }
        if !good { add("6.1.2", PdfAText.header, part == 4 ? PdfAText.headerVersion4(version) : PdfAText.headerVersion(version)) }

        let next = eol + (data[eol] == 13 && eol + 1 < data.count && data[eol + 1] == 10 ? 2 : 1)
        let binary = next + 5 <= data.count && data[next] == UInt8(ascii: "%") && data[(next + 1)..<(next + 5)].allSatisfy { $0 > 127 }
        if !binary { add("6.1.2", PdfAText.header, PdfAText.headerComment) }
    }

    private func checkTrailer(_ data: [UInt8]) {
        if let eof = data.lastIndexOf(Array("%%EOF".utf8)) {
            let tail = Array(data[(eof + 5)...])
            if !(tail.isEmpty || tail == [10] || tail == [13] || tail == [13, 10]) { add("6.1.3", PdfAText.trailer, PdfAText.dataAfterEof) }
        } else {
            add("6.1.3", PdfAText.trailer, PdfAText.noEof)
        }
        let ids = document.id
        if ids.count < 2 || ids.contains(where: { $0.isEmpty }) { add("6.1.3", PdfAText.trailer, PdfAText.noId) }
        if document.isEncrypted { add("6.1.3", PdfAText.trailer, PdfAText.encrypted) }
    }

    /// The keyword line before the data and the bytes after it (6.1.7 in part 1, 6.1.7.1 in part 2).
    func checkStreamSyntax(_ stream: PdfStream, _ place: @autoclosure () -> String) {
        let data = document.source
        let start = stream.dataOffset
        if start < 0 || start > data.count { return }
        let keyword = start >= 2 && data[start - 1] == 10 ? (data[start - 2] == 13 ? start - 2 : start - 1) : -1
        if keyword < 6 || Array(data[(keyword - 6)..<keyword]) != Array("stream".utf8) { add("6.1.7", place(), PdfAText.streamKeyword) }

        guard let declared = document.integer(stream.dictionary, "Length"), declared >= 0, declared <= data.count - start else {
            add("6.1.7", place(), PdfAText.streamLength)
            return
        }
        let end = start + declared
        let after: Int
        if end < data.count && data[end] == 13 {
            after = end + 1 < data.count && data[end + 1] == 10 ? end + 2 : end + 1
        } else if end < data.count && data[end] == 10 {
            after = end + 1
        } else {
            after = end
        }
        if after == end || !data.hasPattern(Array("endstream".utf8), at: after) { add("6.1.7", place(), PdfAText.streamLength) }
    }

    // 6.1.6: a hex string has an even number of hex digits and nothing but white space besides. The parser drops the difference, so this
    // reads the bytes outside the stream data. In a content stream, given as its parsed operations, the data of an inline image is skipped to where the parser found its end.
    static func hasBadHexString(_ data: [UInt8], _ content: [ContentOperation]? = nil) -> Bool {
        var images = (content ?? []).filter { $0.image != nil }.makeIterator()
        let imagesGiven = content != nil
        let stream = Array("stream".utf8), endstream = Array("endstream".utf8), imageData = Array("ID".utf8)
        var i = 0
        while i < data.count {
            let c = data[i]
            if c == UInt8(ascii: "%") {
                while i < data.count && data[i] != 10 && data[i] != 13 { i += 1 }
            } else if c == UInt8(ascii: "(") {
                var depth = 0
                while i < data.count {
                    if data[i] == UInt8(ascii: "\\") {
                        i += 1
                    } else if data[i] == UInt8(ascii: "(") {
                        depth += 1
                    } else if data[i] == UInt8(ascii: ")") {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    i += 1
                }
            } else if c == UInt8(ascii: "<") && i + 1 < data.count && data[i + 1] == UInt8(ascii: "<") {
                i += 1
            } else if c == UInt8(ascii: "<") {
                var digits = 0
                i += 1
                while i < data.count && data[i] != UInt8(ascii: ">") {
                    if isHexDigit(data[i]) {
                        digits += 1
                    } else if !(data[i] == 0 || data[i] == 9 || data[i] == 10 || data[i] == 12 || data[i] == 13 || data[i] == 32) {
                        return true
                    }
                    i += 1
                }
                if digits % 2 != 0 { return true }
            } else if isRegular(c) || c == UInt8(ascii: "/") {
                let from = c == UInt8(ascii: "/") ? i + 1 : i
                var end = from
                while end < data.count && isRegular(data[end]) { end += 1 }
                let word = data[from..<end]
                if c != UInt8(ascii: "/") && word.elementsEqual(stream) {
                    end = data.indexOf(endstream, from: end) ?? data.count
                } else if imagesGiven && c != UInt8(ascii: "/") && word.elementsEqual(imageData), let image = images.next() {
                    end = Swift.max(end, Swift.min(image.end, data.count))
                }
                i = Swift.max(i, end - 1)
            }
            i += 1
        }
        return false
    }

    private static func isHexDigit(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }

    private static func isRegular(_ c: UInt8) -> Bool {
        switch c {
        case 0, 9, 10, 12, 13, 32, 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return false
        default: return true
        }
    }
}
