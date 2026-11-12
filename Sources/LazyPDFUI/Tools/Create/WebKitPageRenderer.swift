#if canImport(WebKit)
import Foundation
import WebKit
import PDFKit
import LazyPDFApp
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Draws a local HTML file as a paginated PDF with the system web view: scripts off, every http, https, ws and ftp load blocked
// by a content rule list, and read access for the file's own folder only. createPDF makes one tall page, so the pages come from
// the print path: UIPrintPageRenderer on iOS and a save-to-file NSPrintOperation on the Mac.

@MainActor
public final class WebKitPageRenderer: WebPageRenderer {
    public init() {}

    public func render(_ page: URL, _ layout: WebPageLayout) async throws -> (bytes: [UInt8], pages: Int) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "lazypdf-no-network",
                                                                                      encodedContentRuleList: WebPageRules.blockNetwork)
        // Without the rule the network would be open, so a page is not drawn at all.
        guard let list else { throw WebPageError.couldNotLoad }
        configuration.userContentController.add(list)

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: layout.contentWidth, height: layout.contentHeight), configuration: configuration)
        let loader = PageLoader()
        view.navigationDelegate = loader
        try await loader.load(page, in: view)

        let data = try await paginate(view, layout)
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw WebPageError.couldNotLoad }
        if document.pageCount > WebPageRules.mostPages { throw WebPageError.tooLong }
        return ([UInt8](data), document.pageCount)
    }

    #if os(iOS)
    private func paginate(_ view: WKWebView, _ layout: WebPageLayout) async throws -> Data {
        let paper = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        let renderer = PagedRenderer(paper: paper, margin: layout.margin)
        renderer.addPrintFormatter(view.viewPrintFormatter(), startingAtPageAt: 0)
        let pages = renderer.numberOfPages
        if pages > WebPageRules.mostPages { throw WebPageError.tooLong }
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
        for index in 0..<pages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }
    #else
    private func paginate(_ view: WKWebView, _ layout: WebPageLayout) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: layout.width, height: layout.height)
        info.orientation = layout.width > layout.height ? .landscape : .portrait
        info.topMargin = layout.margin
        info.bottomMargin = layout.margin
        info.leftMargin = layout.margin
        info.rightMargin = layout.margin
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file

        // The web view prints only from inside a window; this one is never shown.
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        let operation = view.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = NSRect(x: 0, y: 0, width: layout.contentWidth, height: layout.contentHeight)

        let done = await PrintRun().run(operation, in: window)
        window.contentView = nil
        guard done, let data = try? Data(contentsOf: file) else { throw WebPageError.couldNotLoad }
        return data
    }
    #endif
}

/// Waits for a navigation to finish, fail or run out of time, and refuses anything but the one file load.
@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    private var waiting: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    func load(_ page: URL, in view: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiting = continuation
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(WebPageRules.loadSeconds))
                self?.finish(.failure(WebPageError.timedOut))
            }
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel()
        timeout = nil
        waiting?.resume(with: result)
        waiting = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(WebPageError.couldNotLoad))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(WebPageError.couldNotLoad))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(WebPageError.couldNotLoad))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.isFileURL == true ? .allow : .cancel
    }
}

#if os(iOS)
/// Page and printable rectangles are read-only on UIPrintPageRenderer, so a subclass answers them.
private final class PagedRenderer: UIPrintPageRenderer {
    private let paper: CGRect
    private let printable: CGRect

    init(paper: CGRect, margin: Double) {
        self.paper = paper
        printable = paper.insetBy(dx: margin, dy: margin)
        super.init()
    }

    override var paperRect: CGRect { paper }
    override var printableRect: CGRect { printable }
}
#else
@MainActor
private final class PrintRun: NSObject {
    private var finished: CheckedContinuation<Bool, Never>?

    func run(_ operation: NSPrintOperation, in window: NSWindow) async -> Bool {
        await withCheckedContinuation { continuation in
            finished = continuation
            operation.runModal(for: window, delegate: self, didRun: #selector(printed(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    @objc private func printed(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        finished?.resume(returning: success)
        finished = nil
    }
}
#endif
#endif
