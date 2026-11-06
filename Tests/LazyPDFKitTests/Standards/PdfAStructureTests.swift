import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAStructureTests.cs: the same cases.

final class PdfAStructureTests: XCTestCase {
    private let binary = "%\u{E2}\u{E3}\u{CF}\u{D3}\n"

    func test_aCompliantFilePassesEveryPart() throws {
        for level in [PdfALevel.a1b, .a2b, .a2u, .a3b, .a3u, .a4] {
            try StandardsKit.assertClean(StandardsKit.compliant(level), level)
        }
    }

    func test_aHeaderVersionOutsideTheRangeIsReported() throws {
        let file = StandardsKit.compliant(header: "%PDF-1.9\n" + binary)
        StandardsKit.assertContains(try StandardsKit.clauses(file), "6.1.2")
        StandardsKit.assertLacks(try StandardsKit.clauses(StandardsKit.compliant(header: "%PDF-1.3\n" + binary)), "6.1.2")
    }

    func test_aHeaderWithoutTheBinaryCommentIsReported() throws {
        let issues = try StandardsKit.check(StandardsKit.compliant(header: "%PDF-1.7\n")).issues
        StandardsKit.assertHas(issues) { $0.clause == "6.1.2" && $0.where == "File header" }
    }

    func test_part4NeedsAHeaderOfVersion2() throws {
        try StandardsKit.assertClean(StandardsKit.compliant(.a4), .a4)
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(.a2b), .a4), "6.1.2")
    }

    func test_dataAfterTheLastEofIsReportedButOneLineBreakIsNot() throws {
        let good = StandardsKit.compliant()
        StandardsKit.assertLacks(try StandardsKit.clauses(good), "6.1.3")
        StandardsKit.assertContains(try StandardsKit.clauses(good + Array("junk".utf8)), "6.1.3")
        StandardsKit.assertContains(try StandardsKit.clauses(good + [10, 10]), "6.1.3")
    }

    func test_aTrailerWithoutAnIdIsReported() throws {
        let pdf = TestPdf("%PDF-1.7\n" + binary)
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [] /Count 0>>")
        let issues = try StandardsKit.check(pdf.finish()).issues
        StandardsKit.assertHas(issues) { $0.clause == "6.1.3" && $0.message.contains("/ID") }
    }

    func test_anEncryptedFileIsReported() throws {
        let id = [UInt8](repeating: 0, count: 16)
        let security = PdfSecurity.create(userPassword: "u", ownerPassword: "o", permissions: .all, strength: .aes256, firstId: id)
        let file = try StandardsKit.edited(StandardsKit.compliant()) { _ in }
        let document = try PdfDocument.open(file)
        let locked = try document.saveRewrite(PdfSaveOptions(security: security, documentId: id))
        let again = try PdfDocument.open(locked, password: "u")
        StandardsKit.assertHas(PdfAValidator.validate(again, .a2b).issues) { $0.clause == "6.1.3" && $0.message.contains("encrypted") }
    }

    func test_aStreamKeywordFollowedByACarriageReturnAloneIsReported() throws {
        let file = StandardsKit.compliant()
        let at = try XCTUnwrap(file.indexOf(Array("stream\n0 0 1 rg".utf8)))
        var broken = file
        broken[at + 6] = 13
        StandardsKit.assertHas(try StandardsKit.check(broken).issues) { $0.clause == "6.1.7" && $0.message.contains("CRLF") }
    }

    func test_aStreamLengthThatDoesNotMatchIsReported() throws {
        let text = StandardsKit.latin(StandardsKit.compliant())
        let length = "0 0 1 rg 20 20 100 100 re f".count
        let broken = text.replacingOccurrences(of: "/Length \(length)", with: "/Length \(length - 1)", options: .literal)
        StandardsKit.assertHas(try StandardsKit.check(StandardsKit.bytes(broken)).issues) { $0.clause == "6.1.7" && $0.message.contains("/Length") }
    }

    func test_forbiddenStreamKeysAndFiltersAreReported() throws {
        let file = try StandardsKit.edited(StandardsKit.compliant()) { d in
            let content = try XCTUnwrap(d.resolve(d.pages[0].dictionary["Contents"]) as? PdfStream)
            content.dictionary["F"] = PdfString(bytes: Array("a.txt".utf8), isHex: false)
            content.data = PdfFilterEncoders.lzw(Array("0 0 1 rg 20 20 100 100 re f".utf8))
            content.dictionary["Filter"] = PdfName("LZWDecode")
        }
        let issues = try StandardsKit.check(file).issues
        StandardsKit.assertHas(issues) { $0.clause == "6.1.7" && $0.message.contains("/F") }
        StandardsKit.assertHas(issues) { $0.clause == "6.1.7.2" && $0.message.contains("LZW") }
        StandardsKit.assertHas(try StandardsKit.check(file, .a1b).issues) { $0.clause == "6.1.10" && $0.message.contains("LZW") }
    }

    func test_objectStreamsAreOnlyAllowedFromPart2() throws {
        let document = try PdfDocument.open(StandardsKit.compliant())
        let packed = try document.saveRewrite(PdfSaveOptions(useObjectStreams: true))
        StandardsKit.assertContains(try StandardsKit.clauses(packed, .a1b), "6.1.4")
        StandardsKit.assertLacks(try StandardsKit.clauses(packed, .a2b), "6.1.4")
    }

    func test_implementationLimitsAreReported() throws {
        let longName = String(repeating: "a", count: 130)
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(catalog: "/Key /\(longName)")), "6.1.13")
        let nested = String(repeating: "q ", count: 29) + String(repeating: "Q ", count: 29)
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(content: nested)), "6.1.13")
        StandardsKit.assertLacks(try StandardsKit.clauses(StandardsKit.compliant(content: String(repeating: "q ", count: 28) + String(repeating: "Q ", count: 28))), "6.1.13")
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(catalog: "/Big 3000000000")), "6.1.13")
    }

    func test_aDamagedCrossReferenceTableIsReported() throws {
        let file = StandardsKit.compliant()
        let start = try XCTUnwrap(file.lastIndexOf(Array("startxref\n".utf8)))
        let broken = Array(file[..<(start + 10)]) + Array("9999\n%%EOF\n".utf8)
        StandardsKit.assertContains(try StandardsKit.clauses(broken), "6.1.4")
    }
}
