import Observation
import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/Pages/CombineJobTests.cs: combine and split against the real engine: the parts a file is
// cut into, their names, and the files that are read in. CultureScope is left out: the number parser takes the locale as an
// argument.

@MainActor
final class CombineJobTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    func test_anAmountIsAcceptedOnlyWhenItMakesSenseForTheKindOfSplit() {
        let cases: [(SplitBy, String, Double?)] = [(.count, "10", 10), (.count, "0", nil), (.count, "2.5", nil), (.count, "many", nil),
                                                   (.size, "0.5", 0.5), (.size, "0", nil), (.bookmarks, "", 0)]
        for (by, text, expected) in cases {
            XCTAssertEqual(CombineJob.amount(by, text, locale: english), expected, "\(by) \(text)")
        }
    }

    func test_splittingByCountMakesPartsOfThatManyPages() throws {
        let source = try PdfDocument.open(Pdfs.text(7))

        let parts = try CombineJob.split(source, .count, 3)

        XCTAssertEqual(parts.map { $0.pages.count }, [3, 3, 1])
    }

    func test_aCancelledSplitStopsInsteadOfMakingParts() throws {
        let source = try PdfDocument.open(Pdfs.text(7))
        let token = CancelToken()
        token.cancel()

        XCTAssertThrowsError(try CombineJob.split(source, .size, 0.01, token))
        XCTAssertThrowsError(try CombineJob.split(source, .count, 2, token))
    }

    func test_splittingByBookmarksCutsAtTheTopLevelOnes() throws {
        let source = try PagesPdfs.withBookmarks(6, [0, 2, 5])

        let parts = try CombineJob.split(source, .bookmarks, 0)

        XCTAssertEqual(parts.map { $0.pages.count }, [2, 3, 1])
    }

    func test_bookmarksThatPointNowhereAreIgnored() throws {
        let source = try PagesPdfs.withBookmarks(3, [1])
        let item = OutlineItem()
        item.title = "Nowhere"
        item.destination = PdfDestination(-1)
        _ = try Outline.read(source).add(item)

        XCTAssertEqual(CombineJob.bookmarkStarts(source), [1])
    }

    func test_aSizeLimitGivesPartsThatFitIt() throws {
        let source = try PdfDocument.open(Pdfs.text(12))
        let whole = try source.saveRewrite().count
        let megabytes = Double(whole) / 2 / Double(CombineJob.megabyteBytes)

        let parts = try CombineJob.split(source, .size, megabytes)

        XCTAssertGreaterThanOrEqual(parts.count, 2)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.pages.count }, 12)
        for part in parts {
            XCTAssertTrue(try part.saveRewrite().count <= Int(megabytes * Double(CombineJob.megabyteBytes)) || part.pages.count == 1)
        }
    }

    func test_partsAreNumberedToTheWidthOfTheCount() {
        XCTAssertEqual(CombineJob.partName("Report", 1, 5), "Report 2.pdf")
        XCTAssertEqual(CombineJob.partName("Report", 1, 12), "Report 02.pdf")
        XCTAssertEqual(CombineJob.partName("Report", 11, 120), "Report 012.pdf")
    }

    func test_aNameTakenInTheFolderGetsANumber() {
        let dir = TempDir(self)
        dir.file("Report 1.pdf", [1])
        dir.file("Report 1 (2).pdf", [1])

        XCTAssertEqual(CombineJob.uniquePath(dir.url, "Report 1.pdf").lastPathComponent, "Report 1 (3).pdf")
        XCTAssertEqual(CombineJob.uniquePath(dir.url, "Other.pdf").lastPathComponent, "Other.pdf")
    }

    func test_filesMergeWithTheirRangesInTheOrderOfTheList() throws {
        let first = try PdfDocument.open(Pdfs.text(4))
        let second = try PdfDocument.open(Pdfs.text(3))

        let merged = try PageAssembly.merge([MergeSource(second, PageRange.parse("2-3", 3).pages), MergeSource(first, nil),
                                             MergeSource(second, PageRange.parse("1", 3).pages)])

        XCTAssertEqual(merged.pages.count, 7)
    }

    func test_aFileThatCannotBeReadIsReportedAndLeftOut() async throws {
        let dir = TempDir(self)
        let host = PagesHost()
        let asker = StubAsker()
        let bad = dir.file("bad.pdf", [1, 2, 3, 4])
        let good = dir.file("good.pdf", Pdfs.text(2))
        let missing = dir.sub("gone.pdf")

        let first = await SourceFile.open(host, ToolFile(url: bad), asker)
        let second = await SourceFile.open(host, ToolFile(url: missing), asker)
        let opened = await SourceFile.open(host, ToolFile(url: good), asker)

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(opened?.pages.count, 2)
        XCTAssertEqual(host.problems.map(\.title), ["Not a PDF", "File not found"])
    }

    func test_aLockedFileIsOpenedWithThePasswordTheAskerGives() async throws {
        let dir = TempDir(self)
        let host = PagesHost()
        let asker = StubAsker(passwords: ["guess", "secret"])
        let locked = dir.file("locked.pdf", try PagesPdfs.locked())

        let opened = await SourceFile.open(host, ToolFile(url: locked), asker)

        XCTAssertEqual(opened?.pages.count, 3)
        XCTAssertEqual(asker.asked, [false, true])
        XCTAssertTrue(host.problems.isEmpty)
    }

    func test_givingUpOnThePasswordLeavesTheFileOutWithoutAProblem() async throws {
        let dir = TempDir(self)
        let host = PagesHost()
        let locked = dir.file("locked.pdf", try PagesPdfs.locked())

        let opened = await SourceFile.open(host, ToolFile(url: locked), StubAsker())

        XCTAssertNil(opened)
        XCTAssertTrue(host.problems.isEmpty)
    }

    func test_bookmarksOnTheSamePageOrTheFirstMakeNoExtraPart() throws {
        XCTAssertEqual(CombineJob.bookmarkParts(try PagesPdfs.withBookmarks(5, [0, 0])), 1)
        XCTAssertEqual(CombineJob.bookmarkParts(try PagesPdfs.withBookmarks(5, [0, 3, 3])), 2)
        XCTAssertEqual(CombineJob.bookmarkParts(try PagesPdfs.withBookmarks(5, [1, 3])), 3)
    }

    func test_aRangeTypedInAnEntryIsAnnounced() {
        let entry = CombineEntry("a.pdf", 3, nil)
        let changed = Counter()
        withObservationTracking { _ = entry.range } onChange: { changed.count += 1 }

        entry.range = "1-3"

        XCTAssertEqual(entry.range, "1-3")
        XCTAssertEqual(changed.count, 1)
    }

    func test_theEntryOfTheOpenFileFollowsItsPageCount() {
        let entry = CombineEntry("a.pdf", 3, nil)
        let changed = Counter()
        withObservationTracking { _ = entry.detail } onChange: { changed.count += 1 }

        entry.pages = 5

        XCTAssertEqual(entry.detail, "5 pages")
        XCTAssertEqual(changed.count, 1)
    }
}
