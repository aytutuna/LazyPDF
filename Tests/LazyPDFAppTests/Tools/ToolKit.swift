import Foundation
import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// What the tool tests share, as windows/LazyPDF.App.Tests/StandIns.cs and Tools/stamps/PanelHarness.cs have it: files with
// the limits a tool has to respect, and a tab with a viewer and a window to attach a model to.

extension Pdfs {
    /// A file that is signed, or certified when `certified`: its catalog names the signature permissions.
    static func signed(certified: Bool, pages: Int = 2) throws -> [UInt8] {
        let document = try PdfDocument.open(text(pages))
        let perms = PdfDictionary()
        perms[certified ? "DocMDP" : "UR3"] = try document.add(PdfDictionary())
        document.catalog["Perms"] = perms
        return try document.saveRewrite(PdfSaveOptions())
    }

    /// A file whose owner password is "owner" and that allows only `allowed` to anyone else.
    static func restricted(_ allowed: PdfPermissions) throws -> [UInt8] {
        let document = try PdfDocument.open(text())
        let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: allowed, strength: .aes256,
                                          firstId: [UInt8](repeating: 7, count: 16))
        return try document.saveRewrite(PdfSaveOptions(security: security))
    }
}

/// A tab over `bytes` with a viewer and a recording window, and a model attached to it by `attach`.
@MainActor
struct ToolRig {
    let tab: DocumentTab
    let viewer: PanelViewer
    let host: RecordingHost

    init(_ bytes: [UInt8]? = nil, password: String? = nil) throws {
        tab = DocumentTab(session: try PdfEditSession.open(bytes ?? Pdfs.text(2), password: password), renderer: FakeRenderer(), url: nil,
                          title: "a.pdf", password: password)
        viewer = PanelViewer(tab)
        host = RecordingHost()
    }

    func attach(_ model: ToolPanelModel) {
        model.attach(tab, viewer, host)
    }
}

/// Lets the main actor run until `condition` holds, for the models that follow the file through an observation or a task.
@MainActor
func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<300 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(condition(), file: file, line: line)
}
