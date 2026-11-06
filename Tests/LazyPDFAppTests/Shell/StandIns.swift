import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Follows windows/LazyPDF.App.Tests/StandIns.cs.

/// A folder of its own for one test, removed with it.
final class TempDir {
    let url: URL

    init(_ test: XCTestCase) {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("lazypdf-tests-" + UUID().uuidString, isDirectory: true)
        let folder = url
        test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    }

    func sub(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    @discardableResult
    func file(_ name: String, _ bytes: [UInt8]) -> URL {
        let file = sub(name)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(bytes).write(to: file)
        return file
    }
}

/// A count that an observation callback may bump.
final class Counter: @unchecked Sendable {
    var count = 0
}

func samePath(_ a: URL?, _ b: URL?) -> Bool {
    a?.standardizedFileURL.path == b?.standardizedFileURL.path
}

/// Sets the time a file was last written, as another program writing it would.
func touch(_ url: URL, _ bytes: [UInt8], minutes: Double = 10) throws {
    try Data(bytes).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(minutes * 60)], ofItemAtPath: url.path)
}

/// Draws nothing: blank pages of a fixed size, and a count of how often the file was read.
final class FakeRenderer: DocumentRenderer {
    var loads = 0
    var draws = true
    var disposed = false

    func load(_ session: PdfEditSession, _ password: String?) -> Bool {
        loads += 1
        return draws
    }

    func pageSize(_ pageIndex: Int) -> (width: Double, height: Double) { (200, 300) }

    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? {
        draws ? PdfRgbaImage(4, 6, [UInt8](repeating: 255, count: 4 * 6 * 4)) : nil
    }

    func close() { disposed = true }
}

/// Takes pictures as 4 by 4 grey squares, one frame each.
final class FakeCodec: ImageCodec {
    func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { nil }

    func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? {
        file.isEmpty ? nil : [PdfRgbaImage(4, 4, [UInt8](repeating: 128, count: 4 * 4 * 4))]
    }

    func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [] }
}

final class FakeFonts: FontSource {
    func find(_ family: String, _ style: FontStyles) -> FontFile? { nil }
}

final class FakeSisters: SisterApps {
    var lazyScanInstalled = false
    var printTaken = false
    var printed: [URL] = []
    var scanOpened = 0

    func openLazyScan() { scanOpened += 1 }

    func tryPrint(_ file: URL) -> Bool {
        printed.append(file)
        return printTaken
    }
}

/// Keeps the path in the bytes of the bookmark. `moved` sends a path to where its file went since; `stale` marks every
/// bookmark as one the system wants made again.
final class PathBookmarks: Bookmarks {
    var moved: [String: String] = [:]
    var stale = false
    var lost = false
    private(set) var grants: [Grant] = []

    func make(_ url: URL) -> Data? { Data(url.standardizedFileURL.path.utf8) }

    func resolve(_ bookmark: Data) -> ResolvedBookmark? {
        if lost { return nil }
        let path = String(decoding: bookmark, as: UTF8.self)
        return ResolvedBookmark(url: URL(fileURLWithPath: moved[path] ?? path), stale: stale)
    }

    func access(_ url: URL) -> FileAccess? {
        let grant = Grant()
        grants.append(grant)
        return grant
    }
}

/// A file grant that counts how often it was stopped.
final class Grant: FileAccess {
    private(set) var stops = 0

    func stop() { stops += 1 }
}

/// One identity, "alice"; it opens whatever the keys are asked to open, and any other is not a recipient.
final class FakeKeys: CertificateKeys {
    static let alice = CertificateChoice(id: "alice", name: "Alice", issuer: "Test", expires: Date().addingTimeInterval(86400 * 365), isValidNow: true)
    static let mallory = CertificateChoice(id: "mallory", name: "Mallory", issuer: "Test", expires: Date().addingTimeInterval(86400 * 365), isValidNow: true)

    func choices() -> [CertificateChoice] { [Self.alice] }

