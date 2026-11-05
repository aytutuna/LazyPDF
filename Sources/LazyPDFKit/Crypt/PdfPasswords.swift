import Foundation

// Twin of windows/LazyPDF.Core/Crypt/PdfPasswords.cs: how typed passwords become the bytes the security handler
// hashes. The preparation is from Lazy Scan's PdfEncryption.cs.

enum PdfPasswords {
    /// A password is at most this many bytes once prepared (ISO 32000-2 7.6.4.3.3).
    static let maxBytes = 127

    /// R 5 and 6: SASLprep (RFC 4013). Other spaces become U+0020, characters mapped to nothing are
    /// dropped, the rest is NFKC normalized and cut at `maxBytes` bytes of UTF-8.
    static func prepare(_ password: String) -> [UInt8] {
        cut(mapped(password).precomposedStringWithCompatibilityMapping)
    }

    /// The bytes Apple's PDFKit passes on: `prepare` with NFKD in place of NFKC.
    static func decompose(_ password: String) -> [UInt8] {
        cut(mapped(password).decomposedStringWithCompatibilityMapping)
    }

    /// R 2 to 4 take the password as PDFDocEncoding bytes; Latin-1 stands for it, UTF-8 for text outside it.
    static func legacy(_ password: String) -> [UInt8] {
        password.utf16.allSatisfy { $0 < 256 } ? Latin1.bytes(password) : Array(password.utf8)
    }

    private static func mapped(_ password: String) -> String {
        var mapped = String.UnicodeScalarView()
        for scalar in password.unicodeScalars {
            let c = scalar.value
            if isNonAsciiSpace(c) {
                mapped.append(" ")
            } else if !mapsToNothing(c) {
                mapped.append(scalar)
            }
        }
        return String(mapped)
    }

    private static func cut(_ text: String) -> [UInt8] {
        let utf8 = Array(text.utf8)
        return utf8.count <= maxBytes ? utf8 : Array(utf8.prefix(maxBytes))
    }

    private static func isNonAsciiSpace(_ c: UInt32) -> Bool {
        c == 0x00A0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200B) || c == 0x202F || c == 0x205F || c == 0x3000
    }

    private static func mapsToNothing(_ c: UInt32) -> Bool {
        c == 0x00AD || c == 0x034F || c == 0x1806 || (c >= 0x180B && c <= 0x180D) || c == 0x200C || c == 0x200D
            || c == 0x2060 || (c >= 0xFE00 && c <= 0xFE0F) || c == 0xFEFF
    }
}
