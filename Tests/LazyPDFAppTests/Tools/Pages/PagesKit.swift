import Foundation
import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// What the Pages and Combine tests share: a window that records what it was told and answers the pickers, as the hosts of
// windows/LazyPDF.App.Tests/Tools/Pages have it, and helpers to read the pages of a tab.

@MainActor
final class StubPicker: ToolFilePicker {
    var files: [ToolFile] = []

    /// Runs while the picker is up, as whatever the person does meanwhile.
    var during: (() -> Void)?

    func pickFiles(_ kinds: [ToolFileKind], multiple: Bool) async -> [ToolFile] {
        during?()
        return files
    }

    func pickFolder() async -> ToolFile? { nil }
}

/// Reads what it was given at once, since the files are taken down when the call returns.
@MainActor
final class PagesExporter: ToolFileExporter {
    var received: [(name: String, bytes: [UInt8])] = []
    private(set) var urls: [URL] = []
    var gaveUp = false

    /// Names of files the stand-in cannot write, as a full disk would leave them.
    var failing: Set<String> = []

    func export(_ files: [URL]) async -> ToolExport {
        urls = files
        received = files.map { ($0.lastPathComponent, [UInt8]((try? Data(contentsOf: $0)) ?? Data())) }
        if gaveUp { return ToolExport() }
        return ToolExport(
            saved: files.filter { !failing.contains($0.lastPathComponent) }
                .map { URL(fileURLWithPath: "/saved").appendingPathComponent($0.lastPathComponent) },
            failed: files.filter { failing.contains($0.lastPathComponent) })
    }
}

final class PagesFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }
}

@MainActor
final class PagesHost: ToolHost {
    var problems: [Problem] = []
    var notices: [(title: String, text: String, action: NoticeAction?)] = []
    var statuses: [String] = []
    var opened: [URL] = []
    var openedNew: [(pdf: [UInt8], title: String)] = []
    var holding = false
    let picker = StubPicker()
    let exporter = PagesExporter()

    var filePicker: ToolFilePicker { picker }
    var fileExporter: ToolFileExporter { exporter }

    /// Presses Cancel shortly after the job starts.
    var cancelsBusy = false

    func runBusy(_ text: String, _ work: @MainActor (CancelToken) async throws -> Void) async throws {
        let token = CancelToken()
        if cancelsBusy {
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000)
                token.cancel()
            }
        }
        do {
            try await work(token)
        } catch is CancellationError {
            setStatus("Cancelled.")
        }
    }

    func setBusyText(_ text: String) {}
    func showProblem(_ problem: Problem) { problems.append(problem) }
    func showNotice(_ title: String, _ text: String, _ action: NoticeAction?) { notices.append((title, text, action)) }
    func setStatus(_ sentence: String) { statuses.append(sentence) }
    func holdStage(_ on: Bool) { holding = on }

    func open(_ url: URL, access: FileAccess?) async {
        opened.append(url)
    }

    func openNew(_ pdf: [UInt8], title: String, password: String?, certificate: CertificateChoice?) async {
        openedNew.append((pdf, title))
    }

    func tryReload(_ tab: DocumentTab) async -> Bool { true }
}

/// Answers the questions of a source file from a list, and records them.
@MainActor
final class StubAsker: SourceAsker {
    var passwords: [String?]
    var certificates: [CertificateChoice?] = []
    var asked: [Bool] = []

    init(passwords: [String?] = []) {
        self.passwords = passwords
    }

    func password(for name: String, wrong: Bool) async -> String? {
        asked.append(wrong)
        return passwords.isEmpty ? nil : passwords.removeFirst()
    }

    func certificate(for name: String, wrong: Bool) async -> CertificateChoice? {
        asked.append(wrong)
        return certificates.isEmpty ? nil : certificates.removeFirst()
    }
}

extension DocumentTab {
    /// The content of a page, which differs from page to page of the files the tests make.
    func text(_ page: Int) -> String {
        String(bytes: document.pages[page].contents(), encoding: .isoLatin1) ?? ""
    }

    var order: [String] { (0..<pageCount).map(text) }
}

enum PagesPdfs {
    /// A file with an open password, so that it asks for one.
    static func locked(_ pages: Int = 3) throws -> [UInt8] {
        let document = try PdfDocument.open(Pdfs.text(pages))
        let security = PdfSecurity.create(userPassword: "secret", ownerPassword: "owner", permissions: .all, strength: .aes256,
                                          firstId: [UInt8](repeating: 7, count: 16))
        return try document.saveRewrite(PdfSaveOptions(security: security))
    }

    /// A file with the bookmarks at these pages.
    static func withBookmarksFile(_ pages: Int, _ starts: [Int]) throws -> [UInt8] {
        let session = try PdfEditSession.open(Pdfs.text(pages))
        let outline = Outline.read(session.document)
        for start in starts {
            let item = OutlineItem()
            item.title = "Part \(start)"
            item.destination = PdfDestination(start)
            _ = try outline.add(item)
        }
        try outline.write(session.document)
        _ = try session.commit("Bookmarks")
        return session.current
    }

    static func withBookmarks(_ pages: Int, _ starts: [Int]) throws -> PdfDocument {
        try PdfDocument.open(withBookmarksFile(pages, starts))
    }

    /// Two pages and a tag tree; only the first page is tagged.
    static func tagged() -> [UInt8] {
        var file = "%PDF-1.7\n"
        var offsets: [Int] = []
        func obj(_ body: String) {
            offsets.append(file.utf8.count)
            file += "\(offsets.count) 0 obj\n\(body)\nendobj\n"
        }
        obj("<</Type /Catalog /Pages 2 0 R /MarkInfo <</Marked true>> /StructTreeRoot 5 0 R>>")
        obj("<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>")
        obj("<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /StructParents 0>>")
        obj("<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]>>")
        obj("<</Type /StructTreeRoot /K 6 0 R /ParentTree <</Nums [0 [6 0 R]]>>>>")
        obj("<</Type /StructElem /S /P /P 5 0 R /Pg 3 0 R /K 0>>")
        let xref = file.utf8.count
        file += "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { file += String(repeating: "0", count: 10 - String(offset).count) + "\(offset) 00000 n \n" }
        file += "trailer\n<</Size \(offsets.count + 1) /Root 1 0 R>>\nstartxref\n\(xref)\n%%EOF\n"
        return Array(file.utf8)
    }
}

/// A tab over `bytes` with a viewer and a window that answers the pickers.
@MainActor
struct PagesRig {
    let tab: DocumentTab
    let viewer: PanelViewer
    let host = PagesHost()

    init(_ bytes: [UInt8]? = nil, title: String = "a.pdf", password: String? = nil) throws {
        tab = DocumentTab(session: try PdfEditSession.open(bytes ?? Pdfs.text(2), password: password), renderer: FakeRenderer(), url: nil,
                          title: title, password: password)
        viewer = PanelViewer(tab)
    }

    /// Hands the picker a file made of `bytes`.
    func pick(_ dir: TempDir, _ name: String, _ bytes: [UInt8]) {
        host.picker.files = [ToolFile(url: dir.file(name, bytes))]
    }
}
