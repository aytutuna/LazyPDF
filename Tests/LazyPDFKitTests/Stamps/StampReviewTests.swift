import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Stamps/StampReviewTests.cs: the same cases. In AFailedUpdateKeepsTheOldRun the spec
// that cannot be drawn is a text no font has, because an empty spec is a precondition here and cannot be caught. The tests
// from RenumberMarker on have no C# twin: it is the hand-written replacement of a Regex.

final class StampReviewTests: XCTestCase {
    func test_runsWithTheSameIdFromTwoFilesStayApartInAMerge() throws {
        let a = try StampKit.doc(1)
        let b = try StampKit.doc(1)
        try PdfStamper(a).addWatermark(WatermarkSpec(text: "DRAFT"))
        try PdfStamper(b).addWatermark(WatermarkSpec(text: "CONFIDENTIAL"))

        let merged = try PageAssembly.merge([MergeSource(a), MergeSource(b)])

        let stamper = PdfStamper(merged)
        let runs = stamper.list()
        XCTAssertEqual(runs.count, 2)
        let confidential = try XCTUnwrap(runs.first { $0.label == "CONFIDENTIAL" })
        XCTAssertEqual(stamper.remove(confidential.id), 1)
        XCTAssertEqual(try StampKit.single(stamper.list()).label, "DRAFT")
        let reopened = try PdfDocument.open(try merged.saveRewrite())
        XCTAssertEqual(StampKit.text(StampKit.glyphs(reopened, 0)), "DRAFT")
        XCTAssertTrue(StampKit.glyphs(reopened, 1).isEmpty)
    }

    func test_twoRunsFromEachOfTwoFilesStayApartInAMerge() throws {
        let a = try StampKit.doc(1)
        let b = try StampKit.doc(1)
        for (document, first, second) in [(a, "AONE", "ATWO"), (b, "BONE", "BTWO")] {
            try PdfStamper(document).addWatermark(WatermarkSpec(text: first))
            try PdfStamper(document).addWatermark(WatermarkSpec(text: second))
        }

        let merged = try PageAssembly.merge([MergeSource(a), MergeSource(b)])

        let stamper = PdfStamper(merged)
        let runs = stamper.list()
        XCTAssertEqual(runs.compactMap { $0.label }.sorted(), ["AONE", "ATWO", "BONE", "BTWO"])
        XCTAssertEqual(Set(runs.map { $0.id }).count, 4)
        XCTAssertEqual(StampKit.text(StampKit.glyphs(merged, 1)), "BONEBTWO")
        let content = StampKit.latin(merged, 1)
        let fonts = (merged.dict(merged.dict(merged.pages[1].dictionary, "Resources"), "Font")?.entries ?? []).map { $0.key }
        for run in runs where run.pages.contains(1) {
            XCTAssertTrue(content.contains("/LazyPDF \(run.id)"), "run \(run.id)")
            XCTAssertTrue(fonts.contains("LPS\(run.id)_F"), "run \(run.id)")
            XCTAssertTrue(content.contains("/LPS\(run.id)_F "), "run \(run.id)")
        }
        let bTwo = try XCTUnwrap(runs.first { $0.label == "BTWO" })
        XCTAssertEqual(bTwo.pages, [1])
        XCTAssertEqual(stamper.remove(bTwo.id), 1)
        XCTAssertEqual(StampKit.text(StampKit.glyphs(merged, 0)), "AONEATWO")
        XCTAssertEqual(StampKit.text(StampKit.glyphs(merged, 1)), "BONE")
    }

