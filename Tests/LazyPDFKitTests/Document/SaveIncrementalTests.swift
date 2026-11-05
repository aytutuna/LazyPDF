import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/SaveIncrementalTests.cs: the same cases, except PdfPigReadsTheUpdate,
// whose only assertions are PdfPig's (there is no Swift PdfPig).

final class SaveIncrementalTests: XCTestCase {
    private func text(_ bytes: [UInt8]) -> String { Latin1.string(bytes) }

    private func string(_ value: PdfObject?) throws -> String {
        text(try XCTUnwrap(value as? PdfString).bytes)
    }

    func test_originalBytesStayAndTheChangeIsThere() throws {
        for kind in SaveFixtures.kinds {
            let original = try SaveFixtures.make(kind)
            let document = try PdfDocument.open(original)
            try SaveFixtures.edit(document)
            let saved = try document.saveIncremental()

            XCTAssertGreaterThan(saved.count, original.count, kind)
            XCTAssertEqual(Array(saved[0..<original.count]), original, kind)

            let reopened = try PdfDocument.open(saved)
            XCTAssertTrue(reopened.repairs.isEmpty, kind)
            XCTAssertEqual(SaveFixtures.title(reopened), "New title", kind)
            XCTAssertEqual(try string(reopened.info?["Author"]), "Someone", kind)
            XCTAssertEqual(reopened.pages.count, 2, kind)
            XCTAssertEqual(text(reopened.pages[0].contents()), SaveFixtures.pageOne, kind)
            XCTAssertTrue(text(reopened.pages[1].contents()).contains("Changed"), kind)
            let extra = reopened.dict(reopened.catalog, "Extra")
            XCTAssertEqual(try string(extra?["Note"]), "Added note", kind)
            XCTAssertEqual(reopened.isEncrypted, kind.hasPrefix("aes"), kind)
        }
    }

    func test_nothingChangedAddsNothing() throws {
        let original = SaveFixtures.table()
        let document = try PdfDocument.open(original)
        _ = document.pages[0].contents()
        XCTAssertEqual(try document.saveIncremental(), original)
    }

    func test_onlyWhatChangedIsWritten() throws {
        let original = SaveFixtures.table()
        let document = try PdfDocument.open(original)
        document.info?["Title"] = PdfString(bytes: Latin1.bytes("Other"), isHex: false)
        let update = text(Array(try document.saveIncremental()[original.count...]))

        XCTAssertTrue(update.contains("7 0 obj"))
        XCTAssertFalse(update.contains("1 0 obj"))
        XCTAssertFalse(update.contains("5 0 obj"))
        XCTAssertTrue(update.contains("xref\n7 1\n"))
        XCTAssertTrue(update.contains("/Prev \(document.startXref)"))
        XCTAssertTrue(update.contains("/Size 8"))
        XCTAssertTrue(update.contains("/Root 1 0 R"))
        XCTAssertTrue(update.contains("/Info 7 0 R"))
    }

    func test_sectionIsOfTheKindTheFileEndsWith() throws {
        for (kind, stream) in [("table", false), ("hybrid", false), ("stream", true), ("objects", true)] {
            let original = try SaveFixtures.make(kind)
            let document = try PdfDocument.open(original)
            try SaveFixtures.edit(document)
            let saved = try document.saveIncremental()
            let update = Array(saved[original.count...])

            XCTAssertEqual(TestPdf.contains(update, "/Type /XRef"), stream, kind)
            XCTAssertEqual(TestPdf.contains(update, "\nxref\n"), !stream, kind)
            XCTAssertFalse(TestPdf.contains(update, "XRefStm"), kind)
            XCTAssertTrue(update.hasPattern(TestPdf.latin("%%EOF\n"), at: update.count - 6), kind)
            let at = try XCTUnwrap(update.lastIndexOf(TestPdf.latin("startxref\n")), kind)
            let digits = update[(at + 10)...].prefix { $0 >= 0x30 && $0 <= 0x39 }
            let start = try XCTUnwrap(Int(text(Array(digits))), kind)
            let section = Array(saved[start...])
            if stream {
                XCTAssertNotNil(text(section).range(of: "^\\d+ 0 obj\\n<</Type /XRef", options: .regularExpression), kind)
            } else {
                XCTAssertTrue(section.hasPattern(TestPdf.latin("xref\n"), at: 0), kind)
            }
        }
    }

