import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageMergeTests.cs: the same cases. The cancellation is the task's: the two
// cancelled cases run in a task that is cancelled before the merge starts. AMergeCancelledWhileItCopiesPagesStopsThere cancels
// the task from outside after a short wait, where the C# hands the merge a list of pages that raises the token when it is
// read; a list of 200000 pages keeps the merge copying for longer than the wait. The
// ArgumentException and ArgumentOutOfRangeException lines of NothingToMergeIsRefused that are preconditions in Swift are not
// there; a source with no page throws.

final class PageMergeTests: XCTestCase {
    private static func doc(_ count: Int, _ catalogExtra: String = "") throws -> PdfDocument {
        try PageTestFiles.open(count, catalogExtra)
    }

    private func fontCount(_ document: PdfDocument) -> Int {
        document.objectNumbers.filter { n in (document.get(n) as? PdfDictionary).map { document.name($0, "Type") == "Font" } ?? false }.count
    }

    func test_sourcesFollowEachOtherWithTheirRanges() throws {
        let merged = try PageAssembly.merge([MergeSource(try Self.doc(3)), MergeSource(try Self.doc(4), PageRange.parse("2-3, 1", 4).pages),
                                             MergeSource(try Self.doc(2), [])])
        XCTAssertEqual(PageTestFiles.order(merged), [1, 2, 3, 2, 3, 1])
        XCTAssertEqual(try PageTestFiles.reopen(merged), ["Page 1", "Page 2", "Page 3", "Page 2", "Page 3", "Page 1"])
    }

    func test_theMergeIsAFreshDocumentWithOneBalancedTree() throws {
        let merged = try PageAssembly.merge([MergeSource(try Self.doc(40)), MergeSource(try Self.doc(40))])
        let again = try PdfDocument.open(try merged.saveRewrite())
        XCTAssertEqual(again.repairs, [])
        XCTAssertEqual(again.pages.count, 80)
        XCTAssertLessThanOrEqual(try XCTUnwrap(again.array(again.dict(again.catalog, "Pages"), "Kids")).items.count, 32)
    }

    func test_aFontSharedByAllPagesOfASourceIsCopiedOnce() throws {
        let merged = try PageAssembly.merge([MergeSource(try Self.doc(10)), MergeSource(try Self.doc(10))])
        let again = try PdfDocument.open(try merged.saveRewrite())
        XCTAssertEqual(fontCount(again), 2)
    }

    func test_aDocumentListedTwiceIsCopiedOnce() throws {
        let source = try Self.doc(10)
        let merged = try PageAssembly.merge([MergeSource(source, [0]), MergeSource(source, [9])])
        let again = try PdfDocument.open(try merged.saveRewrite())
        XCTAssertEqual(PageTestFiles.order(again), [1, 10])
        XCTAssertEqual(fontCount(again), 1)
    }

    func test_theFirstSourcesInfoIsKept() throws {
        let first = try PdfDocument.open(PageTestFiles.make(1, add: { $0.obj(20, "<</Title (First) /Author (Someone)>>") }, trailerExtra: "/Info 20 0 R"))
        let merged = try PageAssembly.merge([MergeSource(first), MergeSource(try Self.doc(1))])
        let again = try PdfDocument.open(try merged.saveRewrite())
        XCTAssertEqual(PageTestFiles.text(again.info?["Title"]), "First")
    }

