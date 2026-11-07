import XCTest
@testable import LazyPDFApp

final class AppFoldersTests: XCTestCase {
    private let folders = DefaultAppFolders(support: URL(fileURLWithPath: "/s"), caches: URL(fileURLWithPath: "/c"), temporary: URL(fileURLWithPath: "/t"))

    func test_settingsAndRecoverySitInApplicationSupport() {
        XCTAssertEqual(folders.settings.path, "/s/Lazy PDF")
        XCTAssertEqual(folders.recovery.path, "/s/Lazy PDF/Recovery")
    }

    func test_thumbnailsAndPrintCopiesSitInTheCaches() {
        XCTAssertEqual(folders.thumbnails.path, "/c/Lazy PDF/Thumbnails")
        XCTAssertEqual(folders.printCopies.path, "/c/Lazy PDF/Print")
    }

    func test_openedAttachmentsSitInTheTemporaryFolder() {
        XCTAssertEqual(folders.openedAttachments.path, "/t/Lazy PDF/Attachments")
    }
}
