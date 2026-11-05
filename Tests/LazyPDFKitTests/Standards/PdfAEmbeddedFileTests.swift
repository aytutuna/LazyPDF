import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAEmbeddedFileTests.cs: the same cases.

final class PdfAEmbeddedFileTests: XCTestCase {
    private func withAttachment(_ content: [UInt8], _ spec: String = "", _ level: PdfALevel = .a2b, _ stream: String = "/Type /EmbeddedFile") -> [UInt8] {
        StandardsKit.compliant(level, catalog: "/Names << /EmbeddedFiles << /Names [(a.dat) 9 0 R] >> >>", extra: { pdf in
            pdf.obj(9, "<</Type /Filespec /F (a.dat) /UF (a.dat) /EF << /F 10 0 R >> \(spec)>>")
            pdf.stream(10, stream, content)
        })
    }

    private let text = Array("hello".utf8)

    func test_part1AndPart4ForbidEmbeddedFiles() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(withAttachment(text, "", .a1b), .a1b), "6.1.11")
        StandardsKit.assertContains(try StandardsKit.clauses(withAttachment(text, "", .a4), .a4), "6.8")
    }

    func test_part2OnlyAllowsFilesThatAreThemselvesPdfA() throws {
        StandardsKit.assertHas(try StandardsKit.check(withAttachment(text)).issues) { $0.clause == "6.8" && $0.message.contains("not a PDF/A") }
        try StandardsKit.assertClean(withAttachment(StandardsKit.compliant(.a2b)))
    }

    func test_part3AllowsAnyFileWithARelationshipAndAType() throws {
        StandardsKit.assertHas(try StandardsKit.check(withAttachment(text, "", .a3b), .a3b).issues) { $0.message.contains("AFRelationship") }
        StandardsKit.assertHas(try StandardsKit.check(withAttachment(text, "/AFRelationship /Data", .a3b), .a3b).issues) { $0.message.contains("MIME") }
        try StandardsKit.assertClean(withAttachment(text, "/AFRelationship /Data", .a3b, "/Type /EmbeddedFile /Subtype /text#2Fplain"), .a3b)
    }
}
