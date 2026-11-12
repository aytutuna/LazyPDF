import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Stamps/StampsPanel.xaml.cs and its partial files: watermarks, backgrounds, headers, footers
// and Bates numbers. The form describes one stamp, the pages show it as it is typed, and the action writes it; the runs already
// in the file are listed to update or remove. The draft is read in StampsModel+Form.swift, a run goes back into the form in
// +Runs.swift and the pending stamp is drawn on the pages in +Preview.swift.

@MainActor
@Observable
public final class StampsModel: ToolPanelModel {
    public internal(set) var form = StampForm()

    /// What is wrong with the form before the engine could draw it; nil when nothing is.
    public private(set) var problem: String?
    public internal(set) var runs: [RunRow] = []

    /// The run picked in the list, whose settings the form shows; nil when the form describes a new stamp.
    public internal(set) var selected: RunRow?

    /// The name of the picture the stamp uses; nil for none.
    public private(set) var pictureName: String?

    /// A stamp or a removal is being written and nothing else may be changed.
    public private(set) var isBusy = false

    // A run read back from the file is not changed until the form is.
    var touched = false

    public let families: [String]

    @ObservationIgnored var tab: DocumentTab?
    @ObservationIgnored var host: ToolHost?
    @ObservationIgnored var viewer: DocumentViewer?
    @ObservationIgnored var watch: ObservationWatch?
    @ObservationIgnored var viewWatch: ObservationWatch?
    @ObservationIgnored var written: [WrittenRun: StampDraft] = [:]
    @ObservationIgnored var previewOn = true
    @ObservationIgnored var previewPages = Set<Int>()
    @ObservationIgnored var picture: [UInt8]?
    @ObservationIgnored var pictureImage: PdfRgbaImage?

    struct WrittenRun: Hashable {
        let tab: UUID
        let run: Int
    }

    public init() {
        let installed = Set(InstalledFonts.families)
        families = ["Helvetica", "Times", "Courier"] + ["Arial", "Georgia", "Verdana", "Avenir", "Menlo"].filter(installed.contains)
    }

    /// The colours of text, and of backgrounds, by name.
    var colors: [(name: String, color: StampColor)] {
        [
            (L10n.t("Gray"), .gray(0.5)),
            (L10n.t("Black"), .black),
            (L10n.t("Red"), StampColor(0.8, 0.1, 0.1)),
            (L10n.t("Orange"), StampColor(0.95, 0.5, 0.1)),
            (L10n.t("Green"), StampColor(0.1, 0.55, 0.25)),
            (L10n.t("Blue"), StampColor(0.1, 0.35, 0.8)),
        ]
    }

    var backColors: [(name: String, color: StampColor?)] {
        [
            (L10n.t("None"), nil),
            (L10n.t("White"), StampColor(1, 1, 1)),
            (L10n.t("Light gray"), .gray(0.9)),
            (L10n.t("Cream"), StampColor(1, 0.97, 0.85)),
            (L10n.t("Light blue"), StampColor(0.85, 0.92, 1)),
        ]
    }

    public var colorNames: [String] { colors.map(\.name) }
    public var backColorNames: [String] { backColors.map(\.name) }

    public var tokensHint: String { L10n.t("{page}, {pages}, {date} and {file} fill in by themselves.") }

    public var action: ToolAction? {
        let text = selected != nil ? L10n.t("Update stamp") : addText(form.mode)
        return ToolAction(text, symbol: "seal", hint: nil, canRun: { [self] in problem == nil && !isBusy && tab != nil && (selected == nil || touched) },
                          run: { [self] in await run() })
    }

