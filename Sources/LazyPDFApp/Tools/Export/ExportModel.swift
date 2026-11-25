import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Export/ExportPanel.xaml.cs and ExportJob.cs: saves the document, or some of its pages, as
// Word, Excel, PowerPoint, HTML, Markdown, RTF, text or pictures. The files are written to a folder of the app's own and
// handed to host.fileExporter, which asks the person where they go.

@MainActor
@Observable
public final class ExportModel: ToolPanelModel {
    public static let dpiSteps = [72, 96, 150, 300, 600]

    public var format = ExportFormat.word
    public var scope = PageScope.all
    public var pagesText = ""
    public var fixedHtml = false
    public var markdownPictures = false
    public var picture = PictureFormat.png
    public var dpiIndex = 2
    public var quality = 85

    var tab: DocumentTab?
    var host: ToolHost?
    @ObservationIgnored private var viewer: DocumentViewer?
    @ObservationIgnored private let codec: ImageCodec?
    @ObservationIgnored private let renderers: () -> DocumentRenderer
    @ObservationIgnored private let reveal: ((URL) -> Void)?

    /// `renderers` makes the renderer a copy of the file is drawn with for pictures of pages; `reveal` shows a file or folder
    /// to the person, where the platform can.
    public init(codec: ImageCodec? = nil, renderers: @escaping () -> DocumentRenderer, reveal: ((URL) -> Void)? = nil) {
        self.codec = codec
        self.renderers = renderers
        self.reveal = reveal
    }

    public var action: ToolAction? {
        ToolAction(L10n.t("Export"), symbol: "square.and.arrow.up", canRun: { [self] in tab != nil && blocker == nil }, run: { [self] in await run() })
    }

    public var pages: ExportPages {
        ExportPages.of(scope, pagesText, current: viewer?.pageIndex ?? 0, count: tab?.pageCount ?? 0)
    }

    /// Why the export cannot run now; nil when it can.
    public var blocker: String? {
        guard let tab else { return nil }
        _ = tab.revision
        if !Exporter.allowed(tab.document) { return L10n.t("This file does not allow copying its content.") }
        if format == .pictures && !tab.canDraw { return L10n.t("The system cannot draw this file.") }
        return pages.error
    }

    public var options: ExportOptions {
        ExportOptions(format, pages: pages.pages, fixedHtml: fixedHtml, markdownPictures: markdownPictures, picture: picture,
                      dpi: Self.dpiSteps[min(max(dpiIndex, 0), Self.dpiSteps.count - 1)], quality: quality)
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.viewer = viewer
        self.host = host
    }

    public func detach() {
        tab = nil
        viewer = nil
        host = nil
    }

    private func run() async {
        guard let tab, let host else { return }
        let name = L10n.t("Export")
        await ChangeGate.guardedAsync(host, name) { [self] in
            await tab.whenDrawn()
            let options = options
            let source = Exporter.source(tab, host, codec: codec)
            let makeRenderer = renderers
            let folder = Exporter.workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            var result: ExportResult?
            do {
                try await host.runBusy(L10n.t("Exporting")) { token in
                    result = try await ToolDocuments.run(token) {
                        var source = source
                        let drawn = options.format == .pictures ? Exporter.snapshot(source, makeRenderer) : nil
                        if let drawn { source.renderer = drawn }
                        defer { drawn?.close() }
                        return try Exporter.write(source, options, to: folder, token)
                    }
                }
            } catch let error where error is PdfReadException || Problems.isFileSystem(error) {
                host.showProblem(ExportProblems.failed(error, tab.title))
                return
            }
            guard let result else { return }

            if result.files.isEmpty {
                tellNothingWasWritten(result, options, host)
                return
            }
            let outcome = await host.fileExporter.export(result.files)
            let saved = outcome.saved
            guard let first = saved.first else {
                if let failed = outcome.failed.first { host.showProblem(ExportProblems.notSaved(failed, denied: outcome.denied)) }
                return
            }

            let place = options.toFolder ? first.deletingLastPathComponent() : first
            var text = saved.count == 1 && !options.toFolder
                ? L10n.t("Saved as {0}.", first.lastPathComponent)
                : L10n.plural(saved.count, one: "Saved {0} file in {1}.", other: "Saved {0} files in {1}.", Self.leaf(place))
            if !outcome.failed.isEmpty {
                text += " " + L10n.plural(outcome.failed.count, one: "{0} file could not be saved.", other: "{0} files could not be saved.")
            }
            if result.skipped > 0 {
                text += " " + L10n.plural(result.skipped, one: "{0} page could not be drawn.", other: "{0} pages could not be drawn.")
            }
            if result.picturesLeftOut > 0 { text += " " + ExportText.picturesLeftOut(result.picturesLeftOut) }
            if result.gap == .outsideTables {
                text += " " + L10n.t("Text outside the tables was left out.")
            } else if result.gap == .pastSheetLimit {
                text += " " + L10n.t("Pages past the first 1000 sheets were left out.")
            }
            let show = reveal.map { reveal in NoticeAction(L10n.t("Show in folder")) { reveal(place) } }
            host.showNotice(L10n.t("Exported"), text, show)
            host.setStatus(L10n.t("Export saved."))
        }
    }

    private func tellNothingWasWritten(_ result: ExportResult, _ options: ExportOptions, _ host: ToolHost) {
        if result.gap == .noText {
            let makeSearchable = NoticeAction(L10n.t("Make searchable")) { [weak host] in host?.openToolReturning("ocr", back: "export") }
            host.showNotice(L10n.t("No text found"),
                            L10n.t("This file has no text to export. Run Make searchable first, or save the pages as pictures."), makeSearchable)
        } else if options.format == .images {
            host.showNotice(L10n.t("No pictures found"), L10n.t("This file has no pictures to save."), nil)
        } else {
            host.showProblem(Problem(L10n.t("Nothing exported"), L10n.t("The system cannot draw these pages. Try another format.")))
        }
    }

    // A drive root has no file name; the root is what the folder is called then.
    nonisolated static func leaf(_ url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}

enum ExportProblems {
    // The target is a place the person picked, so the message names it; the system does not say more than denied or not.
    static func notSaved(_ target: URL, denied: Bool) -> Problem {
        if denied {
            return Problem(L10n.t("Not exported"), L10n.t("The system does not let Lazy PDF write to {0}. Pick another folder.",
                                                          ExportModel.leaf(target.deletingLastPathComponent())))
        }
        return Problem(L10n.t("Not exported"),
                       L10n.t("{0} could not be written. Check that the disk has room and that nothing else has the file open.", target.lastPathComponent))
    }

    static func failed(_ error: Error, _ name: String) -> Problem {
        if error is PdfReadException {
            return Problem(L10n.t("Too large to export"), L10n.t("{0} is too big for this format. Export fewer pages or pick another format.", name))
        }
        return Problem(L10n.t("Not exported"), L10n.t("{0} could not be written. Check that the disk has room and that nothing else has the file open.", name))
    }
}
