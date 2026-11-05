import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/ObjectStreamTests.cs: the same cases.

final class ObjectStreamTests: XCTestCase {
    private static let bodies = [
        "<</Type /Catalog /Pages 2 0 R>>",
        "<</Type /Pages /Kids [3 0 R] /Count 1>>",
        "<</Type /Page /Parent 2 0 R /Contents 4 0 R /MediaBox [0 0 100 100]>>",
    ]

    /// Objects 1 to 3 in object stream 5, content stream 4, cross-reference stream 6.
    static func objectStreamFile(predictor: Bool = false) -> (pdf: TestPdf, xref: Int) {
        var header = ""
        var body = ""
        for (i, text) in bodies.enumerated() {
            header += "\(i + 1) \(body.count) "
            body += text + "\n"
        }
        let pdf = TestPdf("%PDF-1.5\n")
        let content = pdf.position
        pdf.stream(4, "", "q Q")
        let objects = pdf.position
        pdf.stream(5, "/Type /ObjStm /N 3 /First \(header.count) /Filter /FlateDecode", TestPdf.deflate(TestPdf.latin(header + body)))
        let xrefOffset = pdf.position

        let rows = [
            row(0, 0, 255), row(2, 5, 0), row(2, 5, 1), row(2, 5, 2), row(1, content, 0), row(1, objects, 0), row(1, xrefOffset, 0),
        ]
        let data = predictor ? pngUp(rows) : Array(rows.joined())
        let parms = predictor ? "/DecodeParms <</Predictor 12 /Columns 5>>" : ""
        pdf.stream(6, "/Type /XRef /Size 7 /W [1 3 1] /Root 1 0 R /Filter /FlateDecode \(parms)", TestPdf.deflate(data))
        return (pdf, xrefOffset)
    }

    private static func row(_ type: Int, _ field: Int, _ third: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: type), UInt8(truncatingIfNeeded: field >> 16), UInt8(truncatingIfNeeded: field >> 8),
         UInt8(truncatingIfNeeded: field), UInt8(truncatingIfNeeded: third)]
    }

    private static func pngUp(_ rows: [[UInt8]]) -> [UInt8] {
        var output: [UInt8] = []
        var previous = [UInt8](repeating: 0, count: 5)
        for row in rows {
            output.append(2)
            for i in 0..<5 { output.append(row[i] &- previous[i]) }
            previous = row
        }
        return output
    }

    private func finish(_ pdf: TestPdf, _ xref: Int) -> [UInt8] {
        pdf.finishWithoutXref() + TestPdf.latin("startxref\n\(xref)\n%%EOF\n")
    }

    func test_objectsInObjectStreamsAreRead() throws {
        for predictor in [false, true] {
            let (pdf, xref) = Self.objectStreamFile(predictor: predictor)
            let document = try PdfDocument.open(finish(pdf, xref))
            XCTAssertTrue(document.repairs.isEmpty, "predictor \(predictor)")
            XCTAssertEqual(document.version, "1.5", "predictor \(predictor)")
            XCTAssertEqual(document.pages.count, 1, "predictor \(predictor)")
            XCTAssertEqual(document.pages[0].mediaBox.width, 100, "predictor \(predictor)")
            XCTAssertEqual(TestPdf.text(document.pages[0].contents()), "q Q", "predictor \(predictor)")
            XCTAssertTrue(document.xrefIsStream, "predictor \(predictor)")
            XCTAssertEqual(document.nextObjectNumber, 7, "predictor \(predictor)")
            XCTAssertEqual(document.objectNumbers, [1, 2, 3, 4, 5, 6], "predictor \(predictor)")
        }
    }

    func test_lostCrossReferenceStreamIsRebuiltFromTheObjectStream() throws {
        let (pdf, _) = Self.objectStreamFile()
        let document = try PdfDocument.open(finish(pdf, 12))
        XCTAssertTrue(document.xrefRebuilt)
        XCTAssertTrue(document.repairs.contains { $0.contains("Rebuilt") })
        XCTAssertEqual(document.pages.count, 1)
        XCTAssertEqual(document.name(document.catalog, "Type"), "Catalog")
    }

    func test_hybridFileTakesObjectsFromTheStreamTheTableLeavesFree() throws {
        let header = "2 0 3 \(Self.bodies[1].count + 1) "
        let data = header + Self.bodies[1] + "\n" + Self.bodies[2] + "\n"
        let pdf = TestPdf("%PDF-1.5\n")
        pdf.obj(1, Self.bodies[0])
        let content = pdf.position
        pdf.stream(4, "", "BT ET")
        let objects = pdf.position
        pdf.stream(5, "/Type /ObjStm /N 2 /First \(header.count)", data)
        let stream = pdf.position
        let rows = Self.row(2, 5, 0) + Self.row(2, 5, 1)
        pdf.stream(6, "/Type /XRef /Size 7 /W [1 3 1] /Index [2 2]", rows)
        let table = pdf.position
        func ten(_ n: Int) -> String { String(format: "%010ld", n) }
        var text = "xref\n0 7\n0000000000 65535 f \n\(ten(0)) 00000 n \n0000000000 00000 f \n0000000000 00000 f \n"
            + "\(ten(content)) 00000 n \n\(ten(objects)) 00000 n \n\(ten(stream)) 00000 n \n"
            + "trailer\n<</Size 7 /Root 1 0 R /XRefStm \(stream)>>\nstartxref\n\(table)\n%%EOF\n"
        // Object 1 is the first thing after the header.
        text = text.replacingOccurrences(of: "0000000000 00000 n \n", with: "\(ten(9)) 00000 n \n")
        let document = try PdfDocument.open(pdf.finishWithoutXref() + TestPdf.latin(text))
        XCTAssertTrue(document.repairs.isEmpty)
        XCTAssertEqual(document.pages.count, 1)
        XCTAssertEqual(TestPdf.text(document.pages[0].contents()), "BT ET")
    }

    func test_objectStreamWithAShortHeaderKeepsTheObjectsItHas() throws {
        let pdf = TestPdf("%PDF-1.5\n")
        let header = "1 0 2 "
        pdf.stream(5, "/Type /ObjStm /N 4 /First \(header.count)", header + Self.bodies[0] + " ")
        pdf.obj(2, Self.bodies[1]).obj(3, Self.bodies[2])
        let document = try PdfDocument.open(pdf.finishWithoutXref())
        XCTAssertTrue(document.repairs.contains { $0.contains("header lists") })
        XCTAssertEqual(document.name(document.catalog, "Type"), "Catalog")
    }

    func test_objectNumberZeroInAnObjectStreamHeaderIsLeftOut() throws {
        let pdf = TestPdf("%PDF-1.5\n")
        let header = "0 0 1 4 "
        pdf.stream(5, "/Type /ObjStm /N 2 /First \(header.count)", header + "(x) " + Self.bodies[0] + " ")
        pdf.obj(2, Self.bodies[1]).obj(3, Self.bodies[2])
        let document = try PdfDocument.open(pdf.finishWithoutXref())
        XCTAssertEqual(document.name(document.catalog, "Type"), "Catalog")
        XCTAssertFalse(document.objectNumbers.contains(0))
        for number in document.objectNumbers { document.set(number, try XCTUnwrap(document.get(number))) }
    }
}
