import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/DocumentOpenerTests.cs: what the open panel and the drop target hand over, a PDF as
// it is, a picture or a text file made into a PDF. Not ported: TurkishTextNeedsAFontFromTheSource asks Windows' system
// fonts; its first half, that no font source means no text, is kept.

final class DocumentOpenerTests: XCTestCase {
    private let opener = DocumentOpener(FakeCodec(), FakeFonts())

    func test_aPdfIsReadAsItIsAndKeepsItsPath() throws {
        let dir = TempDir(self)
        let bytes = Pdfs.text()
        let url = dir.file("a.pdf", bytes)

        let source = try opener.read(url)

        XCTAssertEqual(source.bytes, bytes)
        XCTAssertEqual(source.url, url)
        XCTAssertEqual(source.title, "a.pdf")
        XCTAssertFalse(source.made)
    }

    func test_theBytesComeFromTheReader() throws {
        let dir = TempDir(self)
        let bytes = Pdfs.text()
        let url = dir.file("a.pdf", bytes)
        var calls = 0
        let counting = DocumentOpener(FakeCodec(), FakeFonts())
        counting.reader = { calls += 1; return try Data(contentsOf: $0) }

        let source = try counting.read(url)

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(source.bytes, bytes)
    }

    func test_theStampIsTakenAgainWhenTheReaderDownloadedTheFile() throws {
        let dir = TempDir(self)
        let bytes = Pdfs.text()
        let url = dir.file("a.pdf", [])
        let downloading = DocumentOpener(FakeCodec(), FakeFonts())
        downloading.reader = { try Data(bytes).write(to: $0); return Data(bytes) }

        let source = try downloading.read(url)

        XCTAssertEqual(source.stamp?.length, Int64(bytes.count))
    }

    func test_aFolderIsRefusedInWords() throws {
        let dir = TempDir(self)
        let folder = dir.sub("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertThrowsError(try opener.read(folder)) {
            XCTAssertEqual(($0 as? InvalidDataException)?.message, DocumentOpener.isFolder)
        }
    }

    func test_aPictureBecomesAPdfWithNoFileOfItsOwn() throws {
        for name in ["scan.jpg", "scan.PNG", "scan.tif", "scan.heic"] {
            let dir = TempDir(self)
            let url = dir.file(name, [1, 2, 3, 4])

            let source = try opener.read(url)

            XCTAssertTrue(source.made, name)
            XCTAssertNil(source.url, name)
            XCTAssertEqual(source.title, url.deletingPathExtension().lastPathComponent + ".pdf", name)
            XCTAssertEqual(try PdfDocument.open(source.bytes).pages.count, 1, name)
        }
    }

    func test_aPictureNoCodecCanReadIsSaidInWords() {
        let dir = TempDir(self)
        let url = dir.file("empty.png", [])

        XCTAssertThrowsError(try opener.read(url)) { error in
            XCTAssertEqual((error as? InvalidDataException)?.message, ExportText.noUsablePicture)
        }
    }

    func test_aTextFileBecomesPagesOfText() throws {
        let dir = TempDir(self)
        let url = dir.file("notes.txt", Array("first page\u{0C}second page".utf8))

        let source = try opener.read(url)

        XCTAssertTrue(source.made)
        XCTAssertEqual(source.title, "notes.pdf")
        XCTAssertEqual(try PdfDocument.open(source.bytes).pages.count, 2)
    }

    func test_textInAnOldCodePageIsStillRead() throws {
        let dir = TempDir(self)
        let url = dir.file("old.txt", [0x63, 0x61, 0x66, 0xE9])

        let source = try opener.read(url)

        XCTAssertEqual(try PdfDocument.open(source.bytes).pages.count, 1)
        XCTAssertEqual(DocumentOpener.decode([0x63, 0x61, 0x66, 0xE9]), "caf\u{E9}")
    }

    func test_aByteOrderMarkIsNotPartOfTheText() {
        XCTAssertEqual(DocumentOpener.decode([0xEF, 0xBB, 0xBF, 0x61]), "a")
    }

    func test_utf16TextWithAByteOrderMarkIsRead() {
        let little: [UInt8] = [0xFF, 0xFE] + "Şeker".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let big: [UInt8] = [0xFE, 0xFF] + "Şeker".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }

        XCTAssertEqual(DocumentOpener.decode(little), "Şeker")
        XCTAssertEqual(DocumentOpener.decode(big), "Şeker")
    }

    func test_otherBytesAreReadAsAWindowsCodePage() {
        let en = Locale(identifier: "en_US")
        let tr = Locale(identifier: "tr_TR")

        XCTAssertEqual(DocumentOpener.decode([0x93, 0x68, 0x69, 0x94], locale: en), "\u{201C}hi\u{201D}")
        XCTAssertEqual(DocumentOpener.decode([0xFD], locale: tr), "\u{131}")
        XCTAssertEqual(DocumentOpener.decode([0xFD], locale: en), "\u{FD}")
    }

    func test_utf8WithoutAByteOrderMarkIsRead() {
        XCTAssertEqual(DocumentOpener.decode([0xC5, 0x9E, 0x61]), "\u{15E}a")
    }

    func test_turkishTextNeedsAFontFromTheSource() {
        let dir = TempDir(self)
        let url = dir.file("tr.txt", Array("\u{C7}al\u{131}\u{15F}ma \u{11F} \u{15F} \u{131} \u{130}".utf8))

        XCTAssertThrowsError(try opener.read(url)) { error in
            XCTAssertTrue(error is InvalidOperationException)
        }
    }

    func test_aStampHasTheLengthAndTimeOfTheFile() throws {
        let dir = TempDir(self)
        let url = dir.file("a.pdf", [1, 2, 3])

        let stamp = DiskStamp.of(url)

        XCTAssertEqual(stamp?.length, 3)
        XCTAssertEqual(stamp?.write.timeIntervalSinceNow ?? -1000, 0, accuracy: 120)
        XCTAssertNil(DiskStamp.of(dir.sub("none.pdf")))
        XCTAssertNil(DiskStamp.of(nil))
    }

    func test_aMissingFileIsNotFound() {
        let dir = TempDir(self)
        try? FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)

        XCTAssertThrowsError(try opener.read(dir.sub("none.pdf"))) { error in
            XCTAssertTrue(StoreFiles.isNoSuchFile(error))
        }
    }
}