    private func addText(_ mode: StampMode) -> String {
        switch mode {
        case .watermark: return L10n.t("Add watermark")
        case .background: return L10n.t("Add background")
        case .headerFooter: return L10n.t("Add header and footer")
        case .bates: return L10n.t("Add Bates numbers")
        }
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.host = host
        self.viewer = viewer
        previewOn = true
        touched = false
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in
            self?.buildRuns()
            self?.refresh()
        })
        viewWatch = ObservationWatch(track: { _ = viewer.viewRevision; _ = viewer.visiblePages }, changed: { [weak self] in self?.updatePreview() })
        buildRuns()
        refresh()
    }

    public func detach() {
        watch?.stop()
        viewWatch?.stop()
        watch = nil
        viewWatch = nil
        clearPreviews()
        runs = []
        selected = nil
        tab = nil
        host = nil
        viewer = nil
    }

    // MARK: The form

    /// A change the person made to the form: the stamp is previewed again and the action can run.
    public func edit(_ change: (inout StampForm) -> Void) {
        change(&form)
        touched = true
        previewOn = true
        refresh()
    }

    /// Each kind starts from what suits it; what the person changes afterwards stays.
    public func setMode(_ mode: StampMode) {
        edit { form in
            form.mode = mode
            form.bold = mode == .watermark
            form.color = mode == .headerFooter || mode == .bates ? 1 : 0
            form.opacity = mode == .background ? 100 : 30
        }
    }

    // Sets fields without the form taking it for an edit.
    func quiet(_ change: (inout StampForm) -> Void) {
        change(&form)
        refresh()
    }

    func refresh() {
        guard tab != nil else { return }
        problem = readDraft().problem
        updatePreview()
    }

    // MARK: The picture

    public func pickPicture() async {
        guard let host else { return }
        guard let chosen = await host.filePicker.pickFiles([.picture], multiple: false).first else { return }
        defer { chosen.access?.stop() }
        guard let bytes = try? [UInt8](Data(contentsOf: chosen.url)), let frame = host.imageCodec.flatMap({ PdfImageWriter.decodeUpright(bytes, $0) }) else {
            host.showProblem(Problem(L10n.t("Picture cannot be read"), L10n.t("Pick a PNG, JPEG or another common picture.")))
            return
        }
        picture = bytes
        pictureImage = frame
        pictureName = chosen.url.lastPathComponent
        edit { _ in }
    }

    public func removePicture() {
        setPicture(nil)
        edit { _ in }
    }

    func setPicture(_ bytes: [UInt8]?) {
        picture = bytes
        pictureImage = bytes.flatMap { bytes in host?.imageCodec.flatMap { PdfImageWriter.decodeUpright(bytes, $0) } }
        pictureName = bytes == nil ? nil : L10n.t("Picture")
    }

    // MARK: Writing

    private func run() async {
        guard let tab, let host, let draft = readDraft().draft else { return }
        let replace = selected?.id
        let name = replace == nil ? draft.addText : L10n.t("Update stamp")
        await ChangeGate.runAsync(tab, host, name) { [self] in
            try await working { try await stamp(tab, host, draft, replace) }
        }
    }

    func working(_ run: () async throws -> Void) async throws {
        isBusy = true
        defer { isBusy = false }
        try await run()
    }

    // The job runs on a copy of the file made from the session's bytes, off the main actor, so the document being shown is not
    // touched until the result is committed. Nil when the work was cancelled, or Undo or another tool changed the file meanwhile;
    // `file` is nil when the copy came out unchanged. The caller commits it with `commitCopy` before it yields.
    func editDocument<T>(_ tab: DocumentTab, _ host: ToolHost, _ busy: String, _ label: String,
                         _ work: @escaping @Sendable (PdfDocument) throws -> T) async throws -> (value: T, file: [UInt8]?)? {
        let start = tab.session.current
        let password = tab.password
        let certificate = tab.certificate.flatMap { host.verifyCertificate($0) }
        var made: (value: T, file: [UInt8]?)?
        try await host.runBusy(busy) { token in
            let value = try await ToolDocuments.run(token) { () throws -> (value: T, file: [UInt8]?) in
                try token.throwIfCancelled()
                let scratch = try ContentEdits.scratchSession(start, password, certificate)
                let value = try work(scratch.document)
                try token.throwIfCancelled()
                return (value, try scratch.commit(label) ? scratch.current : nil)
            }
            if !token.isCancelled { made = value }
        }
        guard let made else {
            host.setStatus(L10n.t("Canceled."))
            return nil
        }
        return tab.session.current == start ? made : nil
    }

    // False when the copy changed nothing.
    func commitCopy(_ tab: DocumentTab, _ label: String, _ file: [UInt8]?) throws -> Bool {
        guard let file else { return false }
        _ = try tab.session.commitBytes(label, file)
        tab.refresh()
        return true
    }

    private func stamp(_ tab: DocumentTab, _ host: ToolHost, _ draft: StampDraft, _ replace: Int?) async throws {
        let fonts = host.fontSource, codec = host.imageCodec
        let label = replace == nil ? draft.addText : L10n.t("Update stamp")
        let made: (value: StampRun, file: [UInt8]?)?
        do {
            made = try await editDocument(tab, host, L10n.t("Stamping pages"), label) { document in
                try draft.apply(document, fonts: fonts, codec: codec, replace: replace)
            }
        } catch is InvalidOperationException {
            host.showProblem(Problem(L10n.t("No font for this text"), StampsText.noFont))
            return
        } catch is InvalidDataException {
            host.showProblem(Problem(L10n.t("Picture cannot be read"), L10n.t("Pick a PNG, JPEG or another common picture.")))
            return
        }
        guard let made else { return }
        let run = made.value

        // The page now carries the stamp; the preview would only draw it twice.
        previewOn = false
        clearPreviews()
        if try !commitCopy(tab, label, made.file) {
            host.setStatus(L10n.t("Nothing was stamped."))
            return
        }
        written[WrittenRun(tab: tab.id, run: run.id)] = draft
        touched = false
        buildRuns()
        if replace == nil, let bates = draft.headerFooter?.bates {
            quiet { $0.start = String(run.nextBates) }
            host.setStatus(L10n.t("Next number is {0}.", bates.format(run.nextBates)))
        } else {
            refresh()
            host.setStatus(L10n.plural(run.pages, one: "Stamped {0} page.", other: "Stamped {0} pages."))
        }
        if !run.missing.isEmpty {
            host.showNotice(L10n.t("Some characters are missing"), L10n.t("The font cannot draw all of the text. Pick another font and update the stamp."), nil)
        }
    }
}
