import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactFinderTests.cs: the same cases.

final class RedactFinderTests: XCTestCase {
    private func lines(_ lines: String...) throws -> PdfDocument {
        let content = lines.enumerated().map { "BT /F1 11 Tf 50 \(750 - 30 * $0.offset) Td (\($0.element)) Tj ET" }.joined(separator: " ")
        return try RedactionKit.page(content)
    }

    private func found(_ document: PdfDocument, _ kind: RedactionKind) throws -> [String] {
        try RedactionFinder.find(document, kind).map { $0.text }
    }

    func test_emails() throws {
        let document = try lines("Write to jane.doe+tag@example.co.uk now", "not an address: @example.com or jane@", "bob@x.org.")
        XCTAssertEqual(try found(document, .email), ["jane.doe+tag@example.co.uk", "bob@x.org"])
    }

    func test_phones() throws {
        let document = try lines("Call +90 532 123 45 67 today", "Office (212) 555-0147", "Not one: 2024-03-15 or 1234", "Plain 0532 123 4567")
        let hits = try found(document, .phone)
        XCTAssertTrue(hits.contains("+90 532 123 45 67"))
        XCTAssertTrue(hits.contains("(212) 555-0147"))
        XCTAssertTrue(hits.contains("0532 123 4567"))
        XCTAssertFalse(hits.contains { $0.contains("2024") })
        XCTAssertEqual(hits.count, 3)
    }

    func test_usSocialSecurityNumbersKeepTheirRules() throws {
        let document = try lines("SSN 123-45-6789 ok", "Bad 000-12-3456 and 666-12-3456 and 123-00-6789 and 123-45-0000 and 912-34-5678")
        XCTAssertEqual(try found(document, .usSocialSecurity), ["123-45-6789"])
    }

    func test_turkishIdNumbersNeedTheirChecksum() throws {
        let document = try lines("T.C. 10000000146 ge\u{E7}erli", "Hatal\u{FD} 10000000147 ve 01234567890 ve 123456789012")
        XCTAssertEqual(try found(document, .turkishId), ["10000000146"])
    }

    func test_ibansAreCheckedModNinetySevenAndCutWhereTheNumberEnds() throws {
        let document = try lines("IBAN TR33 0006 1005 1978 6457 8413 26 hesap", "DE89 3704 0044 0532 0130 00 and DE89 3704 0044 0532 0130 01", "ES91 2100 0418 4502 0005 1332 BANK")
        XCTAssertEqual(try found(document, .iban), ["TR33 0006 1005 1978 6457 8413 26", "DE89 3704 0044 0532 0130 00", "ES91 2100 0418 4502 0005 1332"])
    }

    func test_paymentCardsNeedLuhn() throws {
        let document = try lines("Card 4111 1111 1111 1111 exp", "Wrong 4111 1111 1111 1112", "Dashes 5500-0000-0000-0004 done")
        XCTAssertEqual(try found(document, .paymentCard), ["4111 1111 1111 1111", "5500-0000-0000-0004"])
    }

    func test_dates() throws {
        let document = try lines("On 2024-03-15 and 15.03.2024 and 03/15/2024", "March 5, 2024 and 5 Mart 2024 and 17 Haziran 1999", "Not 2024-13-45 or 99.99.2024")
        let hits = try found(document, .date)
        XCTAssertEqual(Array(hits.prefix(5)), ["2024-03-15", "15.03.2024", "03/15/2024", "March 5, 2024", "5 Mart 2024"])
        XCTAssertEqual(hits.count, 6)
        XCTAssertFalse(hits.contains("2024-13-45"))
    }

    func test_regularExpressionAndWordList() throws {
        let document = try lines("Invoice INV-00123 for Acme and ACME corp", "Another INV-99999 plus acmeware")
        let cache = TextCache(document)
        XCTAssertEqual(try RedactionFinder.findRegex(cache, #"INV-\d{5}"#).map { $0.text }, ["INV-00123", "INV-99999"])
        XCTAssertEqual(try RedactionFinder.findWords(cache, ["acme"]).map { $0.text }, ["Acme", "ACME"])
        XCTAssertEqual(try RedactionFinder.findWords(cache, ["acme"], false).count, 3)
        XCTAssertEqual(try RedactionFinder.findWords(cache, ["Acme"], true, true).count, 1)
        XCTAssertThrowsError(try RedactionFinder.findRegex(cache, "(unclosed")) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_matchesBecomeMarksThatRemoveTheText() throws {
        let document = try lines("Mail jane@example.com please", "and bob@example.org too")
        let hits = try RedactionFinder.find(document, .email)
        let result = try PdfRedactor(document).apply(hits.map { $0.mark })
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "Mail  pleaseand  too")
        XCTAssertFalse(RedactionKit.holds(result.bytes, "example"))
    }

    func test_aBadKindIsRefused() throws {
        let document = try lines("x")
        XCTAssertThrowsError(try RedactionFinder.find(document, .word)) { XCTAssertTrue($0 is ArgumentException) }
    }
}
