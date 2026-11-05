import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Structure/NameTreeTests.cs: the same cases. The PdfPig reading of the saved file
// in LargeTreeSurvivesSavingAndPdfPig has no twin; the rest of that test is kept.

final class NameTreeTests: XCTestCase {
    private func entry(_ key: String, _ value: Int) -> (key: String, value: PdfObject) {
        (key: key, value: PdfNumber(value) as PdfObject)
    }

    private func numbered(_ n: Int, _ digits: Int) -> String {
        "n" + String(format: "%0\(digits)ld", n)
    }

    func test_smallTreeIsOneSortedLeaf() throws {
        let document = try StructureFixtures.open(1)
        let root = try PdfNameTree.write(document, nil, [entry("b", 2), entry("a", 1), entry("c", 3), entry("a", 9)])
        XCTAssertNotNil(root["Names"])
        XCTAssertNil(root["Kids"])
        let read = PdfNameTree.read(document, root)
        XCTAssertEqual(read.map { $0.key }, ["a", "b", "c"])
        XCTAssertEqual((read[0].value as? PdfNumber)?.value, 9)
    }

    func test_largeTreeIsSplitWithLimits() throws {
        let document = try StructureFixtures.open(1)
        let entries = (0..<5000).map { entry(numbered($0, 5), $0) }
        let root = try PdfNameTree.write(document, nil, entries)
        let kids = try XCTUnwrap(root["Kids"] as? PdfArray)
        XCTAssertTrue(kids.items.count <= 64)
        let leaf = try XCTUnwrap(document.resolve(kids.items[0]) as? PdfDictionary)
        XCTAssertNotNil(leaf["Limits"])

        let read = PdfNameTree.read(document, root)
        XCTAssertEqual(read.count, 5000)
        XCTAssertEqual(entries.map { $0.key }, read.map { $0.key })
    }

    func test_largeTreeSurvivesSavingAndPdfPig() throws {
        let document = try StructureFixtures.open(1)
        let root = try PdfNameTree.write(document, nil, (0..<300).map { entry(numbered($0, 4), $0) })
        PdfNames.ensure(document)["Dests"] = try document.add(root)
        let reopened = try StructureFixtures.reopen(document)
        let tree = reopened.dict(reopened.dict(reopened.catalog, "Names"), "Dests")
        XCTAssertEqual(PdfNameTree.read(reopened, tree).count, 300)
    }

    func test_rewritingFreesOldNodes() throws {
        let document = try StructureFixtures.open(1)
        let root = try PdfNameTree.write(document, nil, (0..<200).map { entry(numbered($0, 4), $0) })
        let oldKid = try XCTUnwrap((root["Kids"] as? PdfArray)?.items[0] as? PdfReference)
        _ = try PdfNameTree.write(document, root, [entry("only", 1)])
        XCTAssertNil(document.get(oldKid.number))
        XCTAssertNil(root["Kids"])
        XCTAssertEqual(PdfNameTree.read(document, root).count, 1)
    }

    func test_emptyTreeIsValid() throws {
        let document = try StructureFixtures.open(1)
        let root = try PdfNameTree.write(document, nil, [])
        XCTAssertTrue(PdfNameTree.read(document, root).isEmpty)
        XCTAssertTrue(root["Names"] is PdfArray)
    }

    func test_keysKeepTheirBytes() throws {
        let document = try StructureFixtures.open(1)
        let odd = Latin1.string([0xFE, 0xFF, 0x00, 0x41, 0x80])
        let root = try PdfNameTree.write(document, nil, [entry(odd, 1)])
        XCTAssertEqual(PdfNameTree.read(document, root)[0].key, odd)
        XCTAssertEqual(PdfNameTree.textOf(PdfNameTree.keyOf("caf\u{E9}")), "caf\u{E9}")
        XCTAssertEqual(PdfNameTree.textOf(PdfNameTree.keyOf("A\u{416}")), "A\u{416}")
    }

    func test_readsHandWrittenNestedTreeInAnyOrderOfKeys() throws {
        let pdf = TestPdf.withPages(1)
        pdf.obj(20, "<</Kids [21 0 R 22 0 R] /Limits [(a) (z)]>>")
        pdf.obj(21, "<</Names [(a) 1 (b) 2] /Limits [(a) (b)]>>")
        pdf.obj(22, "<</Kids [23 0 R]>>")
        pdf.obj(23, "<</Names [(y) 3 (z) 4]>>")
        let document = try PdfDocument.open(pdf.finish())
        let read = PdfNameTree.read(document, PdfReference(20, 0))
        XCTAssertEqual(read.map { $0.key }, ["a", "b", "y", "z"])
    }

    func test_loopsAndJunkAreCutOff() throws {
        let pdf = TestPdf.withPages(1)
        pdf.obj(20, "<</Kids [20 0 R 21 0 R 99 0 R 5 (x) null] /Names [(a) 1 (odd)]>>")
        pdf.obj(21, "<</Names [1 2 (k) 3 (m)]>>")
        let document = try PdfDocument.open(pdf.finish())
        let read = PdfNameTree.read(document, PdfReference(20, 0))
        XCTAssertEqual(read.map { $0.key }, ["a", "k"])
    }

    func test_deepChainIsCutOff() throws {
        let pdf = TestPdf.withPages(1)
        for i in 0..<100 { pdf.obj(20 + i, "<</Kids [\(21 + i) 0 R] /Names [(k\(i)) \(i)]>>") }
        let document = try PdfDocument.open(pdf.finish())
        let read = PdfNameTree.read(document, PdfReference(20, 0))
        XCTAssertTrue((1...40).contains(read.count), "\(read.count)")
    }

    func test_numberTreeRoundTrips() throws {
        let document = try StructureFixtures.open(1)
        let entries: [(key: Int, value: PdfObject)] = [7, 0, 300, 12].map { (key: $0, value: PdfNumber($0 * 2) as PdfObject) }
        let root = try PdfNumberTree.write(document, nil, entries)
        let read = PdfNumberTree.read(document, root)
        XCTAssertEqual(read.map { $0.key }, [0, 7, 12, 300])
        XCTAssertEqual((read[3].value as? PdfNumber)?.value, 600)
    }

    func test_largeNumberTreeIsSplit() throws {
        let document = try StructureFixtures.open(1)
        let entries: [(key: Int, value: PdfObject)] = (0..<1000).map { (key: $0, value: PdfNumber($0) as PdfObject) }
        let root = try PdfNumberTree.write(document, nil, entries)
        XCTAssertNotNil(root["Kids"])
        XCTAssertEqual(PdfNumberTree.read(document, root).count, 1000)
    }

    func test_numberTreeIgnoresNonIntegerKeys() throws {
        let pdf = TestPdf.withPages(1)
        pdf.obj(20, "<</Nums [0 (a) 1.5 (b) 2 (c) (x) (d)]>>")
        let document = try PdfDocument.open(pdf.finish())
        XCTAssertEqual(PdfNumberTree.read(document, PdfReference(20, 0)).map { $0.key }, [0, 2])
    }
}