    func test_formFieldsOfTwoFilesWithTheSameNamesStayApart() throws {
        func form(_ value: String) throws -> PdfDocument {
            try PdfDocument.open(PageTestFiles.make(1, "/AcroForm <</Fields [20 0 R]>>", pageExtra: { _ in "/Annots [20 0 R]" }, add: { pdf in
                pdf.obj(20, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (\(value)) /Rect [0 0 10 10]>>")
            }))
        }
        let merged = try PageAssembly.merge([MergeSource(try form("one")), MergeSource(try form("two"))])
        let again = try PdfDocument.open(try merged.saveRewrite())
        let fields = try XCTUnwrap(again.array(again.dict(again.catalog, "AcroForm"), "Fields")).items.compactMap { again.resolve($0) as? PdfDictionary }
        XCTAssertEqual(fields.map { PageTestFiles.text($0["T"]) }, ["name", "name_2"])
        XCTAssertEqual(fields.map { PageTestFiles.text($0["V"]) }, ["one", "two"])
    }

    func test_nothingToMergeIsRefused() throws {
        assertReadFails(try PageAssembly.merge([MergeSource(try Self.doc(2), [])]), .damaged)
    }

    func test_sourcesThatAreEncryptedMerge() throws {
        let locked = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: .all, strength: .aes256,
                                        firstId: [UInt8](repeating: 0, count: 16), random: SeededRandom(3))
        let encrypted = try PdfDocument.open(try PdfDocument.open(PageTestFiles.make(2)).saveRewrite(PdfSaveOptions(useObjectStreams: false, security: locked)))
        let merged = try PageAssembly.merge([MergeSource(encrypted), MergeSource(try Self.doc(1))])
        XCTAssertEqual(try PageTestFiles.reopen(merged), ["Page 1", "Page 2", "Page 1"])
    }

    func test_aMergeGoesThroughASessionAsOneStep() throws {
        let merged = try PageAssembly.merge([MergeSource(try Self.doc(2)), MergeSource(try Self.doc(2))])
        let session = try PdfEditSession.open(try merged.saveRewrite())
        try PageOperations.delete(session.document, [0])
        XCTAssertTrue(try session.commit("Delete"))
        XCTAssertEqual(PageTestFiles.order(try PdfDocument.open(session.current)), [2, 1, 2])
        XCTAssertTrue(try session.undo())
        XCTAssertEqual(session.document.pages.count, 4)
    }

    func test_aCancelledMergeThrowsBeforeCopyingAnything() async throws {
        let task = Task { () throws -> PdfDocument in
            while !Task.isCancelled { await Task.yield() }
            return try PageAssembly.merge([MergeSource(try Self.doc(3)), MergeSource(try Self.doc(3))])
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }

    func test_anUncancelledTokenChangesNothing() throws {
        let merged = try PageAssembly.merge([MergeSource(try Self.doc(2)), MergeSource(try Self.doc(2))])
        XCTAssertEqual(PageTestFiles.order(merged), [1, 2, 1, 2])
    }

    func test_aMergeCancelledWhileItCopiesPagesStopsThere() async throws {
        let source = try Self.doc(1)
        let pages = [Int](repeating: 0, count: 200_000)
        let task = Task { () throws -> PdfDocument in
            try PageAssembly.merge([MergeSource(try Self.doc(1)), MergeSource(source, pages)])
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }

    func test_aDocumentListedTwiceGivesEachCopyItsOwnFields() throws {
        let source = try PdfDocument.open(PageTestFiles.make(1, "/AcroForm <</Fields [20 0 R]>>", pageExtra: { _ in "/Annots [21 0 R 22 0 R]" }, add: { pdf in
            pdf.obj(20, "<</FT /Btn /Ff 49152 /T (r) /V /a /Kids [21 0 R 22 0 R]>>")
                .obj(21, "<</Type /Annot /Subtype /Widget /Parent 20 0 R /Rect [0 0 10 10] /AS /a /AP <</N <</a 23 0 R /Off 23 0 R>>>>>>")
                .obj(22, "<</Type /Annot /Subtype /Widget /Parent 20 0 R /Rect [20 0 30 10] /AS /Off /AP <</N <</b 23 0 R /Off 23 0 R>>>>>>")
                .stream(23, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "")
        }))
        let merged = try PageAssembly.merge([MergeSource(source), MergeSource(source)])
        let again = try PdfDocument.open(try merged.saveRewrite())
        let form = try XCTUnwrap(again.dict(again.catalog, "AcroForm"))
        let fields = try XCTUnwrap(again.array(form, "Fields")).items.compactMap { again.resolve($0) as? PdfDictionary }
        XCTAssertEqual(fields.map { PageTestFiles.text($0["T"]) }, ["r", "r_2"])
        for field in fields { XCTAssertEqual(again.array(field, "Kids")?.items.count, 2) }
    }
}
