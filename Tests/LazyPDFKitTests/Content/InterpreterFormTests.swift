import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Content/InterpreterFormTests.cs: the same cases.

final class InterpreterFormTests: XCTestCase {
    private let formEntries = "/Type /XObject /Subtype /Form /BBox [0 0 100 100]"

    private func withForm(_ page: String, _ form: String, _ entries: String? = nil,
                          resources: String = "/XObject <</Fm 5 0 R>> /Font <</F1 6 0 R>>") throws -> PdfDocument {
        try ContentTestPdf.page(page, resources) { pdf in
            pdf.stream(5, entries ?? self.formEntries, form)
            pdf.obj(6, ContentTestPdf.helvetica)
        }
    }

    func test_formContentRunsWithItsMatrixAndFontFromThePage() throws {
        let document = try withForm("/Fm Do", "BT /F1 10 Tf (A) Tj ET", formEntries + " /Matrix [1 0 0 1 50 60]")
        let r = ContentTestPdf.run(document)
        XCTAssertEqual(r.text, "A")
        XCTAssertEqual(r.glyphs[0].matrix.e, 50, accuracy: 1e-6)
        XCTAssertEqual(r.glyphs[0].matrix.f, 60, accuracy: 1e-6)
        XCTAssertEqual(r.events, ["form", "endform"])
        XCTAssertEqual(r.`where`[0].formDepth, 1)
    }

    func test_theFormUsesItsOwnResourcesFirst() throws {
        let document = try ContentTestPdf.page("/Fm Do", "/XObject <</Fm 5 0 R>>") { pdf in
            pdf.stream(5, self.formEntries + " /Resources <</Font <</F1 6 0 R>>>>", "BT /F1 10 Tf (A) Tj ET")
            pdf.obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /Courier>>")
        }
        XCTAssertEqual(ContentTestPdf.run(document).glyphs[0].character.width, 600)
    }

    func test_theBoxClipsAndFormStateDoesNotLeak() throws {
        let document = try withForm("/Fm Do 0 0 1 1 re f", "q 9 w 0 0 500 500 re f", formEntries + " /Matrix [1 0 0 1 10 10]")
        let r = ContentTestPdf.run(document)
        XCTAssertEqual(r.paths[0].state.clip, PdfRect(10, 10, 110, 110))
        XCTAssertEqual(r.paths[1].state.lineWidth, 1)
        XCTAssertEqual(r.paths[1].state.clip, PdfRect(0, 0, 600, 800))
    }

    func test_formsThatCallThemselvesRunOnce() throws {
        let document = try withForm("/Fm Do", "BT /F1 10 Tf (A) Tj ET /Fm Do", resources: "/XObject <</Fm 5 0 R>> /Font <</F1 6 0 R>>")
        XCTAssertEqual(ContentTestPdf.run(document).text, "A")
    }

    func test_twoFormsCallingEachOtherStop() throws {
        let document = try ContentTestPdf.page("/A Do", "/XObject <</A 5 0 R /B 6 0 R>> /Font <</F1 7 0 R>>") { pdf in
            pdf.stream(5, self.formEntries, "BT /F1 10 Tf (A) Tj ET /B Do")
            pdf.stream(6, self.formEntries, "BT /F1 10 Tf (B) Tj ET /A Do")
            pdf.obj(7, ContentTestPdf.helvetica)
        }
        XCTAssertEqual(ContentTestPdf.run(document).text, "AB")
    }

    func test_nestingStopsAtTheDepthCap() throws {
        let count = 40
        let names = (0..<count).map { "/F\($0) \(5 + $0) 0 R" }.joined(separator: " ")
        let document = try ContentTestPdf.page("/F0 Do", "/XObject <<\(names)>>") { pdf in
            for i in 0..<count { pdf.stream(5 + i, self.formEntries, "0 0 1 1 re f /F\(i + 1) Do") }
        }
        let r = ContentTestPdf.run(document)
        XCTAssertEqual(r.paths.count, 20)
        XCTAssertEqual(r.`where`.map { $0.formDepth }.max(), 20)
    }

