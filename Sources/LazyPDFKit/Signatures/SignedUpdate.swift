import Foundation

// Twin of windows/LazyPDF.Core/Signatures/SignedUpdate.cs: the signed update: the document's changes written as an
// incremental update with a zeroed /Contents and /ByteRange, then the byte range filled in, the file digested outside
// /Contents and the signature put in the gap.

enum SignedUpdate {
    private static let maxReserve = 1 << 21
    private static let byteRangeText = Array("[0 0000000000 0000000000 0000000000]".utf8)

    /// The ByteRange entry a signature dictionary starts with; `fill` overwrites its numbers in the written file.
    static func byteRangePlaceholder() -> PdfArray {
        PdfArray([PdfNumber(0), PdfNumber("0000000000"), PdfNumber("0000000000"), PdfNumber("0000000000")])
    }

    /// Writes the update for `document`, whose signature dictionary holds `contents` (the zero bytes that reserve the
    /// room), and returns the whole file with the signature in it. `sign` turns the digest of the signed ranges into
    /// the bytes of /Contents; the room grows when they do not fit.
    static func build(_ document: PdfDocument, _ contents: PdfString, _ digest: HashAlgorithmName, _ sign: ([UInt8]) throws -> [UInt8]) throws -> [UInt8] {
        while true {
            let (file, fits) = try fill(document, contents, digest, sign)
            if fits { return file }
            if contents.bytes.count >= maxReserve { throw InvalidOperationException(SignatureText.noRoom) }
            contents.bytes = [UInt8](repeating: 0, count: contents.bytes.count * 2)
        }
    }

    private static func fill(_ document: PdfDocument, _ contents: PdfString, _ digest: HashAlgorithmName,
                             _ sign: ([UInt8]) throws -> [UInt8]) throws -> (file: [UInt8], fits: Bool) {
        let update = try PdfUpdate.build(document)
        let source = document.source
        var file = source + update

        var hex = [UInt8](repeating: UInt8(ascii: "0"), count: contents.bytes.count * 2 + 2)
        hex[0] = UInt8(ascii: "<")
        hex[hex.count - 1] = UInt8(ascii: ">")
        guard let start = file.indexOf(hex, from: source.count), let rangeAt = file.indexOf(byteRangeText, from: source.count) else {
            throw InvalidOperationException("The signature placeholders were not written.")
        }
        let end = start + hex.count

        let range = String(format: "[0 %010ld %010ld %010ld]", start, end, file.count - end)
        file.replaceSubrange(rangeAt..<rangeAt + byteRangeText.count, with: Array(range.utf8))

        let signature = try sign(rangeDigest(file, start, end, digest))
        let fits = signature.count <= contents.bytes.count
        if fits {
            let text = Array(signature.map { String(format: "%02X", $0) }.joined().utf8)
            file.replaceSubrange(start + 1..<start + 1 + text.count, with: text)
        }
        return (file, fits)
    }

    static func rangeDigest(_ file: [UInt8], _ gapStart: Int, _ gapEnd: Int, _ algorithm: HashAlgorithmName) -> [UInt8] {
        SignatureCrypto.hash(algorithm, Array(file[0..<gapStart]) + Array(file[gapEnd...]))
    }
}
