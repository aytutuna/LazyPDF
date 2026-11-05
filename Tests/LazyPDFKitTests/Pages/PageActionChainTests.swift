import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageActionChainTests.cs: the same cases. The C# gives the two fan tests and the
// thread test 20 and 120 seconds with Task.Run and WaitAsync; here a run that does not end is the runner's timeout.

final class PageActionChainTests: XCTestCase {
    // Links 100 to 100 + levels: each action names the next one three times.
    private let levels = 32

    private func fan() -> [UInt8] {
        let levels = self.levels
        return PageTestFiles.make(2, pageExtra: { $0 == 0 ? "/Annots [99 0 R]" : "" }, add: { pdf in
            pdf.obj(99, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A 100 0 R>>")
            for i in 0...levels {
                let next = i == levels ? "" : "/Next [\(101 + i) 0 R \(101 + i) 0 R \(101 + i) 0 R]"
                pdf.obj(100 + i, "<</S /Named /N /NextPage \(next)>>")
            }
        })
    }

    func test_importingAFanOfActionsEnds() throws {
        let source = try PdfDocument.open(fan())
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, source, [0], 1)
        XCTAssertEqual(target.pages.count, 2)
    }

    func test_deletingAnotherPageWithAFanOfActionsEnds() throws {
        let document = try PdfDocument.open(fan())
        try PageOperations.delete(document, [1])
        XCTAssertEqual(document.pages.count, 1)
    }

    func test_openActionKeepsBeingOneActionWhenItsGoToIsDropped() throws {
        let document = try PageTestFiles.open(2, "/OpenAction 20 0 R", add: { pdf in
            pdf.obj(20, "<</S /GoTo /D [5 0 R /Fit] /Next [21 0 R 22 0 R [21 0 R]]>>")
                .obj(21, "<</S /URI /URI (http://a)>>")
                .obj(22, "<</S /URI /URI (http://b)>>")
        })

        try PageOperations.delete(document, [1])

        let action = try XCTUnwrap(document.resolve(document.catalog["OpenAction"]) as? PdfDictionary)
        XCTAssertEqual(document.name(action, "S"), "URI")
        let rest = try XCTUnwrap(document.resolve(action["Next"]) as? PdfArray)
        XCTAssertEqual(rest.items.count, 1)
        let follower = try XCTUnwrap(document.resolve(rest.items.first) as? PdfDictionary)
        XCTAssertEqual(document.name(follower, "S"), "URI")
        XCTAssertFalse(action === follower)
    }

    func test_aLongArticleThreadIsWalkedInLinearTime() throws {
        let beads = 120_000
        let free = PageTestFiles.free(2)
        let document = try PageTestFiles.open(2, "/Threads [\(free) 0 R]", add: { pdf in
            pdf.obj(free, "<</Type /Thread /F \(free + 1) 0 R>>")
            for i in 0..<beads {
                let next = free + 1 + (i + 1) % beads, previous = free + 1 + (i + beads - 1) % beads
                pdf.obj(free + 1 + i, "<</Type /Bead /N \(next) 0 R /V \(previous) 0 R /P \(i == 0 ? 5 : 4) 0 R /R [0 0 1 1]>>")
            }
        })

        try PageOperations.delete(document, [1])

        let thread = try XCTUnwrap(document.resolve(document.array(document.catalog, "Threads")?.items[0]) as? PdfDictionary)
        XCTAssertNotNil(thread["F"])
    }
}