    func open(_ bytes: [UInt8], _ choice: CertificateChoice) throws -> PdfEditSession {
        if choice != Self.alice { throw PdfReadException(.certificateRequired, "The certificate does not open the file.") }
        return try PdfEditSession.open(Pdfs.text())
    }
}

struct TestFolders: AppFolders {
    let root: URL

    var settings: URL { root.appendingPathComponent("settings") }
    var recovery: URL { root.appendingPathComponent("recovery") }
    var thumbnails: URL { root.appendingPathComponent("thumbnails") }
    var printCopies: URL { root.appendingPathComponent("print") }
    var openedAttachments: URL { root.appendingPathComponent("attachments") }
}

/// The renderers the view model asked for. It asks off the main actor, as the app does, so the list has a lock.
final class RendererLog: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeRenderer] = []
    private var draw = true

    var draws: Bool {
        get { lock.withLock { draw } }
        set { lock.withLock { draw = newValue } }
    }

    var renderers: [FakeRenderer] { lock.withLock { made } }

    func next() -> FakeRenderer {
        lock.withLock {
            let renderer = FakeRenderer()
            renderer.draws = draw
            made.append(renderer)
            return renderer
        }
    }
}

/// The view model with stand-ins for the system, and folders of its own for what it writes.
@MainActor
final class ViewModelFixture {
    let dir: TempDir
    let folders: TestFolders
    let sisters = FakeSisters()
    let keys = FakeKeys()
    let bookmarks = PathBookmarks()
    private let log = RendererLog()
    private(set) var vm: AppViewModel!

    init(_ test: XCTestCase, draws: Bool = true) {
        dir = TempDir(test)
        folders = TestFolders(root: dir.url)
        log.draws = draws
        vm = makeViewModel()
    }

    var renderers: [FakeRenderer] { log.renderers }

    /// Whether a renderer made from now on can draw.
    var draws: Bool {
        get { log.draws }
        set { log.draws = newValue }
    }

    func makeViewModel() -> AppViewModel {
        let log = log
        return AppViewModel(renderers: { log.next() }, codec: FakeCodec(), fonts: FakeFonts(), sisters: sisters,
                            certificates: keys, bookmarks: bookmarks, folders: folders)
    }

    func pdf(_ name: String = "a.pdf", pages: Int = 1) -> URL {
        dir.file(name, Pdfs.text(pages))
    }

    func locked(_ name: String = "locked.pdf", fixture: String = "locked.pdf") -> URL {
        dir.file(name, Pdfs.fixture(fixture))
    }
}

/// PDFs for the tests, built by the engine.
enum Pdfs {
    static func text(_ pages: Int = 1, _ line: String = "Hello from the tests.") -> [UInt8] {
        let text = (0..<pages).map { "\(line) Page \($0 + 1)." }.joined(separator: "\u{0C}")
        return try! PdfFromText.create(text, fonts: FakeFonts()).bytes
    }

    /// The file of the fixtures (Tests/Fixtures/Documents) by name.
    static func fixture(_ name: String) -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("Documents").appendingPathComponent(name)
        return [UInt8](try! Data(contentsOf: url))
    }

    /// A file that asks for a certificate: its /Encrypt dictionary names the public-key handler.
    static func forRecipients() -> [UInt8] {
        Array(("%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
            + "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
            + "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>\nendobj\n"
            + "4 0 obj\n<< /Filter /Adobe.PubSec /SubFilter /adbe.pkcs7.s5 /V 4 /Length 128 >>\nendobj\n"
            + "trailer\n<< /Root 1 0 R /Size 5 /Encrypt 4 0 R >>\n%%EOF\n").utf8)
    }

    /// Changes the title, so the session has something to commit.
    static func retitle(_ session: PdfEditSession, _ title: String) throws {
        var metadata = DocumentMetadata.read(session.document)
        metadata.title = title
        try metadata.write(session.document)
    }
}

/// Opens a gate that tests wait at: the main actor runs one thing at a time, so no sleeping is needed.
@MainActor
final class Latch {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        open = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}
