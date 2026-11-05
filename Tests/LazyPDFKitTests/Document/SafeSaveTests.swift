import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/SafeSaveTests.cs. Windows file attributes have no twin, so three cases
// change: ExistingFileIsReplacedAndKeepsItsAttributes keeps the POSIX permissions instead of Hidden and the creation
// time, and ReadOnlyFileIsNotReplaced makes the file mode 0444 instead of setting the ReadOnly attribute;
// test_readOnlyFolderIsNotWrittenTo is added for the other way a write is refused on POSIX.
// FileOpenForReadingElsewhereIsNotReplacedAndNothingIsLost is not ported: it rests on Windows' exclusive file
// sharing, which POSIX does not have.

final class SafeSaveTests: XCTestCase {
    private var folder = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        folder = try temporaryFolder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }

    private func entries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func test_newFileIsWrittenWithoutLeavingATemporaryOne() throws {
        let path = folder.appendingPathComponent("new.pdf").path
        let bytes = SaveFixtures.table()
        try PdfFileSaver.save(path, bytes)
        XCTAssertEqual([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))), bytes)
        XCTAssertEqual(try entries(), ["new.pdf"])
    }

    func test_existingFileIsReplacedAndKeepsItsAttributes() throws {
        let path = folder.appendingPathComponent("old.pdf").path
        try Data(TestPdf.simple()).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)

        let bytes = SaveFixtures.table()
        try PdfFileSaver.save(path, bytes)
        XCTAssertEqual([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))), bytes)
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o640)
        XCTAssertEqual(try entries(), ["old.pdf"])
    }

    func test_bytesThatAreNotAPdfLeaveTheOriginalAndNoTemporaryFile() throws {
        let path = folder.appendingPathComponent("keep.pdf").path
        let original = SaveFixtures.table()
        try Data(original).write(to: URL(fileURLWithPath: path))
        assertReadFails(try PdfFileSaver.save(path, Array("not a pdf at all".utf8)))
        XCTAssertEqual([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))), original)
        XCTAssertEqual(try entries(), ["keep.pdf"])
    }

    func test_readOnlyFileIsNotReplaced() throws {
        let path = folder.appendingPathComponent("locked.pdf").path
        let original = TestPdf.simple()
        try Data(original).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        XCTAssertThrowsError(try PdfFileSaver.save(path, SaveFixtures.table()))
        XCTAssertEqual([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))), original)
        XCTAssertEqual(try entries(), ["locked.pdf"])
    }

    func test_readOnlyFolderIsNotWrittenTo() throws {
        let path = folder.appendingPathComponent("locked.pdf").path
        let original = TestPdf.simple()
        try Data(original).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertThrowsError(try PdfFileSaver.save(path, SaveFixtures.table()))
        XCTAssertEqual([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))), original)
        XCTAssertEqual(try entries(), ["locked.pdf"])
    }

    func test_encryptedBytesNeedThePasswordToBeChecked() throws {
        let security = PdfSecurity.create(userPassword: "pw", ownerPassword: "owner", permissions: .all, strength: .aes256,
                                          firstId: SaveFixtures.fileId)
        let bytes = try PdfDocument.open(SaveFixtures.table()).saveRewrite(PdfSaveOptions(security: security))
        let path = folder.appendingPathComponent("enc.pdf").path
        assertReadFails(try PdfFileSaver.save(path, bytes))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        try PdfFileSaver.save(path, bytes, password: "pw")
        XCTAssertEqual([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))), bytes)
    }

    func test_aFileThatOnlyOpensByRebuildingIsNotWrittenOverTheOriginal() throws {
        let path = folder.appendingPathComponent("keep.pdf").path
        let original = SaveFixtures.table()
        try Data(original).write(to: URL(fileURLWithPath: path))
        let cut = Array(original[0..<(try XCTUnwrap(original.indexOf(TestPdf.latin("4 0 obj"))) + 10)])
        XCTAssertTrue(try PdfDocument.open(cut).xrefRebuilt)

        assertReadFails(try PdfFileSaver.save(path, cut, source: PdfDocument.open(original), samePages: false) { try PdfDocument.open($0) })
        XCTAssertEqual([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))), original)
        XCTAssertEqual(try entries(), ["keep.pdf"])
    }

    func test_aLosingOfPagesIsCaughtWhenThePageCountMustHold() throws {
        let path = folder.appendingPathComponent("pages.pdf").path
        let two = TestPdf.simple(2)
        try Data(two).write(to: URL(fileURLWithPath: path))
        let source = try PdfDocument.open(two)

        assertReadFails(try PdfFileSaver.save(path, TestPdf.simple(1), source: source, samePages: true) { try PdfDocument.open($0) })
        XCTAssertEqual([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))), two)
        try PdfFileSaver.save(path, TestPdf.simple(1), source: source, samePages: false) { try PdfDocument.open($0) }
        XCTAssertEqual(try PdfDocument.open(path: path).pages.count, 1)
    }
}