    func test_hybridFileKeepsItsObjectStreamObjectsReadable() throws {
        let document = try PdfDocument.open(SaveFixtures.make("hybrid"))
        XCTAssertEqual(document.entries[3]?.kind, .compressed)
        document.info?["Title"] = PdfString(bytes: Latin1.bytes("Hybrid"), isHex: false)
        let reopened = try PdfDocument.open(document.saveIncremental())
        XCTAssertEqual(reopened.pages.count, 2)
        XCTAssertEqual(text(reopened.pages[0].contents()), SaveFixtures.pageOne)
        XCTAssertEqual(SaveFixtures.title(reopened), "Hybrid")
    }

    func test_objectFromAnObjectStreamIsWrittenAsAPlainObject() throws {
        let original = try SaveFixtures.make("objects")
        let document = try PdfDocument.open(original)
        let number = document.pages[0].reference.number
        XCTAssertEqual(document.entries[number]?.kind, .compressed)
        document.pages[0].dictionary["Rotate"] = PdfNumber(90)
        let saved = try document.saveIncremental()

        let update = text(Array(saved[original.count...]))
        XCTAssertTrue(update.contains("\(number) 0 obj\n<<"))
        XCTAssertFalse(update.contains("ObjStm"))
        let reopened = try PdfDocument.open(saved)
        XCTAssertEqual(reopened.entries[number]?.kind, .inUse)
        XCTAssertEqual(reopened.pages[0].rotate, 90)
        XCTAssertEqual(reopened.pages[1].rotate, 0)
    }

    func test_deletedObjectIsFreed() throws {
        for kind in ["table", "stream", "aes256"] {
            let document = try PdfDocument.open(SaveFixtures.make(kind))
            document.delete(6)
            document.pages[1].dictionary.remove("Contents")
            let reopened = try PdfDocument.open(document.saveIncremental())
            XCTAssertNil(reopened.get(6), kind)
            XCTAssertFalse(reopened.objectNumbers.contains(6), kind)
            XCTAssertEqual(reopened.generationOf(6), 1, kind)
            XCTAssertEqual(reopened.pages.count, 2, kind)
            XCTAssertTrue(reopened.pages[1].contents().isEmpty, kind)
        }
    }

    func test_firstIdIsKeptAndTheSecondIsNew() throws {
        let document = try PdfDocument.open(SaveFixtures.table())
        document.info?["Title"] = PdfString(bytes: [65], isHex: false)
        let reopened = try PdfDocument.open(document.saveIncremental())
        XCTAssertEqual(reopened.id.count, 2)
        XCTAssertEqual(reopened.id[0], SaveFixtures.fileId)
        XCTAssertNotEqual(reopened.id[1], SaveFixtures.fileId)
    }

    func test_fileWithoutIdGetsOne() throws {
        let document = try PdfDocument.open(TestPdf.simple())
        document.pages[0].dictionary["Rotate"] = PdfNumber(180)
        let reopened = try PdfDocument.open(document.saveIncremental())
        XCTAssertEqual(reopened.id.count, 2)
        XCTAssertEqual(reopened.id[0].count, 16)
    }

