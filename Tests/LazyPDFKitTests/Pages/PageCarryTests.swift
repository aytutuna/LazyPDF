import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageCarryTests.cs: the same cases.

final class PageCarryTests: XCTestCase {
    // Six pages (objects 4 to 9). Bookmarks: Part A (Ch1, Ch2), Part B (Ch3, Ch4 by action), Ch5 by name, Ch6.
    // Labels are i, ii, iii and then 1, 2, 3. Names: three and five.
    private static func fixture(_ title: String? = nil, brokenFile: Bool = false) throws -> PdfDocument {
        try PdfDocument.open(PageTestFiles.make(6,
            "/Outlines 16 0 R /PageLabels <</Nums [0 <</S /r>> 3 <</S /D>>]>> /Lang (en-CA) /Metadata 25 0 R " +
            "/Names <</Dests <</Names [(five) [8 0 R /Fit] (three) [6 0 R /Fit]]>> /EmbeddedFiles <</Names [(note.txt) 27 0 R]>>>>",
            add: { pdf in
                pdf.obj(16, "<</Type /Outlines /First 17 0 R /Last 24 0 R /Count 8>>")
                pdf.obj(17, "<</Title (Part A) /Parent 16 0 R /Next 20 0 R /First 18 0 R /Last 19 0 R /Count 2>>")
                pdf.obj(18, "<</Title (Ch1) /Parent 17 0 R /Next 19 0 R /Dest [4 0 R /Fit]>>")
                pdf.obj(19, "<</Title (Ch2) /Parent 17 0 R /Prev 18 0 R /Dest [5 0 R /Fit]>>")
                pdf.obj(20, "<</Title (Part B) /Parent 16 0 R /Prev 17 0 R /Next 23 0 R /First 21 0 R /Last 22 0 R /Count 2>>")
                pdf.obj(21, "<</Title (Ch3) /Parent 20 0 R /Next 22 0 R /Dest [6 0 R /Fit]>>")
                pdf.obj(22, "<</Title (Ch4) /Parent 20 0 R /Prev 21 0 R /A <</S /GoTo /D [7 0 R /Fit]>>>>")
                pdf.obj(23, "<</Title (Ch5) /Parent 16 0 R /Prev 20 0 R /Next 24 0 R /Dest (five)>>")
                pdf.obj(24, "<</Title (Ch6) /Parent 16 0 R /Prev 23 0 R /Dest [9 0 R /Fit]>>")
                pdf.stream(25, "/Type /Metadata /Subtype /XML", "<x:xmpmeta>fixture</x:xmpmeta>")
                pdf.stream(26, brokenFile ? "/Type /EmbeddedFile /Filter /FlateDecode" : "/Type /EmbeddedFile", "hello")
                pdf.obj(27, "<</Type /Filespec /F (note.txt) /UF (note.txt) /EF <</F 26 0 R>>>>")
                pdf.obj(28, "<</Title (\(title ?? ""))>>")
            },
            trailerExtra: title == nil ? "" : "/Info 28 0 R"))
    }

    private func dump(_ items: [OutlineItem]) -> String {
        items.map { item in
            item.title + (item.destination.map { ">\($0.pageIndex)" } ?? "") + (item.children.isEmpty ? "" : "[" + dump(item.children) + "]")
        }.joined(separator: ",")
    }

    private func bookmarks(_ document: PdfDocument) throws -> String {
        dump(Outline.read(try PdfDocument.open(try document.saveRewrite())).items)
    }

    private func names(_ document: PdfDocument) throws -> String {
        PdfDestinations.named(try PdfDocument.open(try document.saveRewrite())).map { "\($0.key)>\($0.value.pageIndex)" }.joined(separator: ",")
    }

    private func files(_ document: PdfDocument) throws -> String {
        let again = try PdfDocument.open(try document.saveRewrite())
        return try PdfAttachments.list(again).map { "\($0.name)=\(Latin1.string(try PdfAttachments.extract(again, $0)))" }.joined(separator: ",")
    }

    private func holds(_ file: [UInt8], _ marker: String) throws -> Bool {
        if TestPdf.contains(file, marker) { return true }
        let document = try PdfDocument.open(file)
        for number in document.objectNumbers {
            switch document.get(number) {
            case let stream as PdfStream:
                if Latin1.string(try document.data(stream)).contains(marker) { return true }
            case let found as PdfDictionary:
                if found.description.contains(marker) { return true }
            case let found as PdfArray:
                if found.description.contains(marker) { return true }
            default:
                break
            }
        }
        return false
    }