    func test_aRunawayFanOutIsCutByTheOperationLimit() throws {
        // Eight forms, each calling the next ten times: 10^8 operations if let go.
        let levels = 8
        let names = (0..<levels).map { "/F\($0) \(5 + $0) 0 R" }.joined(separator: " ")
        let document = try ContentTestPdf.page("/F0 Do", "/XObject <<\(names)>>") { pdf in
            for i in 0..<levels {
                pdf.stream(5 + i, self.formEntries, i == levels - 1 ? "q Q" : String(repeating: "/F\(i + 1) Do ", count: 10))
            }
        }
        let interpreter = ContentInterpreter(document)
        let started = Date()
        interpreter.run(document.pages[0], Recorder())
        XCTAssertTrue(interpreter.isTruncated)
        XCTAssertLessThan(Date().timeIntervalSince(started), 120, "\(Date().timeIntervalSince(started)) s")
    }

    func test_anUndecodableFormIsSkipped() throws {
        let document = try withForm("/Fm Do 0 0 1 1 re f", "xx", formEntries + " /Filter /FlateDecode")
        XCTAssertEqual(ContentTestPdf.run(document).paths.count, 1)
    }

    func test_markedContentOpenInAFormClosesWithIt() throws {
        let document = try withForm("/Fm Do", "/X BMC 0 0 1 1 re f")
        XCTAssertEqual(ContentTestPdf.run(document).events, ["form", "begin X", "end X", "endform"])
    }

    func test_aFormCannotCloseAPageSequence() throws {
        let document = try withForm("/P BMC /Fm Do 0 0 1 1 re f EMC", "EMC")
        XCTAssertEqual(ContentTestPdf.run(document).events, ["begin P", "form", "endform", "end P"])
    }

    func test_runningAFormDirectly() throws {
        let document = try withForm("", "BT /F1 10 Tf (A) Tj ET", formEntries + " /Resources <</Font <</F1 6 0 R>>>>")
        let form = try XCTUnwrap(document.get(5) as? PdfStream)
        let r = Recorder()
        ContentInterpreter(document).run(form, r, PdfMatrix.translate(7, 8))
        XCTAssertEqual(r.text, "A")
        XCTAssertEqual(r.glyphs[0].matrix.e, 7, accuracy: 1e-6)
    }

    func test_tilingPatternCellRunsOncePerPattern() throws {
        let resources = "/Pattern <</P1 5 0 R>>"
        let document = try ContentTestPdf.page("/Pattern cs /P1 scn 0 0 100 100 re f 200 0 100 100 re f", resources) { pdf in
            pdf.stream(5, "/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Matrix [2 0 0 2 0 0]", "0 0 5 5 re f")
        }
        let r = ContentTestPdf.run(document)
        XCTAssertEqual(r.paths.count, 3)
        XCTAssertEqual(r.events, ["pattern", "endform"])
        // The cell is inside the pattern, scaled by its matrix.
        XCTAssertEqual(r.paths[1].path.bounds, PdfRect(0, 0, 10, 10))
        XCTAssertEqual(r.`where`.map { $0.formDepth }, [0, 1, 0])
        XCTAssertNotNil(r.paths[0].state.fillColor.pattern)
        XCTAssertEqual(r.paths[0].state.fillColor.patternName?.value, "P1")
    }

    func test_patternWalkingCanBeSwitchedOff() throws {
        let document = try ContentTestPdf.page("/Pattern cs /P1 scn 0 0 100 100 re f", "/Pattern <</P1 5 0 R>>") { pdf in
            pdf.stream(5, "/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10", "0 0 5 5 re f")
        }
        let r = Recorder()
        let interpreter = ContentInterpreter(document)
        interpreter.walkPatterns = false
        interpreter.run(document.pages[0], r)
        XCTAssertEqual(r.paths.count, 1)
    }
}
