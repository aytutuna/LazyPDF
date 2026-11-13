import XCTest
@testable import LazyPDFIOS

@MainActor
final class IOSShellTests: XCTestCase {
    private var inbox: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Inbox")
    }

    func test_anInboxCopyIsTemporary() {
        XCTAssertTrue(IOSShell.isTemporary(inbox.appendingPathComponent("a.pdf")))
    }

    func test_anInboxCopyNamedThroughThePrivateFolderIsTemporary() throws {
        let path = inbox.resolvingSymlinksInPath().path
        // On a device the app's folders sit under /var, a link to /private/var; the simulator keeps them under /Users.
        try XCTSkipUnless(path.hasPrefix("/private/var/") || path.hasPrefix("/var/"), "no /private alias for \(path)")
        let alias = path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : "/private" + path
        XCTAssertTrue(IOSShell.isTemporary(URL(fileURLWithPath: alias + "/a.pdf")))
    }

    func test_aFileInDocumentsOutsideInboxIsNotTemporary() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        XCTAssertFalse(IOSShell.isTemporary(documents.appendingPathComponent("a.pdf")))
    }
}
