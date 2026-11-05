import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Structure/DestinationTests.cs: the same cases.

final class DestinationTests: XCTestCase {
    private func array(_ document: PdfDocument, _ page: Int, _ rest: String) -> PdfObject {
        PdfArray([document.pages[page].reference] + parseItems(rest))
    }

    private func parseItems(_ rest: String) -> [PdfObject] {
        rest.split(separator: " ").map { token -> PdfObject in
            if token == "null" { return PdfNull.instance }
            if token.hasPrefix("/") { return PdfName(String(token.dropFirst())) }
            return PdfNumber(String(token))
        }
    }

    func test_everyFitModeRoundTrips() throws {
        let cases: [(String, DestinationFit)] = [
            ("/XYZ 10 250 2", .xyz),
            ("/XYZ null null null", .xyz),
            ("/Fit", .fit),
            ("/FitH 120", .fitH),
            ("/FitV 30", .fitV),
            ("/FitR 10 20 100 200", .fitR),
            ("/FitB", .fitB),
            ("/FitBH 99", .fitBH),
            ("/FitBV 5", .fitBV),
        ]
        for (rest, fit) in cases {
            let document = try StructureFixtures.open()
            let parsed = try XCTUnwrap(PdfDestinations.parse(document, array(document, 1, rest)), rest)
            XCTAssertEqual(parsed.pageIndex, 1, rest)
            XCTAssertEqual(parsed.fit, fit, rest)
            let written = PdfDestinations.toObject(document, parsed)
            XCTAssertEqual(parsed, PdfDestinations.parse(document, written), rest)
        }
    }

    func test_valuesAreKeptPerFit() throws {
        let document = try StructureFixtures.open()
        let xyz = try XCTUnwrap(PdfDestinations.parse(document, array(document, 0, "/XYZ 10 250 2")))
        XCTAssertEqual([xyz.left, xyz.top, xyz.zoom], [10, 250, 2])
        let rect = try XCTUnwrap(PdfDestinations.parse(document, array(document, 0, "/FitR 1 2 3 4")))
        XCTAssertEqual([rect.left, rect.bottom, rect.right, rect.top], [1, 2, 3, 4])
        let nulls = try XCTUnwrap(PdfDestinations.parse(document, array(document, 0, "/XYZ null null null")))
        XCTAssertNil(nulls.left)
        XCTAssertNil(nulls.zoom)
    }

    func test_zeroZoomIsWrittenAsNull() throws {
        let document = try StructureFixtures.open()
        let written = try XCTUnwrap(PdfDestinations.toObject(document, PdfDestination(0, .xyz, left: 1, top: 2, zoom: 0)) as? PdfArray)
        XCTAssertTrue(written.items[4] is PdfNull)
    }

    func test_brokenArraysAreNull() throws {
        let document = try StructureFixtures.open()
        XCTAssertNil(PdfDestinations.parse(document, PdfArray([])))
        XCTAssertNil(PdfDestinations.parse(document, PdfArray([document.pages[0].reference])))
        XCTAssertNil(PdfDestinations.parse(document, array(document, 0, "/Bogus 1")))
        XCTAssertNil(PdfDestinations.parse(document, PdfNumber(3)))
        XCTAssertNil(PdfDestinations.parse(document, nil))
    }

    func test_pageThatIsGoneHasIndexMinusOne() throws {
        let document = try StructureFixtures.open()
        let parsed = try XCTUnwrap(PdfDestinations.parse(document, PdfArray([PdfReference(99, 0), PdfName("Fit")])))
        XCTAssertEqual(parsed.pageIndex, -1)
        XCTAssertNil(PdfDestinations.toObject(document, parsed))
        XCTAssertNil(PdfDestinations.locate(document, parsed))
    }

    func test_dictionaryFormUsesD() throws {
        let document = try StructureFixtures.open()
        let dictionary = PdfDictionary()
        dictionary["D"] = array(document, 2, "/Fit")
        XCTAssertEqual(PdfDestinations.parse(document, dictionary)?.pageIndex, 2)
    }

    func test_remoteDestinationUsesPageNumbers() throws {
        let document = try StructureFixtures.open()
        let parsed = try XCTUnwrap(PdfDestinations.parse(document, PdfArray([PdfNumber(7), PdfName("FitH"), PdfNumber(50)]), remote: true))
        XCTAssertEqual(parsed.pageIndex, 7)
        let written = try XCTUnwrap(PdfDestinations.toObject(document, parsed, remote: true) as? PdfArray)
        XCTAssertEqual(written.description, "[7 /FitH 50]")
        XCTAssertEqual(PdfDestinations.parse(document, PdfString(bytes: Array("chap".utf8), isHex: false), remote: true)?.name, "chap")
    }

