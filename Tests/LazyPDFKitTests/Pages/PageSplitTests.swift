import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageSplitTests.cs: the same cases. The cancellation is the task's: the two
// cancelled cases run in a task that is cancelled before the split starts. The ArgumentException and
// ArgumentOutOfRangeException lines that are preconditions in Swift are not there; an extract of no pages throws.

final class PageSplitTests: XCTestCase {
    private func order(_ parts: [PdfDocument]) -> String {
        parts.map { part in PageTestFiles.order(part).map { String($0) }.joined(separator: ",") }.joined(separator: " | ")
    }

    func test_everyNPagesLeavesTheRestInTheLastPart() throws {
        XCTAssertEqual(order(try PageAssembly.splitEvery(try PageTestFiles.open(5), 2)), "1,2 | 3,4 | 5")
        XCTAssertEqual(order(try PageAssembly.splitEvery(try PageTestFiles.open(3), 3)), "1,2,3")
        XCTAssertEqual(order(try PageAssembly.splitEvery(try PageTestFiles.open(2), 1)), "1 | 2")
        XCTAssertEqual(order(try PageAssembly.splitEvery(try PageTestFiles.open(2), 10)), "1,2")
    }

    func test_byRangesGivesOnePartForEachInTheOrderTyped() throws {
        let document = try PageTestFiles.open(8)
        let ranges = ["1-3", "8, 5", "2-3"].map { PageRange.parse($0, 8).pages }
        XCTAssertEqual(order(try PageAssembly.splitByRanges(document, ranges)), "1,2,3 | 8,5 | 2,3")
        assertReadFails(try PageAssembly.splitByRanges(document, [[]]), .damaged)
    }

    func test_atPagesStartsAPartAtEachOfThem() throws {
        let document = try PageTestFiles.open(6)
        XCTAssertEqual(order(try PageAssembly.splitAt(document, [2, 5])), "1,2 | 3,4,5 | 6")
        XCTAssertEqual(order(try PageAssembly.splitAt(document, [5, 0, 2, 2])), "1,2 | 3,4,5 | 6")
        XCTAssertEqual(order(try PageAssembly.splitAt(document, [])), "1,2,3,4,5,6")
    }

    func test_eachPartIsAFileOfItsOwn() throws {
        for part in try PageAssembly.splitEvery(try PageTestFiles.open(5), 2) {
            XCTAssertFalse(try PageTestFiles.reopen(part).isEmpty)
        }
    }

    // Pages of about a kilobyte of data nothing can compress, so that a page weighs what its data does.
    private func heavy(_ count: Int, _ perPage: Int) throws -> PdfDocument {
        var random = SeededRandom(11)
        let pdf = TestPdf().obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        let kids = (0..<count).map { "\(3 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(count) /MediaBox [0 0 100 100]>>")
        for i in 0..<count {
            pdf.obj(3 + i, "<</Type /Page /Parent 2 0 R /Contents \(3 + count + i) 0 R /Resources <</XObject <</X \(3 + 2 * count + i) 0 R>>>>>>")
        }
        for i in 0..<count { pdf.stream(3 + count + i, "", "BT (\(i + 1)) Tj ET /X Do") }
        for i in 0..<count {
            pdf.stream(3 + 2 * count + i, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode",
                       random.bytes(i == 4 ? perPage * 6 : perPage))
        }
        return try PdfDocument.open(pdf.finish())
    }

    private func numbers(_ document: PdfDocument) -> [Int] {
        document.pages.map { page in
            Int(Latin1.string(page.contents()).dropFirst(4).split(separator: ")").first ?? "") ?? -1
        }
    }

    func test_bySizeFitsAsManyPagesAsTheLimitAllows() throws {
        // Page 5 is six times as heavy as the others: it cannot share a part, and no limit below its size holds it.
        let document = try heavy(12, 1000)
        let one = try PageAssembly.extract(document, [0]).saveRewrite().count
        let three = try PageAssembly.extract(document, [0, 1, 2]).saveRewrite().count
        let limit = three + (three - one) / 2
        let parts = try PageAssembly.splitBySize(document, limit)
        XCTAssertEqual(parts.flatMap { numbers($0) }, Array(1...12))
        XCTAssertEqual(parts.map { $0.pages.count }, [3, 1, 1, 3, 3, 1])
        for part in parts { XCTAssertTrue(try part.saveRewrite().count <= limit || part.pages.count == 1) }
        XCTAssertGreaterThan(try parts[2].saveRewrite().count, limit)
    }

    func test_aLimitOfOneByteGivesOnePagePerPart() throws {
        let parts = try PageAssembly.splitBySize(try PageTestFiles.open(4), 1)
        XCTAssertEqual(parts.count, 4)
    }

    func test_aCancelledSplitBySizeThrows() async throws {
        let task = Task { () throws -> [PdfDocument] in
            while !Task.isCancelled { await Task.yield() }
            return try PageAssembly.splitBySize(try PageTestFiles.open(6), 1)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }

    func test_aCancelledSplitByCountThrows() async throws {
        let task = Task { () throws -> [PdfDocument] in
            while !Task.isCancelled { await Task.yield() }
            return try PageAssembly.splitEvery(try PageTestFiles.open(6), 2)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }

    func test_aLimitAboveTheWholeGivesOnePart() throws {
        let parts = try PageAssembly.splitBySize(try PageTestFiles.open(4), 10_000_000)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].pages.count, 4)
    }

    func test_extractKeepsTheOrderAskedAndTheInfo() throws {
        let document = try PdfDocument.open(PageTestFiles.make(4, add: { $0.obj(20, "<</Title (Kept)>>") }, trailerExtra: "/Info 20 0 R"))
        let part = try PageAssembly.extract(document, [3, 0, 3])
        XCTAssertEqual(PageTestFiles.order(part), [4, 1, 4])
        XCTAssertEqual(PageTestFiles.text(try PdfDocument.open(try part.saveRewrite()).info?["Title"]), "Kept")
        assertReadFails(try PageAssembly.extract(document, []), .damaged)
    }

    func test_theSourceIsLeftAsItWas() throws {
        let session = try PdfEditSession.open(PageTestFiles.make(4))
        _ = try PageAssembly.splitEvery(session.document, 2)
        _ = try PageAssembly.extract(session.document, [1])
        XCTAssertFalse(try session.commit("Nothing"))
        XCTAssertFalse(session.isDirty)
    }

    func test_aCountBeyondThePagesIsOnePart() throws {
        XCTAssertEqual(order(try PageAssembly.splitEvery(try PageTestFiles.open(2), Int(Int32.max))), "1,2")
        XCTAssertEqual(order(try PageAssembly.splitEvery(try PageTestFiles.open(2), Int(Int32.max) - 1)), "1,2")
    }
}
