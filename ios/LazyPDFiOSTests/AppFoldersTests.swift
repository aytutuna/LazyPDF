import XCTest
import LazyPDFIOS

// Follows windows/LazyPDF.App.Tests/AppFoldersTests.cs.

final class AppFoldersTests: XCTestCase {
    private let folders = IOSAppFolders()
    private let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path

    private func inContainer(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(home + "/")
    }

    func test_everyFolderIsInTheAppsContainer() {
        for url in [folders.settings, folders.recovery, folders.thumbnails, folders.printCopies, folders.openedAttachments] {
            XCTAssertTrue(inContainer(url), url.path)
        }
    }

    func test_settingsAndRecoveryAreInApplicationSupport() {
        XCTAssertTrue(folders.settings.path.contains("Library/Application Support"))
        XCTAssertEqual(folders.recovery.deletingLastPathComponent().path, folders.settings.path)
    }

    func test_thumbnailsAreInCachesWhereTheSystemMayClearThem() {
        XCTAssertTrue(folders.thumbnails.path.contains("Library/Caches"))
    }

    func test_filesAnotherProgramReadsAreInTheTemporaryFolder() {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        XCTAssertTrue(folders.printCopies.resolvingSymlinksInPath().path.hasPrefix(temporary))
        XCTAssertTrue(folders.openedAttachments.resolvingSymlinksInPath().path.hasPrefix(temporary))
    }

    func test_theFoldersAreDistinct() {
        let paths = [folders.settings, folders.recovery, folders.thumbnails, folders.printCopies, folders.openedAttachments].map(\.path)
        XCTAssertEqual(Set(paths).count, paths.count)
    }
}
