import Foundation
import Observation
import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Stand-ins for the panel tests, as windows/LazyPDF.App.Tests/StandIns.cs has them: a viewer that records where it was sent,
// a window that records what it was told, and the files the panels read.

/// A viewer over one document, with the pages a fixed size. It records every page and rectangle it was sent to.
@MainActor
@Observable
final class PanelViewer: DocumentViewer {
    var tab: DocumentTab?
    var pageIndex = 0
    var zoom = 1.0
    var fit = FitMode.none
    var columns = 1
    var coverPage = false
    var continuous = true
    var rotation = 0
    var tint = PageTint.none
    var readingMode = false
    var mode = PointerMode.hand
    var pointerTool: PagePointerTool?
    var viewRevision = 0
    var layers = LayerSet(layers: [], order: [])
    var search = ViewerSearch(source: { Task { nil } }, startPage: { 0 })

    @ObservationIgnored var sent: [Int] = []
    @ObservationIgnored var revealed: [(page: Int, area: ViewRect)] = []
    @ObservationIgnored var followed: [PdfAction?] = []
    @ObservationIgnored var layerCalls: [(layer: PdfReference, visible: Bool)] = []
    @ObservationIgnored var findShown = 0
    @ObservationIgnored var geometryAsked: [Int] = []

    init(_ tab: DocumentTab? = nil, labels: [String]? = nil) {
        self.tab = tab
        self.labels = labels
        if let tab { layers = PdfLayers.read(tab.document) }
    }

    @ObservationIgnored private let labels: [String]?
    @ObservationIgnored private var off = Set<Int>()

    var pageCount: Int { tab?.pageCount ?? 0 }
    var canGoBack: Bool { false }
    var canGoForward: Bool { false }
    var visiblePages: [Int] { [pageIndex] }
    var hasSelection: Bool { false }

    func show(_ tab: DocumentTab?) {
        self.tab = tab
        layers = tab.map { PdfLayers.read($0.document) } ?? LayerSet(layers: [], order: [])
    }

    func pageLabel(_ page: Int) -> String {
        labels.flatMap { $0.indices.contains(page) ? $0[page] : nil } ?? String(page + 1)
    }

    func goToPage(_ page: Int) {
        sent.append(page)
        pageIndex = page
    }

    func goTo(_ destination: PdfDestination) {
        goToPage(destination.pageIndex)
    }

    func follow(_ action: PdfAction?) {
        followed.append(action)
    }

    func goBack() {}
    func goForward() {}

    func reveal(_ page: Int, _ area: ViewRect) {
        revealed.append((page, area))
    }

    func showFind() {
        findShown += 1
    }

    func showGoToPage() {}

    func pageSize(_ page: Int) -> ViewSize {
        ViewSize(page % 2 == 0 ? 612 : 300, page % 2 == 0 ? 792 : 600)
    }

    @ObservationIgnored private var overlays: [Int: PageOverlay] = [:]

    func overlay(_ page: Int) -> PageOverlay {
        if let known = overlays[page] { return known }
        let made = PageOverlay(page: page, size: pageSize(page))
        overlays[page] = made
        return made
    }

    func endToolMarks(prefix: String) {
        for overlay in overlays.values {
            overlay.finishFields(prefix: prefix)
            overlay.remove(prefix: prefix)
        }
    }

    func pageToView(_ page: Int) -> ViewMatrix? { nil }
    func viewToPage(_ view: ViewPoint, nearest: Bool) -> PagePoint? { nil }

    func geometry(_ page: Int) -> PageGeometry {
        geometryAsked.append(page)
        let size = pageSize(page)
        return PageGeometry(PdfRect(0, 0, size.width, size.height), 0)
    }

    func text(_ page: Int) async -> TextPage? { nil }
    func drawing(_ page: Int) -> [DrawnEdge] { [] }
    var runs: [SelectedRun] = []
    func selection() async -> [SelectedRun] { runs }
    func selectAll() {}
    func clearSelection() {}

    func setLayerVisible(_ layer: PdfReference, _ visible: Bool) {
        layerCalls.append((layer, visible))
        if visible { off.remove(layer.number) } else { off.insert(layer.number) }
        layers = Self.restate(layers, off)
    }

    /// The view turns a layer by itself, as it does for a radio group.
    func viewChanged(_ layer: PdfReference, _ visible: Bool) {
        if visible { off.remove(layer.number) } else { off.insert(layer.number) }
        layers = Self.restate(layers, off)
    }

    private static func restate(_ set: LayerSet, _ off: Set<Int>) -> LayerSet {
        func layer(_ l: PdfLayer) -> PdfLayer {
            PdfLayer(reference: l.reference, name: l.name, isOn: !off.contains(l.reference.number), locked: l.locked, intent: l.intent)
        }
        func node(_ n: LayerNode) -> LayerNode {
            LayerNode(label: n.label, layer: n.layer.map(layer), children: n.children.map(node))
        }
        return LayerSet(layers: set.layers.map(layer), order: set.order.map(node))
    }
}

/// A window that records what the panels told it.
@MainActor
final class RecordingHost: ToolHost {
    var problems: [Problem] = []
    var notices: [(title: String, text: String, action: NoticeAction?)] = []
    var statuses: [String] = []
    var opened: [URL] = []
    var openedAccess: [FileAccess?] = []
    var openedNew: [(pdf: [UInt8], title: String)] = []
    var isDocumentBusy = false
    var certificatesAsked: [CertificateChoice] = []

