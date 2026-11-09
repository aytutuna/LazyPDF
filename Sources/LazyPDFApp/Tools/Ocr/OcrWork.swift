import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Ocr/OcrWork.cs: what the panel does to the document, apart from the controls.

@MainActor
public enum OcrWork {
    public static let dpi = 300.0

    /// Reads a copy of the file off the main actor, so the document can be used meanwhile, and writes the layers into the
    /// document if it is still the one that was read. Nil when cancelled, when the language is missing or when the
    /// document changed.
    public static func makeSearchable(_ tab: DocumentTab, _ host: ToolHost, _ recognizer: TextRecognizer,
                                      _ options: OcrOptions) async throws -> OcrResult? {
        let open = OpenCopy.of(tab, host)
        let revision = tab.revision
        let dropsLayers = options.existing == .replace && hasLayer(tab.document, options.pages)
        let renderer = tab.renderer
        var read: OcrRead?
        do {
            try await host.runBusy(L10n.t("Reading pages")) { token in
                read = try await readCopy(open, recognizer, renderer, options, token) { done, total in
                    host.setBusyText(OcrStatusText.status(done, total))
                }
            }
        } catch let error as InvalidOperationException {
            host.showProblem(Problem(L10n.t("Language not available"), error.message))
            return nil
        }
        guard let read else { return nil }
        if tab.revision != revision {
            host.showNotice(L10n.t("The file changed"), L10n.t("Nothing was added. Run it again."), nil)
            return nil
        }

        var result = read.result
        if !read.pages.isEmpty {
            result.words = try PdfOcrLayer.add(tab.document, read.pages, options.language)
            result.committed = try tab.commit(OcrStatusText.label)
        }
        if result.committed {
            host.setStatus(L10n.plural(result.added, one: "Made {0} page searchable", other: "Made {0} pages searchable"))
        } else if result.noWords == 0 && result.notRendered == 0 {
            host.setStatus(OcrStatusText.nothing)
        }
        if let text = left(result, dropsLayers) { host.showNotice(L10n.t("Not every page was read"), text, nil) }
        return result
    }

    // The job runs on its own task so that Cancel ends the wait at once and reaches the recognizer through the task.
    private static func readCopy(_ open: @escaping @Sendable () throws -> PdfDocument, _ recognizer: TextRecognizer,
                                 _ renderer: PageRenderer, _ options: OcrOptions, _ token: CancelToken,
                                 _ progress: @escaping @MainActor (Int, Int) -> Void) async throws -> OcrRead {
        let job = Task.detached {
            let document = try open()
            return try await PdfSearchable.readAsync(document, recognizer, renderer, options) { step in
                Task { @MainActor in progress(step.done, step.total) }
            }
        }
        let watcher = Task {
            while !Task.isCancelled {
                if token.isCancelled { return job.cancel() }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        defer { watcher.cancel() }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    /// Why the file may not be changed; nil when it may.
    public static func refusal(_ document: PdfDocument) -> Problem? {
        guard let security = document.security, !security.openedAsOwner, !security.permissions.contains(.modify) else { return nil }
        return Problems.restricted()
    }

    /// False when the change has to wait: the file forbids it, or the info bar asks first and `go` runs on a yes.
    public static func cleared(_ tab: DocumentTab, _ host: ToolHost, go: @escaping @MainActor () -> Void, caution: String? = nil) -> Bool {
        if let problem = refusal(tab.document) {
            host.showProblem(problem)
            return false
        }
        var cautions: [String] = []
        if tab.document.isSigned { cautions.append(L10n.t("This file is signed, so changing it breaks the signatures.")) }
        if let caution { cautions.append(caution) }
        if cautions.isEmpty { return true }
        host.showNotice(L10n.t("Check before going on"), cautions.joined(separator: " "), NoticeAction(L10n.t("Go on anyway"), go))
        return false
    }

    /// Takes our text layer off the pages. Returns how many had one.
    public static func remove(_ tab: DocumentTab, _ pages: [Int]) throws -> Int {
        let document = tab.document
        let removed = pages.filter { $0 < document.pages.count }.filter { PdfOcrLayer.remove(document, document.pages[$0]) }.count
        if removed > 0 { try tab.commit(L10n.t("Remove text layer")) }
        return removed
    }

    /// Changes one word of a page's layer; empty text removes it. False when the word already reads so.
    @discardableResult
    public static func correct(_ tab: DocumentTab, _ page: Int, _ index: Int, _ text: String) throws -> Bool {
        let document = tab.document
        guard page < document.pages.count,
              let current = try PdfOcrLayer.words(document, document.pages[page]).first(where: { $0.index == index }),
              current.text != text else { return false }
        try PdfOcrLayer.correct(document, document.pages[page], index, text)
        try tab.commit(L10n.t("Correct word"))
        return true
    }

    private static func hasLayer(_ document: PdfDocument, _ pages: [Int]?) -> Bool {
        (pages ?? Array(0..<document.pages.count)).contains { $0 < document.pages.count && PdfOcrLayer.has(document, document.pages[$0]) }
    }

    private static func left(_ result: OcrResult, _ dropsLayers: Bool) -> String? {
        var parts: [String] = []
        if result.notRendered > 0 {
            parts.append(L10n.plural(result.notRendered, one: "{0} page could not be drawn.", other: "{0} pages could not be drawn."))
        }
        if result.noWords > 0 {
            parts.append(L10n.plural(result.noWords, one: "No text found on {0} page. Check the language.",
                                     other: "No text found on {0} pages. Check the language."))
            if dropsLayers { parts.append(L10n.t("Text read earlier on those pages was removed. Undo brings it back.")) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
