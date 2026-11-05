import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageRotateTests.cs: the same cases, except AnAngleThatIsNotAQuarterTurnIsRefused
// and APageThatIsNotThereIsRefusedBeforeAnythingChanges, whose ArgumentException and ArgumentOutOfRangeException are
// preconditions in Swift and cannot be caught.

final class PageRotateTests: XCTestCase {
    func test_rotationAddsUpAndStaysAMultipleOf90() throws {
        let document = try PageTestFiles.open(3)
        PageOperations.rotate(document, [0, 2], 90)
        PageOperations.rotate(document, [0], 270)
        PageOperations.rotate(document, [2], 180)
        PageOperations.rotate(document, [1], -90)
        XCTAssertEqual(document.pages.map { $0.rotate }, [0, 270, 270])
        for page in document.pages {
            XCTAssertEqual(((page.dictionary["Rotate"] as? PdfNumber)?.integer ?? 1) % 90, 0)
        }
    }

    func test_rotationBuildsOnWhatThePageInherits() throws {
        let document = try PageTestFiles.open(2, rootExtra: "/Rotate 90")
        PageOperations.rotate(document, [1], 90)
        XCTAssertEqual(document.pages.map { $0.rotate }, [90, 180])
    }

    func test_aRepeatedPageTurnsOnce() throws {
        let document = try PageTestFiles.open(1)
        PageOperations.rotate(document, [0, 0], 90)
        XCTAssertEqual(document.pages[0].rotate, 90)
    }

    func test_rotationSurvivesACommitAndAnUndo() throws {
        let session = try PdfEditSession.open(PageTestFiles.make(2))
        PageOperations.rotate(session.document, [1], 90)
        let reopened = try PageTestFiles.commit(session, "Rotate")
        XCTAssertEqual(reopened.pages.map { $0.rotate }, [0, 90])
        XCTAssertTrue(try session.undo())
        XCTAssertEqual(session.document.pages.map { $0.rotate }, [0, 0])
    }
}
