import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/LinearizerUpdateTests.cs: the same cases. The PdfPig text comparison has no
// twin; the engine's own text stands in for it.

final class LinearizerUpdateTests: XCTestCase {
    private func linear(_ pages: Int = 5) throws -> [UInt8] {
        try PdfDocument.open(LinearizerKit.make(pages)).saveLinearized()
    }

    func test_anUpdateLeavesAValidFileThatIsNoLongerLinearized() throws {
        let file = try linear()
        let document = try PdfDocument.open(file)
        XCTAssertTrue(document.isLinearized)
        document.info?["Title"] = PdfString(bytes: Latin1.bytes("Changed"), isHex: false)
        let updated = try document.saveIncremental()
        XCTAssertEqual(file, Array(updated[0..<file.count]))
        let again = try PdfDocument.open(updated)
        XCTAssertFalse(again.isLinearized)
        XCTAssertTrue(again.wasLinearized)
        XCTAssertEqual(5, again.pages.count)
        XCTAssertEqual("Changed", SaveFixtures.title(again))
        XCTAssertTrue(again.repairs.isEmpty)
        XCTAssertEqual(try LinearizerKit.textText(file), try LinearizerKit.textText(updated))
    }

    func test_aSessionCommitDoesTheSame() throws {
        let session = try PdfEditSession.open(try linear(3))
        XCTAssertTrue(session.document.isLinearized)
        session.document.info?["Title"] = PdfString(bytes: Latin1.bytes("Committed"), isHex: false)
        XCTAssertTrue(try session.commit("title"))
        XCTAssertFalse(session.document.isLinearized)
        XCTAssertTrue(try session.undo())
        XCTAssertTrue(session.document.isLinearized)
    }

    func test_aFileCutShortIsNotLinearized() throws {
        let file = try linear()
        let document = try PdfDocument.open(Array(file[0..<file.count - 20]))
        XCTAssertFalse(document.isLinearized)
        XCTAssertEqual(5, document.pages.count)
    }

    func test_aWrongLengthIsNotLinearized() throws {
        var file = try linear()
        let at = OptimizeKit.indexOf(file, Latin1.bytes("/L ")) + 3
        file[at + 3] ^= 1
        let document = try PdfDocument.open(file)
        XCTAssertFalse(document.isLinearized)
    }

    func test_aDictionaryWithoutALengthIsNotLinearized() throws {
        var file = try linear()
        let at = OptimizeKit.indexOf(file, Latin1.bytes("/L "))
        file[at + 1] = UInt8(ascii: "X")
        let document = try PdfDocument.open(file)
        XCTAssertFalse(document.isLinearized)
    }

    func test_anOrdinaryFileIsNotLinearized() throws {
        let document = try PdfDocument.open(LinearizerKit.make(2))
        XCTAssertFalse(document.isLinearized)
    }

    func test_bytesBeforeTheHeaderAreCutAndTheLengthStillMatches() throws {
        let file = try linear(2)
        let document = try PdfDocument.open(Array("junk\n".utf8) + file)
        XCTAssertTrue(document.isLinearized)
    }
}
