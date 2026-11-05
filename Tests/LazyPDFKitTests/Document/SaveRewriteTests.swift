import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/SaveRewriteTests.cs: the same cases, except PdfPigReadsTheRewrite,
// whose only assertions are PdfPig's (there is no Swift PdfPig).

final class SaveRewriteTests: XCTestCase {
    private func text(_ bytes: [UInt8]) -> String { Latin1.string(bytes) }

    private func assertSameContent(_ expected: PdfDocument, _ actual: PdfDocument, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(expected.pages.count, actual.pages.count, file: file, line: line)
        for i in 0..<min(expected.pages.count, actual.pages.count) {
            XCTAssertEqual(expected.pages[i].contents(), actual.pages[i].contents(), file: file, line: line)
        }
        XCTAssertEqual(SaveFixtures.title(expected), SaveFixtures.title(actual), file: file, line: line)
    }

    func test_rewriteOfEveryLayoutReadsTheSame() throws {
        for kind in SaveFixtures.kinds {
            let original = try PdfDocument.open(SaveFixtures.make(kind))
            for packed in [false, true] {
                let rewritten = try original.saveRewrite(PdfSaveOptions(useObjectStreams: packed, security: original.security))
                let reopened = try PdfDocument.open(rewritten)
                XCTAssertTrue(reopened.repairs.isEmpty, "\(kind) \(packed)")
                assertSameContent(original, reopened)
                XCTAssertEqual(original.isEncrypted, reopened.isEncrypted, "\(kind) \(packed)")
                XCTAssertEqual(TestPdf.contains(rewritten, "/Type /XRef"), packed, "\(kind) \(packed)")
            }
        }
    }

    func test_onlyReachableObjectsAreKeptAndTheyAreNumberedFromOne() throws {
        let pdf = TestPdf()
        pdf.obj(10, "<</Type /Catalog /Pages 20 0 R>>")
        pdf.obj(20, "<</Type /Pages /Kids [30 0 R] /Count 1 /MediaBox [0 0 100 100]>>")
        pdf.obj(30, "<</Type /Page /Parent 20 0 R /Contents 40 0 R>>")
        pdf.stream(40, "", "q Q")
        pdf.obj(50, "<</Orphan (never reached)>>")
        pdf.obj(60, "<</Gone 99 0 R /Cycle 60 0 R>>")
        let original = try PdfDocument.open(pdf.finish("/Root 10 0 R"))
        let rewritten = try original.saveRewrite()

        XCTAssertFalse(TestPdf.contains(rewritten, "never reached"))
        let reopened = try PdfDocument.open(rewritten)
        XCTAssertEqual(reopened.objectNumbers, [1, 2, 3, 4])
        XCTAssertEqual(reopened.pages.count, 1)
        XCTAssertEqual(text(reopened.pages[0].contents()), "q Q")
        XCTAssertEqual((reopened.trailer["Root"] as? PdfReference)?.number, 1)
    }