    func test_extractKeepsWhatBelongsToThePagesTaken() throws {
        let part = try PageAssembly.extract(try Self.fixture("Source"), [2, 3])
        XCTAssertEqual(try bookmarks(part), "Part B[Ch3>0,Ch4>1]")
        XCTAssertEqual(PdfPageLabels.labels(try PdfDocument.open(try part.saveRewrite())), ["iii", "1"])
        XCTAssertEqual(try names(part), "three>0")
        XCTAssertEqual(try files(part), "note.txt=hello")
        let again = try PdfDocument.open(try part.saveRewrite())
        XCTAssertEqual(PageTestFiles.text(again.catalog["Lang"]), "en-CA")
        XCTAssertTrue(Latin1.string(try again.data(try XCTUnwrap(again.stream(again.catalog, "Metadata")))).contains("fixture"))
    }

    func test_importAddsTheBookmarksOfTheImportedPagesAtTheEnd() throws {
        let target = try Self.fixture()
        try PageOperations.importPages(target, try Self.fixture(), [3, 0], 1)
        XCTAssertEqual(try bookmarks(target), "Part A[Ch1>0,Ch2>3],Part B[Ch3>4,Ch4>5],Ch5>6,Ch6>7,Part A[Ch1>2],Part B[Ch4>1]")
    }

    func test_importFromTheSameDocumentAddsNoBookmarks() throws {
        let target = try Self.fixture()
        try PageOperations.importPages(target, target, [0], 1)
        XCTAssertEqual(try bookmarks(target), "Part A[Ch1>0,Ch2>2],Part B[Ch3>3,Ch4>4],Ch5>5,Ch6>6")
    }

    func test_nothingThatReachesAPageLeftOutIsWritten() throws {
        let bytes = try PageAssembly.extract(try Self.fixture(), [2, 3]).saveRewrite()
        for marker in ["Page 1", "Page 2", "Ch1", "Ch2", "Part A", "Ch5", "Ch6", "five"] {
            XCTAssertFalse(try holds(bytes, marker), marker)
        }
    }

    func test_anItemWithAnActionOrANameIsCarriedExplicit() throws {
        let part = try PageAssembly.extract(try Self.fixture(), [3, 4])
        XCTAssertEqual(try bookmarks(part), "Part B[Ch4>0],Ch5>1")
        XCTAssertEqual(try names(part), "five>1")
        let items = Outline.read(try PdfDocument.open(try part.saveRewrite())).items
        for item in items.flatMap({ $0.children + [$0] }) { XCTAssertNil(item.destination?.name) }
    }

    func test_aLabelRangeWithAGapKeepsCounting() throws {
        let part = try PageAssembly.extract(try Self.fixture(), [0, 2, 5, 3])
        XCTAssertEqual(PdfPageLabels.labels(try PdfDocument.open(try part.saveRewrite())), ["i", "iii", "3", "1"])
    }

    func test_aFileWithoutLabelsOrBookmarksGetsNone() throws {
        let again = try PdfDocument.open(try PageAssembly.extract(try PageTestFiles.open(3), [0, 1]).saveRewrite())
        XCTAssertTrue(PdfPageLabels.read(again).isEmpty)
        XCTAssertTrue(Outline.read(again).items.isEmpty)
        XCTAssertNil(again.catalog["Lang"])
        XCTAssertNil(again.catalog["Names"])
    }

    func test_theXmpOnlyComesWithTheInfo() throws {
        let again = try PdfDocument.open(try PageAssembly.extract(try Self.fixture(), [0]).saveRewrite())
        XCTAssertNil(again.catalog["Metadata"])
        XCTAssertNotNil(again.catalog["Lang"])
    }

    private static let claimingPacket =
        "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" +
        "<rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\" xmlns:pdfuaid=\"http://www.aiim.org/pdfua/ns/id/\" " +
        "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" pdfaid:part=\"2\"><pdfaid:conformance>B</pdfaid:conformance><pdfuaid:part>1</pdfuaid:part>" +
        "<dc:format>application/pdf</dc:format></rdf:Description></rdf:RDF></x:xmpmeta>"

    private static func claiming() throws -> PdfDocument {
        try PdfDocument.open(PageTestFiles.make(2, "/Metadata 25 0 R",
            add: { pdf in
                pdf.stream(25, "/Type /Metadata /Subtype /XML", claimingPacket)
                pdf.obj(28, "<</Title (T)>>")
            },
            trailerExtra: "/Info 28 0 R"))
    }

    private func xmp(_ document: PdfDocument) throws -> String {
        let again = try PdfDocument.open(try document.saveRewrite())
        return String(decoding: try again.data(again.stream(again.catalog, "Metadata")!), as: UTF8.self)
    }

    func test_extractedXmpKeepsItsPropertiesButNotThePdfAndPdfUaClaims() throws {
        let text = try xmp(try PageAssembly.extract(try Self.claiming(), [0]))
        XCTAssertFalse(text.replacingOccurrences(of: "xmlns:pdfaid", with: "").contains("pdfaid:"))
        XCTAssertFalse(text.replacingOccurrences(of: "xmlns:pdfuaid", with: "").contains("pdfuaid:"))
        XCTAssertTrue(text.contains("application/pdf"))
    }

