#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// Stand-ins for the system, as Tests/LazyPDFAppTests/Shell/StandIns.swift has them, and the picture of a view.

final class StandInRenderer: DocumentRenderer {
    func load(_ session: PdfEditSession, _ password: String?) -> Bool { true }

    func pageSize(_ pageIndex: Int) -> (width: Double, height: Double) { (200, 300) }

    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? { nil }

    func close() {}
}

final class StandInCodec: ImageCodec {
    func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { nil }

    func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? { nil }

    func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [] }
}

final class StandInFonts: FontSource {
    func find(_ family: String, _ style: FontStyles) -> FontFile? { nil }
}

struct StandInSisters: SisterApps {
    var lazyScanInstalled: Bool { false }
    var lazyPrintInstalled: Bool { false }

    func openLazyScan() {}

    func tryPrint(_ file: URL) -> Bool { false }
}

struct StandInBookmarks: Bookmarks {
    func make(_ url: URL) -> Data? { Data(url.standardizedFileURL.path.utf8) }

    func resolve(_ bookmark: Data) -> ResolvedBookmark? {
        ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)), stale: false)
    }

    func access(_ url: URL) -> FileAccess? { nil }
}

final class StandInKeys: CertificateKeys {
    static let alice = CertificateChoice(id: "alice", name: "Alice", issuer: "Test", expires: Date().addingTimeInterval(86400 * 365), isValidNow: true)

    func choices() -> [CertificateChoice] { [Self.alice] }

    func open(_ bytes: [UInt8], _ choice: CertificateChoice) throws -> PdfEditSession {
        try PdfEditSession.open(StandInPdfs.text())
    }

    func verifyCertificate(_ choice: CertificateChoice) -> X509Certificate? { nil }
}

struct StandInFolders: AppFolders {
    let root: URL

    var settings: URL { root.appendingPathComponent("settings") }
    var recovery: URL { root.appendingPathComponent("recovery") }
    var thumbnails: URL { root.appendingPathComponent("thumbnails") }
    var printCopies: URL { root.appendingPathComponent("print") }
    var openedAttachments: URL { root.appendingPathComponent("attachments") }
}

enum StandInPdfs {
    static func text(_ pages: Int = 1) -> [UInt8] {
        let text = (0..<pages).map { "Hello from the tests. Page \($0 + 1)." }.joined(separator: "\u{0C}")
        return try! PdfFromText.create(text, fonts: StandInFonts()).bytes
    }

    /// A file that asks for a certificate: its /Encrypt dictionary names the public-key handler.
    static func forRecipients() -> [UInt8] {
        Array(("%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
            + "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
            + "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>\nendobj\n"
            + "4 0 obj\n<< /Filter /Adobe.PubSec /SubFilter /adbe.pkcs7.s5 /V 4 /Length 128 >>\nendobj\n"
            + "trailer\n<< /Root 1 0 R /Size 5 /Encrypt 4 0 R >>\n%%EOF\n").utf8)
    }

    /// The file of the fixtures (Tests/Fixtures/Documents) by name.
    static func fixture(_ name: String) -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("Documents").appendingPathComponent(name)
        return [UInt8](try! Data(contentsOf: url))
    }
}

/// The view model with stand-ins for the system, and a folder of its own for what it writes.
@MainActor
final class ShellFixture {
    let root: URL
    let vm: AppViewModel

    init(_ test: XCTestCase) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lazypdf-ui-tests-" + UUID().uuidString, isDirectory: true)
        let folder = root
        test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        vm = AppViewModel(renderers: { StandInRenderer() }, codec: StandInCodec(), fonts: StandInFonts(), sisters: StandInSisters(),
                          certificates: StandInKeys(), bookmarks: StandInBookmarks(), folders: StandInFolders(root: root))
    }

    func file(_ name: String, _ bytes: [UInt8]) -> URL {
        let url = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data(bytes).write(to: url)
        return url
    }

    func openDocuments(_ count: Int) async {
        for index in 0..<count {
            await vm.open(file("doc\(index + 1).pdf", StandInPdfs.text(index + 1)))
        }
    }

    /// The window with plain text in the three slots.
    func window() -> some View {
        AppWindow(vm, stage: { tab in Text(tab.title) }, sidePane: { id, _ in Text(id) }, inspector: { id, _ in Text(id) })
    }
}

/// A view as a picture at a fixed size.
@MainActor
func picture<V: View>(_ view: V, _ width: CGFloat, _ height: CGFloat) -> CGImage? {
    let renderer = ImageRenderer(content: view.frame(width: width, height: height))
    renderer.scale = 1
    return renderer.cgImage
}

/// How many different byte values the picture holds: a blank one holds a few.
func variety(_ image: CGImage) -> Int {
    guard let data = image.dataProvider?.data as Data? else { return 0 }
    return Set(data).count
}

/// Opens a gate that a test waits at.
@MainActor
final class Gate {
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
#endif
