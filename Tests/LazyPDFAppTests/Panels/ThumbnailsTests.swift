import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/ThumbnailsTests.cs: the pictures on the Home tab, made from the first page and kept under
// a name that changes with the file.

final class ThumbnailsTests: XCTestCase {
    private func make(_ dir: TempDir) -> Thumbnails {
        Thumbnails({ DpiRenderer() }, directory: dir.sub("thumbs"))
    }

    private func cached(_ dir: TempDir) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir.sub("thumbs"), includingPropertiesForKeys: nil)) ?? []
    }

    func test_aFileGivesAPngOfItsFirstPage() async throws {
        let dir = TempDir(self)
        let url = dir.file("a.pdf", Pdfs.text(2))

        let made = await make(dir).get(url, width: 200)
        let png = try XCTUnwrap(made)

        XCTAssertEqual(Array(png[0..<4]), [0x89, 0x50, 0x4E, 0x47])
        let wide = png[16..<20].reduce(0) { $0 << 8 | Int($1) }
        XCTAssertTrue((198...202).contains(wide))
    }

    func test_thePictureIsKeptAndUsedTheSecondTime() async throws {
        let dir = TempDir(self)
        let url = dir.file("a.pdf", Pdfs.text())
        let thumbnails = make(dir)

        let first = await thumbnails.get(url)
        let keptAfterFirst = cached(dir)
        let second = await thumbnails.get(url)

        XCTAssertEqual(keptAfterFirst.count, 1)
        XCTAssertEqual(first, second)
        XCTAssertEqual(cached(dir).count, 1)
    }

    func test_aChangedFileGetsANewPicture() async throws {
        let dir = TempDir(self)
        let url = dir.file("a.pdf", Pdfs.text())
        let thumbnails = make(dir)
        _ = await thumbnails.get(url)

        try touch(url, Pdfs.text(2, "Another text"))
        _ = await thumbnails.get(url)

        XCTAssertEqual(cached(dir).count, 2)
    }

    func test_aFileThatNeedsAPasswordHasNoPicture() async {
        let dir = TempDir(self)
        let url = dir.file("locked.pdf", Pdfs.fixture("locked.pdf"))

        let picture = await make(dir).get(url)

        XCTAssertNil(picture)
    }

    func test_aFileThatIsNotThereOrNotAPdfHasNoPicture() async {
        let dir = TempDir(self)
        let junk = dir.file("junk.pdf", Array("not a pdf".utf8))
        let thumbnails = make(dir)

        let missing = await thumbnails.get(dir.sub("none.pdf"))
        let notPdf = await thumbnails.get(junk)

        XCTAssertNil(missing)
        XCTAssertNil(notPdf)
    }

    func test_aPictureOldEnoughIsPrunedAtTheNextStart() async throws {
        let dir = TempDir(self)
        let url = dir.file("a.pdf", Pdfs.text())
        _ = await make(dir).get(url)
        let file = try XCTUnwrap(cached(dir).first)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 86400)], ofItemAtPath: file.path)

        _ = make(dir)

        XCTAssertTrue(cached(dir).isEmpty)
    }
}