    func test_generationsGoBackToZeroAndReferencesToNothingAreDropped() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Dangling 77 0 R /List [78 0 R 1]>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 100 100]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        let reopened = try PdfDocument.open(try PdfDocument.open(pdf.finish()).saveRewrite())
        XCTAssertFalse(reopened.catalog.containsKey("Dangling"))
        let list = try XCTUnwrap(reopened.array(reopened.catalog, "List"))
        XCTAssertTrue(list.items[0] is PdfNull)
        for n in reopened.objectNumbers { XCTAssertEqual(reopened.generationOf(n), 0) }
    }

    func test_rewriteKeepsTheFirstIdAndMakesASecond() throws {
        let original = try PdfDocument.open(SaveFixtures.table())
        let reopened = try PdfDocument.open(try original.saveRewrite())
        XCTAssertEqual(reopened.id.count, 2)
        XCTAssertEqual(original.id[0], reopened.id[0])
        XCTAssertNotEqual(original.id[0], reopened.id[1])

        let given = try PdfDocument.open(try original.saveRewrite(PdfSaveOptions(documentId: Array(SaveFixtures.fileId.prefix(8)))))
        XCTAssertEqual(given.id[0], Array(SaveFixtures.fileId.prefix(8)))
    }

    func test_objectStreamsPackThePlainObjectsOnly() throws {
        let original = try PdfDocument.open(SaveFixtures.table())
        let rewritten = try original.saveRewrite(PdfSaveOptions(useObjectStreams: true))
        let reopened = try PdfDocument.open(rewritten)

        XCTAssertTrue(rewritten.hasPattern(TestPdf.latin("%PDF-1.5"), at: 0))
        let catalog = try XCTUnwrap((reopened.trailer["Root"] as? PdfReference)?.number)
        let info = try XCTUnwrap((reopened.trailer["Info"] as? PdfReference)?.number)
        XCTAssertEqual(reopened.entries[catalog]?.kind, .inUse)
        XCTAssertEqual(reopened.entries[info]?.kind, .compressed)
        XCTAssertEqual(reopened.entries[reopened.pages[0].reference.number]?.kind, .compressed)
        let contents = try XCTUnwrap((reopened.pages[0].dictionary["Contents"] as? PdfReference)?.number)
        XCTAssertEqual(reopened.entries[contents]?.kind, .inUse)
        XCTAssertTrue(reopened.xrefIsStream)
        XCTAssertLessThan(rewritten.count, SaveFixtures.table().count * 2)
        assertSameContent(original, reopened)
    }

    func test_manyObjectsGoIntoSeveralObjectStreams() throws {
        let pdf = TestPdf("%PDF-1.4\n")
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 100 100]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        for i in 0..<250 { pdf.obj(10 + i, "<</N \(i)>>") }
        let refs = (0..<250).map { "\(10 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(300, "<</Type /Info /Refs [\(refs)]>>")
        let original = try PdfDocument.open(pdf.finish("/Root 1 0 R /Info 300 0 R"))
        let reopened = try PdfDocument.open(try original.saveRewrite(PdfSaveOptions(useObjectStreams: true)))

        XCTAssertTrue(reopened.repairs.isEmpty)
        let list = try XCTUnwrap(reopened.array(reopened.info, "Refs"))
        XCTAssertEqual(list.items.count, 250)
        for i in 0..<250 {
            XCTAssertEqual(reopened.integer(reopened.resolve(list.items[i]) as? PdfDictionary, "N"), i)
        }
        let streams = reopened.objectNumbers.filter {
            (reopened.get($0) as? PdfStream).map { reopened.name($0.dictionary, "Type") == "ObjStm" } ?? false
        }
        XCTAssertEqual(streams.count, 3)
    }

    func test_signatureDictionaryStaysOutOfObjectStreams() throws {
        let original = try PdfDocument.open(SaveFixtures.table())
        let signature = PdfDictionary()
        signature.add("Type", PdfName("Sig"))
        signature.add("ByteRange", PdfArray([PdfNumber(0), PdfNumber(9)]))
        signature.add("Contents", PdfString(bytes: [1, 2, 3], isHex: true))
        let reference = try original.add(signature)
        original.catalog["Sig"] = reference
        let reopened = try PdfDocument.open(try original.saveRewrite(PdfSaveOptions(useObjectStreams: true)))
        let number = try XCTUnwrap((reopened.catalog["Sig"] as? PdfReference)?.number)
        XCTAssertEqual(reopened.entries[number]?.kind, .inUse)
    }

    func test_streamsAreRecompressedOnlyWhereItPaysAndNeverCodecData() throws {
        let flat = Latin1.bytes(String(repeating: "0 0 m 10 10 l S\n", count: 200))
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 0xFF, 0xD9]
        let lzw = PdfFilterEncoders.lzw(flat)
        let hex = PdfFilterEncoders.asciiHex(flat)
        let flate = TestPdf.deflate(flat)
        let predicted = TestPdf.deflate(flat)
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /A 4 0 R /B 5 0 R /C 6 0 R /D 7 0 R /E 8 0 R /F 9 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 10 10]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.stream(4, "", flat)
        pdf.stream(5, "/Filter /DCTDecode /Subtype /Image", jpeg)
        pdf.stream(6, "/Filter /LZWDecode", lzw)
        pdf.stream(7, "/Filter /ASCIIHexDecode", hex)
        pdf.stream(8, "/Filter /FlateDecode", flate)
        pdf.stream(9, "/Filter /FlateDecode /DecodeParms <</Predictor 12 /Columns 4>>", predicted)
        let original = try PdfDocument.open(pdf.finish())
        let reopened = try PdfDocument.open(try original.saveRewrite())

        func stream(_ key: String) throws -> PdfStream {
            try XCTUnwrap(reopened.resolve(reopened.catalog[key]) as? PdfStream)
        }
        func filter(_ key: String) throws -> String {
            try stream(key).dictionary["Filter"]?.description ?? ""
        }

        XCTAssertEqual(try filter("A"), "/FlateDecode")
        XCTAssertLessThan(reopened.rawData(try stream("A")).count, flat.count / 4)
        XCTAssertEqual(try filter("B"), "/DCTDecode")
        XCTAssertEqual(reopened.rawData(try stream("B")), jpeg)
        XCTAssertEqual(try filter("C"), "/FlateDecode")
        XCTAssertEqual(try filter("D"), "/FlateDecode")
        XCTAssertEqual(try reopened.data(try stream("A")), flat)
        XCTAssertEqual(try reopened.data(try stream("C")), flat)
        XCTAssertEqual(try reopened.data(try stream("D")), flat)
        XCTAssertEqual(reopened.rawData(try stream("E")), flate)
        XCTAssertEqual(reopened.rawData(try stream("F")), predicted)
        XCTAssertNotNil(reopened.dict(try stream("F").dictionary, "DecodeParms"))
    }

    func test_streamThatDoesNotDecodeIsCopiedAsItIs() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Bad 4 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 10 10]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.stream(4, "/Filter /ASCIIHexDecode", "zz not hex at all, not even close", length: 1000)
        let original = try PdfDocument.open(pdf.finish())
        let reopened = try PdfDocument.open(try original.saveRewrite())
        let number = try XCTUnwrap((reopened.catalog["Bad"] as? PdfReference)?.number)
        let stream = try XCTUnwrap(reopened.get(number) as? PdfStream)
        XCTAssertEqual(text(reopened.rawData(stream)), "zz not hex at all, not even close")
    }

    func test_encryptionCanBeAddedRemovedAndKept() throws {
        let plain = try PdfDocument.open(SaveFixtures.table())
        for strength in [PdfCryptStrength.aes128, .aes256] {
            let security = PdfSecurity.create(userPassword: "open", ownerPassword: "owner", permissions: .all, strength: strength,
                                              firstId: SaveFixtures.fileId, random: SeededRandom(3))
            let encrypted = try plain.saveRewrite(PdfSaveOptions(security: security, documentId: SaveFixtures.fileId))
            XCTAssertFalse(TestPdf.contains(encrypted, "Original title"))
            assertReadFails(try PdfDocument.open(encrypted))
            let opened = try PdfDocument.open(encrypted, password: "open")
            assertSameContent(plain, opened)
            XCTAssertTrue(encrypted.hasPattern(TestPdf.latin(strength == .aes128 ? "%PDF-1.6" : "%PDF-1.7"), at: 0))

            let kept = try opened.saveRewrite(PdfSaveOptions(useObjectStreams: true, security: opened.security))
            assertSameContent(plain, try PdfDocument.open(kept, password: "open"))
            XCTAssertFalse(TestPdf.contains(kept, "Original title"))

            let removed = try opened.saveRewrite()
            let open = try PdfDocument.open(removed)
            XCTAssertFalse(open.isEncrypted)
            assertSameContent(plain, open)
        }
    }

    func test_keptOlderHandlerKeepsTheFirstId() throws {
        let original = try PdfDocument.open(SaveFixtures.make("aes128"))
        let reopened = try PdfDocument.open(try original.saveRewrite(PdfSaveOptions(security: original.security)))
        XCTAssertEqual(reopened.id[0], SaveFixtures.fileId)
        XCTAssertEqual(SaveFixtures.title(reopened), "Original title")
    }

    func test_pageEditsAreInTheRewrite() throws {
        let document = try PdfDocument.open(SaveFixtures.make("objects"))
        try SaveFixtures.edit(document)
        let reopened = try PdfDocument.open(try document.saveRewrite())
        XCTAssertEqual(SaveFixtures.title(reopened), "New title")
        XCTAssertTrue(text(reopened.pages[1].contents()).contains("Changed"))
        XCTAssertEqual(text(try XCTUnwrap(reopened.dict(reopened.catalog, "Extra")?["Note"] as? PdfString).bytes), "Added note")
    }

    func test_damagedFileIsRewrittenFromWhatWasRepaired() throws {
        let broken = TestPdf.replace(SaveFixtures.table(), "startxref", "startxxxxx")
        let document = try PdfDocument.open(broken)
        XCTAssertFalse(document.repairs.isEmpty)
        let reopened = try PdfDocument.open(try document.saveRewrite())
        XCTAssertTrue(reopened.repairs.isEmpty)
        assertSameContent(document, reopened)
    }

    func test_directInfoAndCatalogAreWrittenAsObjects() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 10 10]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        let original = try PdfDocument.open(pdf.finish("/Root 1 0 R /Info <</Title (Direct)>>"))
        let reopened = try PdfDocument.open(try original.saveRewrite())
        XCTAssertEqual(SaveFixtures.title(reopened), "Direct")
        XCTAssertTrue(reopened.trailer["Info"] is PdfReference)
    }
}
