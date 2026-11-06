import Foundation
import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The stand-ins the viewer's tests share, as windows/LazyPDF.App.Tests/StandIns.cs and LayeredPdf.cs have them.

final class NoFonts: FontSource {
    func find(_ family: String, _ style: FontStyles) -> FontFile? { nil }
}

enum TestPdfs {
    static func text(pages: Int = 1, line: String = "Hello from the tests.") throws -> [UInt8] {
        let text = (0..<pages).map { "\(line) Page \($0 + 1)." }.joined(separator: "\u{0C}")
        return try PdfFromText.create(text, fonts: NoFonts()).bytes
    }

    /// The file of the fixtures (Tests/Fixtures/Documents) by name.
    static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("Documents").appendingPathComponent(name)
    }

    /// Changes the title, so the session has something to commit.
    static func retitle(_ session: PdfEditSession, _ title: String) throws {
        var metadata = DocumentMetadata.read(session.document)
        metadata.title = title
        try metadata.write(session.document)
    }

    static func addNote(_ session: PdfEditSession, page: Int) throws {
        let info = AnnotationInfo(author: "Ada", contents: "Look", date: DateTimeOffset(1970, 1, 1, 0, 0, 0))
        _ = try PdfAnnotationWriter(session.document).addNote(session.document.pages[page], PdfRect(100, 100, 120, 120), info)
    }

    /// A one page file whose black square is on a layer ("Black box", object 5), written by hand.
    static let blackBox = PdfReference(5, 0)

    static func layered() -> [UInt8] {
        let content = "/OC /L1 BDC 0 0 0 rg 20 20 160 160 re f EMC"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /Order [5 0 R 6 0 R] /ON [5 0 R 6 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Resources << /Properties << /L1 5 0 R /L2 6 0 R >> >> >>",
            "<< /Length \(content.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /OCG /Name (Black box) >>",
            "<< /Type /OCG /Name (Notes) >>",
        ]
        var file = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(file.utf8.count)
            file += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = file.utf8.count
        file += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { file += String(repeating: "0", count: 10 - String(offset).count) + "\(offset) 00000 n \n" }
        file += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Array(file.utf8)
    }
}

/// A temporary file path that is removed with the test.
func temporaryFile(_ name: String, for test: XCTestCase) -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory.appendingPathComponent(name).path
}

/// Polls until `condition` holds, for the tests that wait on background work.
func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(condition(), file: file, line: line)
}