    func test_labelsThatDifferOnlyInNormalisationAreDifferentRuns() throws {
        let a = try StampKit.doc(1)
        let b = try StampKit.doc(1)
        try PdfStamper(a).addWatermark(WatermarkSpec(text: "AB", behind: true))
        try PdfStamper(b).addWatermark(WatermarkSpec(text: "AB", behind: true))
        let first = try marker(a, 0)
        first["Label"] = PdfText.toObject("\u{e9}")
        let second = try marker(b, 0)
        second["Label"] = PdfText.toObject("e\u{301}")

        let merged = try PageAssembly.merge([MergeSource(a), MergeSource(b)])

        let runs = PdfStamper(merged).list()
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.compactMap { $0.label?.unicodeScalars.map { $0.value } }, [[0xE9], [0x65, 0x301]])
    }

    // The first stream on the page that carries a run's marker.
    private func marker(_ document: PdfDocument, _ page: Int) throws -> PdfDictionary {
        let streams = try StampKit.contentStreams(document, page)
        return try XCTUnwrap(streams.compactMap { document.dict($0, "LazyPDF") }.first { $0["Id"] != nil })
    }

    func test_aMarkerIdOutsideAnIntIsNotARun() throws {
        let document = try StampKit.doc(1)
        let stamper = PdfStamper(document)
        try stamper.addWatermark(WatermarkSpec(text: "ONE", behind: true))
        let mark = try marker(document, 0)
        mark["Id"] = PdfNumber(4_294_967_297)

        XCTAssertTrue(stamper.list().isEmpty)
        XCTAssertEqual(stamper.remove(1), 0)
        XCTAssertEqual(stamper.removeAll(), 0)
        XCTAssertEqual(try stamper.addWatermark(WatermarkSpec(text: "TWO")).id, 1)
    }

    func test_anIdAtTheTopOfTheRangeGetsAFreshOne() throws {
        let document = try StampKit.doc(1)
        let stamper = PdfStamper(document)
        try stamper.addWatermark(WatermarkSpec(text: "ONE", behind: true))
        let mark = try marker(document, 0)
        mark["Id"] = PdfNumber(Int(Int32.max))

        XCTAssertEqual(try stamper.addWatermark(WatermarkSpec(text: "TWO", behind: true)).id, 1)
        XCTAssertEqual(try stamper.addWatermark(WatermarkSpec(text: "THREE", behind: true)).id, 2)
        XCTAssertEqual(stamper.list().map { $0.id }, [1, 2, Int(Int32.max)])
        XCTAssertEqual(stamper.remove(Int(Int32.max)), 1)
        XCTAssertEqual(stamper.list().count, 2)
    }

    func test_aLayerListThatHoldsItselfIsStrippedOnce() throws {
        let document = try StampKit.doc(1)
        let stamper = PdfStamper(document)
        let run = try stamper.addWatermark(WatermarkSpec(text: "DRAFT", layerName: "Marks"))
        let order = PdfArray([])
        let reference = try document.add(order)
        for _ in 0..<40 { order.items.append(reference) }
        let properties = try XCTUnwrap(document.dict(document.catalog, "OCProperties"))
        let configuration = try XCTUnwrap(document.dict(properties, "D"))
        configuration["Order"] = reference

        stamper.remove(run.id)
        XCTAssertTrue(stamper.list().isEmpty)
    }

    func test_aKindIsReadByItsNameOnly() throws {
        let document = try StampKit.doc(1)
        let stamper = PdfStamper(document)
        try stamper.addHeaderFooter(HeaderFooterSpec(footer: HeaderFooterBand("", "x", "")))
        XCTAssertEqual(try StampKit.single(stamper.list()).kind, .headerFooter)
        let mark = try marker(document, 0)
        for odd in ["3", "99", "Background,Bates", " Bates", "bates"] {
            mark["Kind"] = PdfName(odd)
            XCTAssertEqual(try StampKit.single(stamper.list()).kind, .watermark, odd)
        }
        mark["Kind"] = PdfName("Bates")
        XCTAssertEqual(try StampKit.single(stamper.list()).kind, .bates)
    }

    func test_aRunSharedByADuplicatedPageIsRemovedFromBoth() throws {
        let document = try StampKit.doc(1)
        let stamper = PdfStamper(document)
        let run = try stamper.addWatermark(WatermarkSpec(text: "DRAFT"))
        try PageOperations.duplicate(document, [0])

        XCTAssertEqual(stamper.remove(run.id), 2)
        XCTAssertTrue(stamper.list().isEmpty)
    }

    func test_aFailedUpdateKeepsTheOldRun() throws {
        let document = try StampKit.doc(2)
        let stamper = PdfStamper(document)
        let run = try stamper.addWatermark(WatermarkSpec(text: "KEEP"))

        XCTAssertThrowsError(try stamper.update(run.id, WatermarkSpec(text: "Şişli"))) { error in
            XCTAssertTrue(error is InvalidOperationException)
        }

        let info = try StampKit.single(stamper.list())
        XCTAssertEqual(info.label, "KEEP")
        XCTAssertEqual(info.pages.count, 2)
    }

    func test_aBackgroundArtifactHasABox() throws {
        let document = try StampKit.doc(1)
        try PdfStamper(document).addBackground(BackgroundSpec(color: .gray(0.9)))
        let content = Latin1.string(document.pages[0].contents())
        XCTAssertTrue(content.contains("/BBox"))
    }

    func test_renumberMarkerChangesTheNumberAfterTheKeyOnly() {
        XCTAssertEqual(StampRuns.renumberMarker("/Artifact <</LazyPDF 1>> BDC", 1, 7), "/Artifact <</LazyPDF 7>> BDC")
        XCTAssertEqual(StampRuns.renumberMarker("/LazyPDF 1/LazyPDF 1", 1, 10), "/LazyPDF 10/LazyPDF 10")
        XCTAssertEqual(StampRuns.renumberMarker("/LazyPDF 1", 1, 2), "/LazyPDF 2")
        XCTAssertEqual(StampRuns.renumberMarker("/LazyPDF\r\n\t 12 /LazyPDF\n12", 12, 3), "/LazyPDF\r\n\t 3 /LazyPDF\n3")
    }

    func test_renumberMarkerLeavesWhatIsNotTheMarker() {
        XCTAssertEqual(StampRuns.renumberMarker("/LazyPDF 12 /LazyPDF 1 /LazyPDF 10", 1, 7), "/LazyPDF 12 /LazyPDF 7 /LazyPDF 10")
        XCTAssertEqual(StampRuns.renumberMarker("/LazyPDF1 /LazyPDFX 1 /Lazy 1 LazyPDF 1", 1, 7), "/LazyPDF1 /LazyPDFX 1 /Lazy 1 LazyPDF 1")
        XCTAssertEqual(StampRuns.renumberMarker("/LazyPDF", 1, 7), "/LazyPDF")
        XCTAssertEqual(StampRuns.renumberMarker("/LazyPDF ", 1, 7), "/LazyPDF ")
        XCTAssertEqual(StampRuns.renumberMarker("", 1, 7), "")
    }

    func test_renumberMarkerTakesWhiteSpaceAsDotNetDoes() {
        // \s is the C0 white space, space, U+0085 and U+00A0 among the Latin-1 characters.
        XCTAssertEqual(StampRuns.renumberMarker("/LazyPDF\u{85}1 /LazyPDF\u{a0}1 /LazyPDF\u{b}1 /LazyPDF\u{c}1", 1, 5),
                       "/LazyPDF\u{85}5 /LazyPDF\u{a0}5 /LazyPDF\u{b}5 /LazyPDF\u{c}5")
        XCTAssertEqual(StampRuns.renumberMarker("/LazyPDF\u{1c}1 /LazyPDF\u{2}1 /LazyPDF\u{b2}1", 1, 5),
                       "/LazyPDF\u{1c}1 /LazyPDF\u{2}1 /LazyPDF\u{b2}1")
    }
}