    func test_locateAppliesRotationAndCropBox() throws {
        let document = try StructureFixtures.open()
        let page = document.pages[0].dictionary
        page["Rotate"] = PdfNumber(90)
        page["CropBox"] = PdfArray([PdfNumber(10), PdfNumber(20), PdfNumber(110), PdfNumber(220)])
        let point = try XCTUnwrap(PdfDestinations.locate(document, PdfDestination(0, .xyz, left: 30, top: 50, zoom: 1.5)))
        let expected = PageGeometry(document.pages[0]).toDisplay(30, 50)
        XCTAssertEqual(point.x, expected.x, accuracy: 1e-6)
        XCTAssertEqual(point.y, expected.y, accuracy: 1e-6)
        XCTAssertEqual(point.zoom, 1.5)
    }

    func test_locateDefaultsToTopLeftAndClamps() throws {
        let document = try StructureFixtures.open()
        let fit = try XCTUnwrap(PdfDestinations.locate(document, PdfDestination(1)))
        XCTAssertEqual([fit.x, fit.y], [0, 0])
        let far = try XCTUnwrap(PdfDestinations.locate(document, PdfDestination(1, .xyz, left: -32768, top: 900000)))
        XCTAssertEqual([far.x, far.y], [0, 0])
        // The fixture pages are 200 by 300 points.
        let fitH = try XCTUnwrap(PdfDestinations.locate(document, PdfDestination(1, .fitH, top: 100)))
        XCTAssertEqual([fitH.x, fitH.y], [0, 200])
    }

    func test_namedDestinationsInTreeAndOldDictionary() throws {
        let document = try StructureFixtures.open()
        let old = PdfDictionary()
        old["old"] = array(document, 0, "/Fit")
        old["shared"] = array(document, 0, "/Fit")
        document.catalog["Dests"] = old
        try PdfDestinations.setNamed(document, "new", PdfDestination(2, .fitH, top: 40))
        try PdfDestinations.setNamed(document, "shared", PdfDestination(1))

        let named = PdfDestinations.named(document)
        XCTAssertEqual(named.map { $0.key }, ["old", "shared", "new"])
        var all: [String: PdfDestination] = [:]
        for entry in named { all[entry.key] = entry.value }
        XCTAssertEqual(all["old"]?.pageIndex, 0)
        XCTAssertEqual(all["shared"]?.pageIndex, 1)
        XCTAssertEqual(all["new"]?.pageIndex, 2)
        XCTAssertEqual(all["new"]?.name, "new")

        // A name already in /Dests is updated there, not copied to the tree.
        let tree = document.dict(document.dict(document.catalog, "Names"), "Dests")
        XCTAssertEqual(PdfNameTree.read(document, tree).map { $0.key }, ["new"])
    }

    func test_namedDestinationsSurviveSaving() throws {
        let document = try StructureFixtures.open()
        for i in 0..<100 { try PdfDestinations.setNamed(document, String(format: "d%03ld", i), PdfDestination(i % 3)) }
        let reopened = try StructureFixtures.reopen(document)
        XCTAssertEqual(PdfDestinations.named(reopened).count, 100)
        XCTAssertEqual(PdfDestinations.find(reopened, "d002")?.pageIndex, 2)
        XCTAssertNil(PdfDestinations.find(reopened, "missing"))
    }

    func test_removeNamed() throws {
        let document = try StructureFixtures.open()
        let old = PdfDictionary()
        old["old"] = array(document, 0, "/Fit")
        document.catalog["Dests"] = old
        try PdfDestinations.setNamed(document, "new", PdfDestination(1))
        XCTAssertTrue(try PdfDestinations.removeNamed(document, "old"))
        XCTAssertTrue(try PdfDestinations.removeNamed(document, "new"))
        XCTAssertFalse(try PdfDestinations.removeNamed(document, "new"))
        XCTAssertTrue(PdfDestinations.named(document).isEmpty)
    }

    func test_aNameResolvesThroughParse() throws {
        let document = try StructureFixtures.open()
        try PdfDestinations.setNamed(document, "intro", PdfDestination(2))
        let byString = try XCTUnwrap(PdfDestinations.parse(document, PdfString(bytes: Array("intro".utf8), isHex: false)))
        XCTAssertEqual(byString.pageIndex, 2)
        XCTAssertEqual(byString.name, "intro")
        let unknown = try XCTUnwrap(PdfDestinations.parse(document, PdfName("nowhere")))
        XCTAssertEqual(unknown.pageIndex, -1)
        XCTAssertEqual(unknown.name, "nowhere")
    }

    func test_nameIsWrittenAsNameOnlyWhereTheFileHasJustAnOldDictionary() throws {
        let document = try StructureFixtures.open()
        let old = PdfDictionary()
        old["old"] = array(document, 0, "/Fit")
        document.catalog["Dests"] = old
        XCTAssertTrue(PdfDestinations.toObject(document, PdfDestination(-1, name: "old")) is PdfName)
        try PdfDestinations.setNamed(document, "new", PdfDestination(1))
        XCTAssertTrue(PdfDestinations.toObject(document, PdfDestination(-1, name: "old")) is PdfString)
    }

    func test_destinationWithoutPageCannotBeNamed() throws {
        let document = try StructureFixtures.open()
        XCTAssertThrowsError(try PdfDestinations.setNamed(document, "x", PdfDestination(9))) { XCTAssertTrue($0 is ArgumentException) }
    }
}
