import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/DisplayCopyTests.cs: a layer toggled in the view is drawn from a copy of the file; the file
// and its session stay as they are. The test that compares pixels of the file and of the copy needs a real renderer and moves
// to the PDFKit one.

final class DisplayCopyTests: XCTestCase {
    private final class StandInRenderer: DocumentRenderer {
        var draws = true
        var loaded: PdfEditSession?

        func load(_ session: PdfEditSession, _ password: String?) -> Bool {
            loaded = session
            return draws
        }

        func pageSize(_ pageIndex: Int) -> (width: Double, height: Double) { (200, 200) }
        func close() {}
        func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? { nil }
    }

    private func isOn(_ session: PdfEditSession) throws -> Bool {
        try XCTUnwrap(PdfLayers.read(session.document).layers.first { $0.reference == TestPdfs.blackBox }).isOn
    }

    func test_theCopyReadsTheLayerAsOffAndTheSessionItWasMadeFromAsOn() throws {
        let bytes = TestPdfs.layered()
        let session = try PdfEditSession.open(bytes)
        let renderer = StandInRenderer()

        let copy = try XCTUnwrap(DisplayCopy.create(bytes, password: nil, changes: [(TestPdfs.blackBox, false)]) { renderer })

        XCTAssertFalse(try isOn(copy.session))
        XCTAssertTrue(try isOn(session))
        XCTAssertFalse(session.isDirty)
        XCTAssertTrue(renderer.loaded === copy.session)
    }

    func test_aCopyTheSystemCannotDrawIsNotMade() {
        let renderer = StandInRenderer()
        renderer.draws = false

        XCTAssertNil(DisplayCopy.create(TestPdfs.layered(), password: nil, changes: []) { renderer })
    }

    func test_bytesTheEngineCannotOpenGiveNoCopy() {
        XCTAssertNil(DisplayCopy.create([1, 2, 3], password: nil, changes: []) { StandInRenderer() })
    }
}
