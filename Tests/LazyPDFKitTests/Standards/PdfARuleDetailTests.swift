import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfARuleDetailTests.cs: the same cases.

final class PdfARuleDetailTests: XCTestCase {
    private func annotated(_ subtype: String, _ entries: String, _ level: PdfALevel, _ intents: String = "/OutputIntents [6 0 R]") -> [UInt8] {
        StandardsKit.compliant(level, page: "/Annots [9 0 R]", extra: { pdf in
            pdf.obj(9, "<</Type /Annot /Subtype /\(subtype) /Rect [10 10 50 50] /F 4 /AP << /N 10 0 R >> \(entries)>>")
            pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 50 50]", "")
        }, intents: intents)
    }

    private func withStream(_ entries: String, _ level: PdfALevel) -> [UInt8] {
        StandardsKit.compliant(level, catalog: "/Extra 9 0 R", extra: { pdf in pdf.stream(9, entries, "abc") })
    }

    func test_polygonAndPolyLineCameWithPdf15() throws {
        for subtype in ["Polygon", "PolyLine"] {
            let vertices = "/Vertices [10 10 50 10 50 50]"
            StandardsKit.assertContains(try StandardsKit.clauses(annotated(subtype, vertices, .a1b), .a1b), "6.5.2")
            StandardsKit.assertLacks(try StandardsKit.clauses(annotated(subtype, vertices, .a2b)), "6.3.1")
        }
        StandardsKit.assertLacks(try StandardsKit.clauses(annotated("Square", "", .a1b), .a1b), "6.5.2")
        XCTAssertTrue(PdfAChecker.allowedAnnotations(2).contains("Polygon"))
        XCTAssertFalse(PdfAChecker.allowedAnnotations(1).contains("PolyLine"))
    }

    func test_filterRulesFollowThePart() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(withStream("/Filter /LZWDecode", .a2b)), "6.1.7.2")
        StandardsKit.assertContains(try StandardsKit.clauses(withStream("/Filter /LZWDecode", .a1b), .a1b), "6.1.10")
        StandardsKit.assertHas(try StandardsKit.check(withStream("/Filter /Invented", .a2b)).issues) { $0.clause == "6.1.7.2" && $0.message.contains("Invented") }
        StandardsKit.assertLacks(try StandardsKit.clauses(withStream("/Filter /FlateDecode", .a2b)), "6.1.7.2")
    }

    func test_aCryptFilterIsOnlyTheIdentityFromPart2() throws {
        StandardsKit.assertLacks(try StandardsKit.clauses(withStream("/Filter /Crypt /DecodeParms << /Name /Identity >>", .a2b)), "6.1.7.2")
        StandardsKit.assertLacks(try StandardsKit.clauses(withStream("/Filter [/Crypt] /DecodeParms [null]", .a2b)), "6.1.7.2")
        StandardsKit.assertContains(try StandardsKit.clauses(withStream("/Filter /Crypt /DecodeParms << /Name /Custom >>", .a2b)), "6.1.7.2")
        StandardsKit.assertContains(try StandardsKit.clauses(withStream("/Filter /Crypt /DecodeParms << /Name /Identity >>", .a1b), .a1b), "6.1.10")
    }

    func test_anEmbeddedFileInPart2IsPdfA1OrPdfA2() throws {
        func attach(_ inner: PdfALevel) -> [UInt8] {
            let content = StandardsKit.compliant(inner)
            return StandardsKit.compliant(.a2b, catalog: "/Names << /EmbeddedFiles << /Names [(a.pdf) 9 0 R] >> >>", extra: { pdf in
                pdf.obj(9, "<</Type /Filespec /F (a.pdf) /UF (a.pdf) /EF << /F 10 0 R >>>>")
                pdf.stream(10, "/Type /EmbeddedFile", content)
            })
        }
        try StandardsKit.assertClean(attach(.a2b))
        StandardsKit.assertHas(try StandardsKit.check(attach(.a3b)).issues) { $0.clause == "6.8" && $0.message.contains("not a PDF/A") }
    }

    func test_thePdfUaNamespaceNeedsAnExtensionSchema() throws {
        let file = StandardsKit.compliant(xmp: StandardsKit.packet(.a2b).replacingOccurrences(
            of: "<rdf:Description ", with: "<rdf:Description xmlns:pdfuaid=\"http://www.aiim.org/pdfua/ns/id/\" pdfuaid:part=\"1\" "))
        StandardsKit.assertHas(try StandardsKit.check(file).issues) { $0.clause == "6.6.2.3.1" && $0.message.contains("pdfua") }
    }

    func test_theMetadataStreamIsNotFiltered() throws {
        let plain = StandardsKit.compliant()
        StandardsKit.assertNone(try StandardsKit.check(plain).issues) { $0.message.contains("/Filter") }
        let filtered = StandardsKit.compliant(extra: { pdf in
            pdf.stream(5, "/Type /Metadata /Subtype /XML /Filter /FlateDecode", TestPdf.deflate(Array(StandardsKit.packet(.a2b).utf8)))
        })
        StandardsKit.assertHas(try StandardsKit.check(filtered).issues) { $0.clause == "6.6.2.1" && $0.message.contains("/Filter") }
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(.a1b, extra: { pdf in
            pdf.stream(5, "/Type /Metadata /Subtype /XML /Filter /FlateDecode", TestPdf.deflate(Array(StandardsKit.packet(.a1b).utf8)))
        }), .a1b), "6.7.2")
    }

    func test_annotationColoursNeedAnRgbIntentInPart1() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(annotated("Square", "/C [1 0 0 0]", .a1b, ""), .a1b), "6.5.3")
        StandardsKit.assertContains(try StandardsKit.clauses(annotated("Square", "/IC [0.5]", .a1b, ""), .a1b), "6.5.3")
        StandardsKit.assertLacks(try StandardsKit.clauses(annotated("Square", "/C [1 0 0]", .a1b), .a1b), "6.5.3")
        StandardsKit.assertLacks(try StandardsKit.clauses(annotated("Square", "/C []", .a1b, ""), .a1b), "6.5.3")
        StandardsKit.assertLacks(try StandardsKit.clauses(annotated("Square", "/C [1 0 0 0]", .a2b, "")), "6.5.3")
    }

    func test_needsRenderingIsNotAllowedFromPart2() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(catalog: "/NeedsRendering false")), "6.4.2")
        StandardsKit.assertLacks(try StandardsKit.clauses(StandardsKit.compliant()), "6.4.2")
    }

    func test_blendModesMustBeOnesOfTheStandard() throws {
        func with(_ mode: String, _ level: PdfALevel = .a2b) -> [UInt8] { StandardsKit.compliant(level, resources: "/ExtGState <</G0 << /BM \(mode) >>>>") }
        try StandardsKit.assertClean(with("/Multiply"))
        try StandardsKit.assertClean(with("/Luminosity"))
        StandardsKit.assertHas(try StandardsKit.check(with("/Glow")).issues) { $0.clause == "6.2.10" && $0.message.contains("Glow") }
        StandardsKit.assertContains(try StandardsKit.clauses(with("[/Multiply /Glow]")), "6.2.10")
        StandardsKit.assertContains(try StandardsKit.clauses(with("/Multiply", .a1b), .a1b), "6.4")
    }

    func test_theConformanceLetterIsMatchedAsWritten() throws {
        func packet(_ level: PdfALevel, _ from: String, _ to: String) -> [UInt8] {
            StandardsKit.compliant(level, xmp: StandardsKit.packet(level).replacingOccurrences(of: "<pdfaid:conformance>\(from)<", with: "<pdfaid:conformance>\(to)<"))
        }
        StandardsKit.assertContains(try StandardsKit.clauses(packet(.a2b, "B", "b")), "6.6.4")
        StandardsKit.assertContains(try StandardsKit.clauses(packet(.a1b, "B", "U"), .a1b), "6.7.11")
        StandardsKit.assertLacks(try StandardsKit.clauses(packet(.a2b, "B", "U")), "6.6.4")
        StandardsKit.assertLacks(try StandardsKit.clauses(packet(.a1b, "B", "A"), .a1b), "6.7.11")
    }

    func test_aLabProfileMayHaveThreeComponents() {
        var lab = PdfASrgb.srgbProfile
        lab.replaceSubrange(16..<20, with: Array("Lab ".utf8))
        XCTAssertNil(PdfAChecker.iccProblem(lab, 3, 4))
        XCTAssertNotNil(PdfAChecker.iccProblem(lab, 1, 4))
        XCTAssertNotNil(PdfAChecker.iccProblem(lab, 3, 4, true))
        var scanner = PdfASrgb.srgbProfile
        scanner.replaceSubrange(12..<16, with: Array("scnr".utf8))
        XCTAssertNil(PdfAChecker.iccProblem(scanner, 3, 4))
        XCTAssertNotNil(PdfAChecker.iccProblem(scanner, 3, 4, true))
    }
}
