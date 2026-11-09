import Foundation
import LazyPDFKit
@testable import LazyPDFApp

// What the model tests of the Forms tool share: a window that also answers the pickers, a tab with a viewer, and pointer events
// for a tool.

@MainActor
final class FormsPicker: ToolFilePicker, ToolFileExporter {
    var picked: [ToolFile] = []
    var exported: [(name: String, bytes: [UInt8])] = []

    func pickFiles(_ kinds: [ToolFileKind], multiple: Bool) async -> [ToolFile] { picked }
    func pickFolder() async -> ToolFile? { nil }

    func export(_ files: [URL]) async -> [URL] {
        for file in files { exported.append((file.lastPathComponent, [UInt8](try! Data(contentsOf: file)))) }
        return files
    }
}

@MainActor
final class FormsHost: ToolHost {
    var problems: [Problem] = []
    var notices: [(title: String, text: String, action: NoticeAction?)] = []
    var statuses: [String] = []
    var signing: [String] = []
    let picker = FormsPicker()

    var filePicker: ToolFilePicker { picker }
    var fileExporter: ToolFileExporter { picker }

    func runBusy(_ text: String, _ work: @MainActor (CancelToken) async throws -> Void) async throws { try await work(CancelToken()) }
    func setBusyText(_ text: String) {}
    func showProblem(_ problem: Problem) { problems.append(problem) }
    func showNotice(_ title: String, _ text: String, _ action: NoticeAction?) { notices.append((title, text, action)) }
    func setStatus(_ sentence: String) { statuses.append(sentence) }
    func open(_ url: URL, access: FileAccess?) async {}
    func openNew(_ pdf: [UInt8], title: String, password: String?, certificate: CertificateChoice?) async {}
    func tryReload(_ tab: DocumentTab) async -> Bool { true }
    func openSigning(_ field: String) { signing.append(field) }
}

@MainActor
struct FormsRig {
    let tab: DocumentTab
    let viewer: PanelViewer
    let host: FormsHost
    let model: FormsModel

    init(_ bytes: [UInt8]? = nil, password: String? = nil) throws {
        tab = DocumentTab(session: try PdfEditSession.open(try bytes ?? FormPdfs.standard(), password: password), renderer: FakeRenderer(),
                          url: nil, title: "form.pdf", password: password)
        viewer = PanelViewer(tab)
        host = FormsHost()
        model = FormsModel(fonts: FormPdfs.fonts)
        model.attach(tab, viewer, host)
    }

    var form: PdfForm { FormPdfs.read(tab) }

    /// An edit made behind the model's back, which then reads the file again as it does when the change reaches it.
    @discardableResult
    func change<T>(_ label: String, _ edit: (PdfForm) throws -> T) throws -> T {
        let result = try FormEdits.apply(tab, FormPdfs.fonts, label, edit)
        model.reload()
        return result
    }

    /// The page point of the middle of a widget of page 0, which the stand-in viewer lays out 612 by 792 as the file is.
    func centre(_ name: String, _ index: Int = 0) -> ViewPoint {
        let rect = form.find(name)!.widgets[index].rect
        return ViewPoint((rect.left + rect.right) / 2, 792 - (rect.bottom + rect.top) / 2)
    }

    func pointer(_ point: ViewPoint, pressed: Bool, page: Int = 0) -> PagePointer {
        PagePointer(page: page, point: point, view: point, pressed: pressed, clicks: pressed ? 1 : 0)
    }

    func tap(_ point: ViewPoint) {
        let tool = viewer.pointerTool!
        tool.press(pointer(point, pressed: true))
        tool.release(pointer(point, pressed: false))
    }

    func drag(from: ViewPoint, to: ViewPoint) {
        let tool = viewer.pointerTool!
        tool.press(pointer(from, pressed: true))
        tool.move(pointer(to, pressed: true))
        tool.release(pointer(to, pressed: false))
    }

    func field(_ name: String, page: Int = 0) -> OverlayField? {
        viewer.overlay(page).fields.first { $0.id.contains("." + name + ".") }
    }
}

extension FormPdfs {
    /// The standard form in a file that says it is signed.
    static func signedForm() throws -> [UInt8] {
        let document = try PdfDocument.open(standard())
        let perms = PdfDictionary()
        perms["UR3"] = try document.add(PdfDictionary())
        document.catalog["Perms"] = perms
        return try document.saveRewrite(PdfSaveOptions())
    }

    /// The standard form in a file that lets its readers print and nothing else.
    static func printOnly() throws -> [UInt8] {
        let document = try PdfDocument.open(standard())
        let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: [.print], strength: .aes256,
                                          firstId: [UInt8](repeating: 7, count: 16))
        return try document.saveRewrite(PdfSaveOptions(security: security))
    }
}
