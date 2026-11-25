import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactXmpMarkupTests.cs: the same cases. The word in the markup of an XMP
// packet: an instruction, the address of a namespace, the name of an element. None of them is text that can be replaced, so
// the packet is emptied and reported, and with nothing to change it is found by the bytes.

final class RedactXmpMarkupTests: XCTestCase {
    private let word = "ZQXMARKER"

    private func redact(_ body: String, prefix: [UInt8] = [], change: Bool = true) throws -> RedactionResult {
        let packet = prefix + Array(("<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>"
            + "<rdf:Description rdf:about=''>" + body + "</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>").utf8)
        let document = try RedactionKit.page("BT /F1 12 Tf 100 100 Td (\(word)) Tj ET", "") { pdf in pdf.stream(9, "/Type /Metadata /Subtype /XML", packet) }
        document.catalog["Metadata"] = PdfReference(9, 0)
        var options = RedactionOptions()
        options.changeMetadata = change
        return try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, word), options)
    }

    func test_markupHoldingTheWordEmptiesThePacket() throws {
        let bodies = ["<?note ZQXMARKER was here?>", "<dc:title xmlns:dc='http://purl.org/dc/elements/1.1/ZQXMARKER'>Report</dc:title>",
                      "<ZQXMARKER>Report</ZQXMARKER>", "<dc:title ZQXMARKER='x' xmlns:dc='http://purl.org/dc/elements/1.1/'>Report</dc:title>"]
        for body in bodies {
            let result = try redact(body)
            XCTAssertTrue(result.report.findings.contains { $0.where == RedactionText.xmpUnreadable && $0.changed }, body)
            XCTAssertFalse(RedactionKit.holds(result.bytes, word), body)
            XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
        }
    }

    func test_markupHoldingTheWordIsFoundWhenNothingMayChange() throws {
        for body in ["<?note ZQXMARKER was here?>", "<ZQXMARKER>Report</ZQXMARKER>"] {
            let result = try redact(body, change: false)
            XCTAssertTrue(result.report.findings.contains { $0.where == "The XMP metadata" && !$0.changed }, body)
            XCTAssertFalse(result.verification.isClean, body)
        }
    }

    func test_secondByteOrderMarkEmptiesThePacket() throws {
        for change in [true, false] {
            let result = try redact("<?note \(word)?><dc:title xmlns:dc='http://purl.org/dc/elements/1.1/'>\(word)</dc:title>", prefix: [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF], change: change)
            XCTAssertTrue(result.report.findings.contains { $0.where == RedactionText.xmpUnreadable }, "\(change)")
            XCTAssertFalse(RedactionKit.holds(result.bytes, word), "\(change)")
        }
    }

    func test_verifySearchesTheBytesOfAPacketAsWellAsItsText() throws {
        let document = try RedactionKit.page("BT ET")
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("Metadata")
        document.catalog["Metadata"] = try document.add(PdfStream(dictionary, data: Array("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><?note \(word)?></x:xmpmeta>".utf8)))
        XCTAssertFalse(PdfRedactor.verify(try document.saveRewrite(), [], [word]).isClean)
    }
}
