import Foundation
import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/compare/CompareKit.cs: files and renderers for the comparison tests.

enum CompareKit {
    static func before() -> [UInt8] { Pdfs.text(2) }

    /// The same two pages with a word added on each, a form field and a new title.
    static func after() throws -> [UInt8] {
        let session = try PdfEditSession.open(Pdfs.text(2, "Hello from the other tests."))
        _ = try PdfForm.read(session.document).addField(FieldSpec(.text, "name", 0, PdfRect(100, 400, 300, 420), value: "Ann"))
        try Pdfs.retitle(session, "Second")
        try session.commit("Edit")
        return session.current
    }

    @MainActor
    static func session(_ before: [UInt8], _ after: [UInt8], _ renderers: (() -> DocumentRenderer)? = nil) async throws -> CompareSession {
        let session = try CompareSession(CompareSide(bytes: before, name: "old.pdf", password: nil),
                                         CompareSide(bytes: after, name: "new.pdf", password: nil), renderers ?? { FakeRenderer() })
        try await session.compare(CompareOptions(), byPixels: false)
        return session
    }

    /// A file that asks for `userPassword`.
    static func locked(_ userPassword: String) throws -> [UInt8] {
        let document = try PdfDocument.open(Pdfs.text(2, "Hello from the other tests."))
        let security = PdfSecurity.create(userPassword: userPassword, ownerPassword: "owner", permissions: .all, strength: .aes256,
                                          firstId: document.firstId ?? [])
        return try document.saveRewrite(PdfSaveOptions(security: security))
    }

    /// The old file draws blank pages, the new one a page of specks and a page with one block.
    static func speckled() -> () -> DocumentRenderer {
        let made = Counter()
        return {
            made.count += 1
            return SpeckledRenderer(specks: made.count > 1)
        }
    }

    /// The old file draws blank pages, the new one pages with a black block.
    static func painted() -> () -> DocumentRenderer {
        let made = Counter()
        return {
            made.count += 1
            return PaintedRenderer(block: made.count > 1)
        }
    }

    static func undrawn() -> () -> DocumentRenderer {
        {
            let renderer = FakeRenderer()
            renderer.draws = false
            return renderer
        }
    }
}

final class PaintedRenderer: DocumentRenderer {
    private let block: Bool

    init(block: Bool) {
        self.block = block
    }

    func load(_ session: PdfEditSession, _ password: String?) -> Bool { true }
    func pageSize(_ pageIndex: Int) -> (width: Double, height: Double) { (200, 300) }
    func close() {}

    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? {
        var rgba = [UInt8](repeating: 255, count: 200 * 300 * 4)
        if block {
            for y in 100..<140 {
                for x in 60..<120 { for c in 0..<3 { rgba[(y * 200 + x) * 4 + c] = 0 } }
            }
        }
        return PdfRgbaImage(200, 300, rgba)
    }
}

final class SpeckledRenderer: DocumentRenderer {
    private let specks: Bool

    init(specks: Bool) {
        self.specks = specks
    }

    func load(_ session: PdfEditSession, _ password: String?) -> Bool { true }
    func pageSize(_ pageIndex: Int) -> (width: Double, height: Double) { (200, 300) }
    func close() {}

    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? {
        var rgba = [UInt8](repeating: 255, count: 200 * 300 * 4)
        if specks {
            for y in 0..<300 {
                for x in 0..<200 {
                    let ink = pageIndex == 0 ? x % 12 < 4 && y % 12 < 4 && y < 120 : (60..<120).contains(x) && (100..<140).contains(y)
                    if ink { for c in 0..<3 { rgba[(y * 200 + x) * 4 + c] = 0 } }
                }
            }
        }
        return PdfRgbaImage(200, 300, rgba)
    }
}

/// A host that cancels whatever it is asked to run, as the Cancel button does.
@MainActor
final class CancellingHost: ToolHost {
    private(set) var opened = 0

    func runBusy(_ text: String, _ work: @MainActor (CancelToken) async throws -> Void) async throws {
        let token = CancelToken()
        token.cancel()
        do {
            try await work(token)
        } catch is CancellationError {
        }
    }

    func setBusyText(_ text: String) {}
    func showProblem(_ problem: Problem) {}
    func showNotice(_ title: String, _ text: String, _ action: NoticeAction?) {}
    func setStatus(_ sentence: String) {}
    func open(_ url: URL, access: FileAccess?) async {}

    func openNew(_ pdf: [UInt8], title: String, password: String?, certificate: CertificateChoice?) async {
        opened += 1
    }

    func tryReload(_ tab: DocumentTab) async -> Bool { true }
}