    func test_mergedXmpHasNoPdfAClaim() throws {
        let text = try xmp(try PageAssembly.merge([MergeSource(try Self.claiming()), MergeSource(try Self.claiming(), [1])]))
        XCTAssertFalse(text.replacingOccurrences(of: "xmlns:pdfaid", with: "").contains("pdfaid:"))
        XCTAssertTrue(text.contains("application/pdf"))
    }

    func test_mergeMakesOneItemForEachSourceWithBookmarks() throws {
        let merged = try PageAssembly.merge([MergeSource(try Self.fixture("First")), MergeSource(try Self.fixture("Second"), [2, 3]),
                                             MergeSource(try PageTestFiles.open(1))])
        XCTAssertEqual(try bookmarks(merged), "First[Part A[Ch1>0,Ch2>1],Part B[Ch3>2,Ch4>3],Ch5>4,Ch6>5],Second[Part B[Ch3>6,Ch4>7]]")
        XCTAssertTrue(PdfPageLabels.read(try PdfDocument.open(try merged.saveRewrite())).isEmpty)
    }

    func test_mergeTitlesComeFromTheCallerWhenTheFileHasNone() throws {
        let merged = try PageAssembly.merge([MergeSource(try Self.fixture(), [0]), MergeSource(try Self.fixture(), [1]),
                                             MergeSource(try PageTestFiles.open(1))], titles: ["One", "Two", "Three"])
        XCTAssertEqual(try bookmarks(merged), "One[Part A[Ch1>0]],Two[Part A[Ch2>1]]")
    }

    func test_mergeCarriesEveryAttachmentUnderAFreshNameAndTheFirstSourcesInfoAndXmp() throws {
        let merged = try PageAssembly.merge([MergeSource(try Self.fixture("First")), MergeSource(try Self.fixture("Second"), [5])])
        XCTAssertEqual(try files(merged), "note (2).txt=hello,note.txt=hello")
        XCTAssertEqual(try names(merged), "five>4,three>2")
        let again = try PdfDocument.open(try merged.saveRewrite())
        XCTAssertNotNil(again.catalog["Metadata"])
        XCTAssertEqual(PageTestFiles.text(try XCTUnwrap(again.info)["Title"]), "First")
    }

    func test_anAttachmentThatDoesNotDecodeIsSkippedAndCounted() throws {
        let part = try PageAssembly.extract(try Self.fixture(brokenFile: true), [2, 3])
        XCTAssertEqual(try files(part), "")
        XCTAssertEqual(part.skippedAttachments, 1)
        let merged = try PageAssembly.merge([MergeSource(try Self.fixture(brokenFile: true)), MergeSource(try Self.fixture(), [5])])
        XCTAssertEqual(try files(merged), "note.txt=hello")
        XCTAssertEqual(merged.skippedAttachments, 1)
        XCTAssertEqual(try PageAssembly.splitAt(try Self.fixture(brokenFile: true), [3]).map(\.skippedAttachments), [1, 0])
    }

    func test_eachPartOfASplitCarriesItsOwn() throws {
        let parts = try PageAssembly.splitAt(try Self.fixture(), [3])
        XCTAssertEqual(try bookmarks(parts[0]), "Part A[Ch1>0,Ch2>1],Part B[Ch3>2]")
        XCTAssertEqual(try bookmarks(parts[1]), "Part B[Ch4>0],Ch5>1,Ch6>2")
        XCTAssertEqual(PdfPageLabels.labels(try PdfDocument.open(try parts[0].saveRewrite())), ["i", "ii", "iii"])
        XCTAssertEqual(PdfPageLabels.labels(try PdfDocument.open(try parts[1].saveRewrite())), ["1", "2", "3"])
        XCTAssertEqual(try names(parts[0]), "three>2")
        XCTAssertEqual(try names(parts[1]), "five>1")
        XCTAssertEqual(try parts.map(files), ["note.txt=hello", ""])
    }

    func test_attachmentsGoIntoTheFirstPartOfASplitBySizeOnly() throws {
        let document = try Self.fixture()
        let one = try PageAssembly.extract(document, [0]).saveRewrite().count
        let parts = try PageAssembly.splitBySize(document, one + 200)
        XCTAssertTrue(parts.count > 1)
        XCTAssertEqual(try files(parts[0]), "note.txt=hello")
        for part in parts.dropFirst() { XCTAssertEqual(try files(part), "") }
        let byRanges = try PageAssembly.splitByRanges(document, [[0, 1], [2], [3]])
        XCTAssertEqual(try byRanges.map(files), ["note.txt=hello", "", ""])
    }
}
