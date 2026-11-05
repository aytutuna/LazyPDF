import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/ChangeTrackingTests.cs: the same cases.

final class ChangeTrackingTests: XCTestCase {
    private func open() throws -> PdfDocument {
        try PdfDocument.open(TestPdf.simple(2))
    }

    func test_readingChangesNothing() throws {
        let document = try open()
        for page in document.pages { _ = page.contents() }
        _ = document.info
        _ = document.get(2)
        XCTAssertTrue(document.changedObjects().isEmpty)
        XCTAssertTrue(document.deletedObjects.isEmpty)
        XCTAssertFalse(document.trailerChanged)
    }

    func test_changeInsideANestedValueIsFound() throws {
        let document = try open()
        let kids = try XCTUnwrap(document.array(document.dict(document.catalog, "Pages"), "Kids"))
        kids.items.append(PdfReference(3, 0))
        XCTAssertEqual(document.changedObjects(), [2])

        document.pages[0].dictionary["Rotate"] = PdfNumber(90)
        XCTAssertEqual(document.changedObjects(), [2, 3])
    }

    func test_changeToADirectValueOfTheCatalogIsFound() throws {
        let document = try open()
        document.catalog["Lang"] = PdfString(bytes: TestPdf.latin("tr"), isHex: false)
        XCTAssertEqual(document.changedObjects(), [1])
    }

    func test_settingTheDataOfAStreamIsAChange() throws {
        let document = try open()
        let stream = try XCTUnwrap(document.resolve(document.pages[0].dictionary["Contents"], as: PdfStream.self))
        XCTAssertTrue(document.changedObjects().isEmpty)
        stream.data = TestPdf.latin("q Q")
        XCTAssertEqual(document.changedObjects(), [stream.number])
        XCTAssertEqual(TestPdf.text(document.pages[0].contents()), "q Q")
    }

    func test_changingAStreamsDictionaryIsAChange() throws {
        let document = try open()
        let stream = try XCTUnwrap(document.resolve(document.pages[1].dictionary["Contents"], as: PdfStream.self))
        stream.dictionary["Subtype"] = PdfName("Form")
        XCTAssertEqual(document.changedObjects(), [stream.number])
    }

    func test_objectsAddedAreNewAndCountedFromTheEnd() throws {
        let document = try open()
        let next = document.nextObjectNumber
        let reference = try document.add(PdfDictionary())
        XCTAssertEqual(reference.number, next)
        XCTAssertEqual(document.nextObjectNumber, next + 1)
        XCTAssertEqual(document.changedObjects(), [reference.number])
        XCTAssertTrue(document.objectNumbers.contains(reference.number))
        XCTAssertNotNil(document.resolve(reference))
    }

    func test_replacingAnObjectIsAChangeEvenIfEqual() throws {
        let document = try open()
        document.set(3, try XCTUnwrap(document.get(3)))
        XCTAssertEqual(document.changedObjects(), [3])
    }

    func test_deletedObjectsReadAsNullAndAreListed() throws {
        let document = try open()
        document.delete(3)
        XCTAssertNil(document.get(3))
        XCTAssertNil(document.resolve(PdfReference(3, 0)))
        XCTAssertEqual(document.deletedObjects, [3])
        XCTAssertFalse(document.objectNumbers.contains(3))
        XCTAssertTrue(document.changedObjects().isEmpty)
        document.delete(3)
        document.delete(999)
        XCTAssertEqual(document.deletedObjects, [3])
    }

    func test_objectDeletedBeforeItWasLoadedIsStillFree() throws {
        let document = try open()
        document.delete(4)
        XCTAssertNil(document.get(4))
        XCTAssertEqual(document.deletedObjects, [4])
    }

    func test_objectAddedAndDeletedLeavesNoTrace() throws {
        let document = try open()
        let reference = try document.add(PdfDictionary())
        document.delete(reference.number)
        XCTAssertTrue(document.changedObjects().isEmpty)
        XCTAssertTrue(document.deletedObjects.isEmpty)
    }

    func test_trailerChangeIsSeen() throws {
        let document = try open()
        document.trailer["Info"] = try document.add(PdfDictionary())
        XCTAssertTrue(document.trailerChanged)
    }

    func test_encryptedStringsAreComparedAfterDecryption() throws {
        let security = PdfSecurity.create(userPassword: "", ownerPassword: "o", permissions: .all, strength: .aes128,
                                          firstId: [UInt8](repeating: 0, count: 16), random: SeededRandom(1))
        let lang = Hex.string(security.encryptString(1, 0, TestPdf.latin("en")))
        let pdf = TestPdf("%PDF-1.6\n")
            .obj(1, "<</Type /Catalog /Pages 2 0 R /Lang <\(lang)>>>")
            .obj(2, "<</Type /Pages /Kids [] /Count 0>>")
            .obj(3, security.dictionary.description)
        let zeros = String(repeating: "0", count: 32)
        let document = try PdfDocument.open(pdf.finish("/Root 1 0 R /Encrypt 3 0 R /ID [<\(zeros)> <\(zeros)>]"))
        XCTAssertEqual(TestPdf.text(try XCTUnwrap(document.catalog["Lang"] as? PdfString).bytes), "en")
        XCTAssertTrue(document.changedObjects().isEmpty)
    }

    func test_startAndSizeOfTheFileAreKnown() throws {
        let file = TestPdf.simple(1)
        let document = try PdfDocument.open(file)
        XCTAssertEqual(document.length, file.count)
        XCTAssertEqual(document.startXref, file.lastIndexOf(TestPdf.latin("xref\n0")))
        XCTAssertFalse(document.xrefIsStream)
        XCTAssertFalse(document.xrefRebuilt)
        XCTAssertEqual(document.nextObjectNumber, 5)
        XCTAssertEqual(document.generationOf(1), 0)
    }
}