    func verifyCertificate(_ choice: CertificateChoice) -> X509Certificate? {
        certificatesAsked.append(choice)
        return nil
    }

    func runBusy(_ text: String, _ work: @MainActor (CancelToken) async throws -> Void) async throws {
        try await work(CancelToken())
    }

    func setBusyText(_ text: String) {}
    func showProblem(_ problem: Problem) { problems.append(problem) }
    func showNotice(_ title: String, _ text: String, _ action: NoticeAction?) { notices.append((title, text, action)) }
    func setStatus(_ sentence: String) { statuses.append(sentence) }
    func open(_ url: URL, access: FileAccess?) async {
        opened.append(url)
        openedAccess.append(access)
    }

    func openNew(_ pdf: [UInt8], title: String, password: String?, certificate: CertificateChoice?) async {
        openedNew.append((pdf, title))
    }

    func tryReload(_ tab: DocumentTab) async -> Bool { true }
}

/// Draws a page as wide as its dpi says, so the size of a picture shows what was asked for.
final class DpiRenderer: DocumentRenderer {
    var draws = true
    private(set) var rendered: [(page: Int, dpi: Double)] = []

    func load(_ session: PdfEditSession, _ password: String?) -> Bool { draws }
    func pageSize(_ pageIndex: Int) -> (width: Double, height: Double) { (612, 792) }
    func close() {}

    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? {
        rendered.append((pageIndex, dpi))
        guard draws else { return nil }
        let width = max(Int((612 * dpi / 72).rounded()), 1)
        let height = max(Int((792 * dpi / 72).rounded()), 1)
        return PdfRgbaImage(width, height, [UInt8](repeating: 255, count: width * height * 4))
    }
}

enum PanelPdfs {
    /// Two pages, two bookmarks (the first with a child), two attachments, two layers (the second locked), and a form that
    /// says the file is signed when `signed` is set.
    static func full(signed: Bool = false) -> [UInt8] {
        let form = signed ? " /AcroForm << /SigFlags 3 >>" : ""
        let content = "/OC /L1 BDC 0 0 0 rg 20 20 160 160 re f EMC"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R /Names << /EmbeddedFiles << /Names [(note.txt) 10 0 R (run.exe) 11 0 R] >> >>"
                + " /OCProperties << /OCGs [5 0 R 6 0 R] /D << /Order [5 0 R 6 0 R] /ON [5 0 R 6 0 R] /Locked [6 0 R] >> >>\(form) >>",
            "<< /Type /Pages /Kids [3 0 R 12 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Resources << /Properties << /L1 5 0 R /L2 6 0 R >> >> >>",
            "<< /Length \(content.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /OCG /Name (Black box) >>",
            "<< /Type /OCG /Name (Notes) >>",
            "<< /Type /Outlines /First 8 0 R /Last 9 0 R /Count 3 >>",
            "<< /Title (Chapter 1) /Parent 7 0 R /Next 9 0 R /First 15 0 R /Last 15 0 R /Count 1 /Dest [3 0 R /Fit] /F 3 >>",
            "<< /Title (Chapter 2) /Parent 7 0 R /Prev 8 0 R /Dest [12 0 R /Fit] >>",
            "<< /Type /Filespec /F (note.txt) /UF (note.txt) /Desc (A note) /EF << /F 13 0 R >> >>",
            "<< /Type /Filespec /F (run.exe) /UF (run.exe) /EF << /F 14 0 R >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 600] >>",
            "<< /Type /EmbeddedFile /Length 5 /Params << /Size 5 >> >>\nstream\nhello\nendstream",
            "<< /Type /EmbeddedFile /Length 2 /Params << /Size 2 >> >>\nstream\nMZ\nendstream",
            "<< /Title (Section 1.1) /Parent 8 0 R /Dest [3 0 R /Fit] >>",
        ]
        var file = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(file.utf8.count)
            file += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = file.utf8.count
        file += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { file += String(repeating: "0", count: 10 - String(offset).count) + "\(offset) 00000 n \n" }
        file += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Array(file.utf8)
    }

    @MainActor
    static func tab(_ bytes: [UInt8], title: String = "a.pdf", renderer: DocumentRenderer = FakeRenderer()) throws -> DocumentTab {
        DocumentTab(session: try PdfEditSession.open(bytes), renderer: renderer, url: nil, title: title)
    }

    /// Adds notes on page `page`: one by Ada, one by Grace with a reply from Ada.
    @MainActor
    static func comment(_ tab: DocumentTab, page: Int = 0, author: String = "Ada", text: String = "Look") throws {
        let writer = PdfAnnotationWriter(tab.document)
        let info = AnnotationInfo(author: author, contents: text, date: DateTimeOffset(2026, 3, 1, 0, 0, 0))
        _ = try writer.addNote(tab.document.pages[page], PdfRect(100, 100, 120, 120), info)
        try tab.commit("Comment")
    }
}

/// Waits on the main actor until `condition` holds, for what the panels do on a task of their own.
@MainActor
func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<300 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(condition(), file: file, line: line)
}
