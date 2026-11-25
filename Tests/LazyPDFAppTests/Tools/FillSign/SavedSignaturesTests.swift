import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/sign/SavedSignaturesTests.cs: signatures kept for reuse, one PNG each, newest first,
// signatures apart from initials. Reading a picture back needs the system's codec, so that test is wrapped.

final class SavedSignaturesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("signatures-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func image(_ shade: UInt8) -> PdfRgbaImage {
        PdfRgbaImage(2, 1, [shade, 0, 0, 255, 0, shade, 0, 128])
    }

    private func saved(_ codec: ImageCodec = SignaturePictureCodec(nil)) -> SavedSignatures {
        SavedSignatures(directory: folder.appendingPathComponent("sigs", isDirectory: true), codec: codec)
    }

    func test_nothingIsSavedBeforeTheFirstOne() {
        XCTAssertTrue(saved().list(.signature).isEmpty)
    }

    func test_signaturesAndInitialsAreKeptApartNewestFirst() throws {
        let store = saved()
        let first = try store.add(.signature, image(1))
        Thread.sleep(forTimeInterval: 0.005)
        let second = try store.add(.signature, image(2))
        let initials = try store.add(.initials, image(3))

        XCTAssertEqual(store.list(.signature), [second, first])
        XCTAssertEqual(store.list(.initials), [initials])
    }

    func test_aSavedFileIsAPngInTheFolderOfItsOwn() throws {
        let store = saved()

        let item = try store.add(.initials, image(9))

        XCTAssertTrue(item.url.lastPathComponent.hasPrefix("initials-"))
        XCTAssertEqual(item.url.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: item.url).prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(item.url.deletingLastPathComponent().lastPathComponent, "sigs")
    }

    func test_aRemovedSignatureIsGone() throws {
        let store = saved(SignaturePictureCodec(image(9)))
        let item = try store.add(.initials, image(9))
        XCTAssertNotNil(store.load(item))

        store.remove(item)

        XCTAssertTrue(store.list(.initials).isEmpty)
        XCTAssertNil(store.load(item))
    }

    func test_removingAFileThatIsNotThereChangesNothing() throws {
        let store = saved()
        let item = try store.add(.signature, image(1))
        store.remove(item)

        store.remove(item)

        XCTAssertTrue(store.list(.signature).isEmpty)
    }

    func test_theFolderIsBesideTheSettingsOfTheApp() {
        let folders = DefaultAppFolders(support: URL(fileURLWithPath: "/s"), caches: URL(fileURLWithPath: "/c"), temporary: URL(fileURLWithPath: "/t"))

        XCTAssertEqual(SavedSignatures.defaultDirectory(folders).path, "/s/Lazy PDF/Signatures")
    }

    #if canImport(ImageIO)
    func test_aSavedSignatureComesBackWithItsPixels() throws {
        let store = saved(ImageIOCodec())

        let item = try store.add(.signature, image(200))
        let back = try XCTUnwrap(store.load(item))

        XCTAssertEqual(back.width, 2)
        XCTAssertEqual(back.rgba[0], 200)
        XCTAssertEqual(back.rgba[7], 128)
    }
    #endif
}