    func test_updatesCanFollowUpdates() throws {
        let first = SaveFixtures.table()
        var document = try PdfDocument.open(first)
        document.info?["Title"] = PdfString(bytes: [49], isHex: false)
        let second = try document.saveIncremental()
        document = try PdfDocument.open(second)
        document.info?["Title"] = PdfString(bytes: [50], isHex: false)
        document.pages[0].dictionary["Rotate"] = PdfNumber(270)
        let third = try document.saveIncremental()

        XCTAssertEqual(Array(third[0..<second.count]), second)
        let reopened = try PdfDocument.open(third)
        XCTAssertEqual(SaveFixtures.title(reopened), "2")
        XCTAssertEqual(reopened.pages[0].rotate, 270)
        XCTAssertEqual(PdfVersion.find(reopened).count, 3)
    }

    func test_encryptedUpdateIsEncryptedAgain() throws {
        for kind in ["aes128", "aes256", "aes256objects"] {
            let original = try SaveFixtures.make(kind)
            XCTAssertFalse(TestPdf.contains(original, "Original title"), kind)
            let document = try PdfDocument.open(original)
            try SaveFixtures.edit(document, "Plain text title")
            let saved = try document.saveIncremental()
            let update = Array(saved[original.count...])

            XCTAssertFalse(TestPdf.contains(update, "Plain text title"), kind)
            XCTAssertFalse(TestPdf.contains(update, "Added note"), kind)
            XCTAssertFalse(TestPdf.contains(update, "Changed"), kind)
            XCTAssertTrue(TestPdf.contains(update, "/Encrypt"), kind)
            let reopened = try PdfDocument.open(saved)
            XCTAssertEqual(SaveFixtures.title(reopened), "Plain text title", kind)
            XCTAssertTrue(text(reopened.pages[1].contents()).contains("Changed"), kind)
            // What was not touched still reads through the older section.
            XCTAssertEqual(text(reopened.pages[0].contents()), SaveFixtures.pageOne, kind)
        }
    }

    func test_signatureContentsAreNotEncrypted() throws {
        let document = try PdfDocument.open(SaveFixtures.make("aes128"))
        let signature = PdfDictionary()
        signature.add("Type", PdfName("Sig"))
        signature.add("ByteRange", PdfArray([PdfNumber(0), PdfNumber(1), PdfNumber(2), PdfNumber(3)]))
        signature.add("Contents", PdfString(bytes: [1, 2, 3, 4, 5], isHex: true))
        signature.add("Reason", PdfString(bytes: Latin1.bytes("Approved"), isHex: false))
        let reference = try document.add(signature)
        let reopened = try PdfDocument.open(document.saveIncremental())
        let read = try XCTUnwrap(reopened.get(reference.number) as? PdfDictionary)
        XCTAssertEqual(try XCTUnwrap(read["Contents"] as? PdfString).bytes, [1, 2, 3, 4, 5])
        XCTAssertEqual(try string(read["Reason"]), "Approved")
    }

    func test_encryptDictionaryInAnObjectIsNotEncrypted() throws {
        let document = try PdfDocument.open(SaveFixtures.make("aes256"))
        XCTAssertNotEqual(document.encryptNumber, 0)
        let encrypt = try XCTUnwrap(document.get(document.encryptNumber) as? PdfDictionary)
        encrypt["Extra"] = PdfName("Marker")
        let reopened = try PdfDocument.open(document.saveIncremental())
        XCTAssertEqual(reopened.name(try XCTUnwrap(reopened.get(reopened.encryptNumber) as? PdfDictionary), "Extra"), "Marker")
        XCTAssertEqual(SaveFixtures.title(reopened), "Original title")
    }

    func test_fileWithABrokenTableGetsAFullSection() throws {
        let broken = TestPdf.replace(SaveFixtures.table(), "startxref", "startxxxxx")
        let document = try PdfDocument.open(broken)
        XCTAssertTrue(document.xrefRebuilt)
        document.info?["Title"] = PdfString(bytes: [66], isHex: false)
        let saved = try document.saveIncremental()
        XCTAssertEqual(Array(saved[0..<broken.count]), broken)

        let reopened = try PdfDocument.open(saved)
        XCTAssertFalse(reopened.xrefRebuilt)
        XCTAssertTrue(reopened.repairs.isEmpty)
        XCTAssertEqual(SaveFixtures.title(reopened), "B")
        XCTAssertEqual(reopened.pages.count, 2)
        XCTAssertEqual(text(reopened.pages[1].contents()), SaveFixtures.pageTwo)
    }

