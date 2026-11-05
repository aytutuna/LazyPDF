import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Crypt/EncryptedFixture.cs: an encrypted fixture file reduced to what the
// security handler needs: /Encrypt, the first /ID and the page's content stream (object 4).

struct EncryptedFixture {
    let encrypt: PdfDictionary
    let id: [UInt8]
    let contentDictionary: PdfDictionary
    let content: [UInt8]

    static let plainContent = "1 0 0 rg 0 0 612 792 re f\n"

    static func load(_ name: String) throws -> EncryptedFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("Documents").appendingPathComponent(name)
        let bytes = [UInt8](try Data(contentsOf: url))
        let idAt = try XCTUnwrap(index(of: "/ID [ <", in: bytes), "\(name) has no /ID")
        let id = Hex.bytes(Latin1.string(Array(bytes[(idAt + 7)...].prefix { $0 != 0x3E })))
        let referenceAt = try XCTUnwrap(index(of: "/Encrypt ", in: bytes), "\(name) has no /Encrypt")
        let digits = bytes[(referenceAt + 9)...].prefix { $0 >= 0x30 && $0 <= 0x39 }
        let number = try XCTUnwrap(Int(Latin1.string(Array(digits))))
        let encrypt = try XCTUnwrap(try objectAt(bytes, number) as? PdfDictionary)
        let content = try XCTUnwrap(try objectAt(bytes, 4) as? PdfStream)
        let length = try XCTUnwrap((content.dictionary["Length"] as? PdfNumber)?.integer)
        return EncryptedFixture(encrypt: encrypt, id: id, contentDictionary: content.dictionary,
                                content: PdfArrayBytes(bytes).read(content.dataOffset, length))
    }

    private static func objectAt(_ bytes: [UInt8], _ number: Int) throws -> PdfObject {
        let at = try XCTUnwrap(index(of: "\n\(number) 0 obj", in: bytes)) + 1
        let lexer = PdfLexer(PdfArrayBytes(bytes), position: at)
        _ = try lexer.readObjectHeader()
        return try lexer.readObject()
    }

    private static func index(of text: String, in bytes: [UInt8]) -> Int? {
        let needle = Array(text.utf8)
        if bytes.count < needle.count { return nil }
        for i in 0...(bytes.count - needle.count) where bytes[i] == needle[0] && Array(bytes[i..<i + needle.count]) == needle {
            return i
        }
        return nil
    }
}