    func test_rebuiltFileWithObjectStreamsGetsAStreamSection() throws {
        let broken = TestPdf.replace(try SaveFixtures.make("objects"), "startxref", "startxxxxx")
        let document = try PdfDocument.open(broken)
        XCTAssertTrue(document.xrefRebuilt)
        document.info?["Title"] = PdfString(bytes: [67], isHex: false)
        let reopened = try PdfDocument.open(document.saveIncremental())
        XCTAssertFalse(reopened.xrefRebuilt)
        XCTAssertEqual(SaveFixtures.title(reopened), "C")
        XCTAssertEqual(reopened.pages.count, 2)
        XCTAssertEqual(text(reopened.pages[0].contents()), SaveFixtures.pageOne)
    }

    func test_fileThatDoesNotEndInALineBreakStillGetsAnUpdateOnItsOwnLine() throws {
        let original = SaveFixtures.table()
        let trimmed = Array(original.dropLast())
        XCTAssertEqual(trimmed.last, UInt8(ascii: "F"))
        let document = try PdfDocument.open(trimmed)
        document.info?["Title"] = PdfString(bytes: [68], isHex: false)
        let saved = try document.saveIncremental()
        XCTAssertEqual(saved[trimmed.count], UInt8(ascii: "\n"))
        XCTAssertEqual(SaveFixtures.title(try PdfDocument.open(saved)), "D")
    }

    func test_changedStreamKeepsItsOtherDataAndGetsALength() throws {
        let document = try PdfDocument.open(SaveFixtures.table())
        let stream = try XCTUnwrap(document.resolve(document.pages[0].dictionary["Contents"], as: PdfStream.self))
        stream.dictionary["Subtype"] = PdfName("Custom")
        let reopened = try PdfDocument.open(document.saveIncremental())
        XCTAssertTrue(reopened.repairs.isEmpty)
        let read = try XCTUnwrap(reopened.resolve(reopened.pages[0].dictionary["Contents"], as: PdfStream.self))
        XCTAssertEqual(reopened.name(read.dictionary, "Subtype"), "Custom")
        XCTAssertEqual(text(try reopened.data(read)), SaveFixtures.pageOne)
    }

    func test_stringsWithAwkwardBytesSurvive() throws {
        let document = try PdfDocument.open(SaveFixtures.table())
        let awkward: [UInt8] = [0, 13, 10, UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"), 200, 255, UInt8(ascii: "a")]
        let source = try XCTUnwrap(document.info)
        source["Author"] = PdfString(bytes: awkward, isHex: false)
        source["Keywords"] = PdfString(bytes: awkward, isHex: true)
        source["Odd#Name"] = PdfName("a b/c#d\u{E9}")
        let info = try XCTUnwrap(try PdfDocument.open(document.saveIncremental()).info)
        XCTAssertEqual(try XCTUnwrap(info["Author"] as? PdfString).bytes, awkward)
        XCTAssertEqual(try XCTUnwrap(info["Keywords"] as? PdfString).bytes, awkward)
        XCTAssertEqual((info["Odd#Name"] as? PdfName)?.value, "a b/c#d\u{E9}")
    }

    func test_bytesBeforeTheHeaderAreDroppedAndOffsetsCountFromTheHeader() throws {
        let original = Array("junk\n".utf8) + SaveFixtures.table()
        let document = try PdfDocument.open(original)
        document.info?["Title"] = PdfString(bytes: [69], isHex: false)
        let saved = try document.saveIncremental()
        XCTAssertTrue(saved.hasPattern(TestPdf.latin("%PDF-"), at: 0))
        XCTAssertEqual(SaveFixtures.title(try PdfDocument.open(saved)), "E")
    }
}
