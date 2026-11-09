import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/EditContent/PageEdits.cs: the edits of the panel, each a call to the engine's page editor.
// Objects are named by their id on the page so that a call after an undo reads them again instead of holding stale ones. The
// page editor commits on the session itself, so a change that went through is shown by `DocumentTab.refresh`.

/// What an edit came to: why the engine refused it, or what the person should know about one that went through.
struct EditOutcome: Equatable {
    var done: Bool
    var problem: String?
    var note: String?

    init(done: Bool, problem: String? = nil, note: String? = nil) {
        self.done = done
        self.problem = problem
        self.note = note
    }
}

/// The file a replace-all made on its copy, and the file it started from.
struct Replacement {
    let start: [UInt8]
    let report: ReplaceReport
    let file: [UInt8]
}

@MainActor
final class PageEdits {
    private let tab: DocumentTab
    private let fonts: FontSource?
    private let codec: ImageCodec?
    private let certificate: X509Certificate?
    private var editors: [Int: PageEditor] = [:]

    init(_ tab: DocumentTab, fonts: FontSource?, codec: ImageCodec?, certificate: X509Certificate? = nil) {
        self.tab = tab
        self.fonts = fonts
        self.codec = codec
        self.certificate = certificate
    }

    func editor(_ page: Int) throws -> PageEditor {
        if let known = editors[page] { return known }
        let made = try PageEditor(tab.session, page, fonts, codec)
        editors[page] = made
        return made
    }

    func objects(_ page: Int) -> [PageObject] {
        (try? editor(page).objects) ?? []
    }

    func object(_ page: Int, _ id: Int) -> PageObject? {
        let all = objects(page)
        return id >= 0 && id < all.count ? all[id] : nil
    }

    func objects(_ page: Int, _ ids: [Int]) -> [PageObject] {
        ids.compactMap { object(page, $0) }
    }

    // MARK: Text

    func replaceLine(_ page: Int, _ line: TextObjectLine, _ text: String) throws -> EditOutcome {
        result(try editor(page).replaceText(line.range, text))
    }

    func replaceParagraph(_ page: Int, _ block: Int, _ text: String) throws -> EditOutcome {
        guard let o = object(page, block) as? TextObject else { return stale() }
        return result(try editor(page).replaceParagraph(o, text))
    }

    // The engine restyles the ranges it is given and sets a changed font again from their text, so a range over several
    // lines would come back as one; each line goes on its own.
    func style(_ page: Int, _ block: Int, _ change: TextStyleChange) throws -> EditOutcome {
        guard let o = object(page, block) as? TextObject else { return stale() }
        var change = change
        if let size = change.size { change.size = size * unscaled(page, o) }
        return result(try editor(page).setTextStyle(o.lines.isEmpty ? [o.range] : o.lines.map(\.range), change))
    }

    // The size shown is in page units; Tf takes it before Tm and cm scale it.
    private func unscaled(_ page: Int, _ o: TextObject) -> Double {
        guard let look = try? editor(page).look(of: o), look.userSize > 0 else { return 1 }
        return look.fontSize / look.userSize
    }

    func align(_ page: Int, _ block: Int, _ alignment: LazyPDFKit.TextAlignment) throws -> EditOutcome {
        guard let o = object(page, block) as? TextObject else { return stale() }
        return result(try editor(page).setAlignment(o, alignment))
    }

    func space(_ page: Int, _ block: Int, _ spacing: Double) throws -> EditOutcome {
        guard let o = object(page, block) as? TextObject else { return stale() }
        return result(try editor(page).setLineSpacing(o, spacing))
    }

    func addTextBox(_ page: Int, _ box: PdfRect, _ text: String, _ style: TextBoxStyle) throws -> EditOutcome {
        result(try editor(page).addTextBox(box, text, style))
    }

    func addImage(_ page: Int, _ box: PdfRect, _ file: [UInt8]) throws -> EditOutcome {
        result(try editor(page).addImage(box, file))
    }

    // MARK: Objects

    func move(_ page: Int, _ ids: [Int], _ dx: Double, _ dy: Double) throws -> EditOutcome {
        result(try editor(page).move(objects(page, ids), dx, dy))
    }

    func resize(_ page: Int, _ ids: [Int], _ bounds: PdfRect) throws -> EditOutcome {
        result(try editor(page).resize(objects(page, ids), bounds))
    }

    func rotate(_ page: Int, _ ids: [Int], _ degrees: Double) throws -> EditOutcome {
        result(try editor(page).rotate(objects(page, ids), degrees))
    }

    // The engine mirrors in page space; on a page turned a quarter, by /Rotate or by the viewer, that is the other way round
    // on the screen.
    func flip(_ page: Int, _ ids: [Int], acrossScreen: Bool, viewRotation: Int) throws -> EditOutcome {
        let turned = PageGeometry(tab.document.pages[page]).rotation + viewRotation
        return result(try editor(page).flip(objects(page, ids), acrossScreen != (turned / 90 % 2 == 1)))
    }

    func delete(_ page: Int, _ ids: [Int]) throws -> EditOutcome {
        result(try editor(page).delete(objects(page, ids)))
    }

    func opacity(_ page: Int, _ ids: [Int], _ opacity: Double) throws -> EditOutcome {
        result(try editor(page).setOpacity(objects(page, ids), opacity))
    }

    func order(_ page: Int, _ id: Int, _ move: OrderMove) throws -> EditOutcome {
        guard let o = object(page, id) else { return stale() }
        return result(try editor(page).order(o, move))
    }

    // The engine sets colours round the paint the shape already has, so a fill on a line-only shape would change nothing.
    func pathStyle(_ page: Int, _ ids: [Int], fill: RgbColor?, stroke: RgbColor?, width: Double?) throws -> EditOutcome {
        let paths = objects(page, ids).compactMap { $0 as? PathObject }
            .filter { (fill == nil || $0.fill) && ((stroke == nil && width == nil) || $0.stroke) }
        if paths.isEmpty {
            if fill != nil { return EditOutcome(done: false, problem: L10n.t("This shape has no fill. Use the line colour instead.")) }
            return EditOutcome(done: false, problem: L10n.t("This shape has no line. Use the fill colour instead."))
        }
        return result(try editor(page).setPathStyle(paths, fill: fill, stroke: stroke, lineWidth: width))
    }

    func crop(_ page: Int, _ id: Int, _ area: PdfRect) throws -> EditOutcome {
        guard let o = object(page, id) as? ImageObject else { return stale() }
        return result(try editor(page).crop(o, area))
    }

    func replaceImage(_ page: Int, _ id: Int, _ file: [UInt8]) throws -> EditOutcome {
        guard let o = object(page, id) as? ImageObject else { return stale() }
        return result(try editor(page).replaceImage(o, file))
    }

    func extract(_ page: Int, _ id: Int) throws -> ExtractedImage? {
        guard let o = object(page, id) as? ImageObject else { return nil }
        return try editor(page).extractImage(o)
    }

    // MARK: Replace all

    /// Replaces on a copy of the file, which holds nothing of the document being shown, so it can run off the main actor and
    /// be cancelled without leaving half an edit behind. `adopt` brings the result in.
    func replaceAll(_ start: [UInt8], _ query: String, _ replacement: String, _ options: TextSearchOptions,
                    _ token: CancelToken) async throws -> Replacement {
        try token.throwIfCancelled()
        let password = tab.password
        let certificate = certificate
        let fonts = fonts
        let job = Task.detached {
            try Self.replace(start, query, replacement, options, password, certificate, fonts)
        }
        let watch = Task.detached {
            while !token.isCancelled && !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
            if token.isCancelled { job.cancel() }
        }
        defer { watch.cancel() }
        return try await job.value
    }

    private nonisolated static func replace(_ start: [UInt8], _ query: String, _ replacement: String, _ options: TextSearchOptions,
                                            _ password: String?, _ certificate: X509Certificate?, _ fonts: FontSource?) throws -> Replacement {
        let scratch = try scratchSession(start, password, certificate)
        let report = try TextReplacer.replaceAll(scratch, query, replacement, options, fonts: fonts, label: L10n.t("Replace text"))
        return Replacement(start: start, report: report, file: report.replaced > 0 ? scratch.current : [])
    }

    private nonisolated static func scratchSession(_ bytes: [UInt8], _ password: String?, _ certificate: X509Certificate?) throws -> PdfEditSession {
        #if canImport(Security)
        if let certificate, let held = PdfCertificate(certificate) { return try PdfEditSession.open(bytes, certificate: held) }
        #endif
        return try PdfEditSession.open(bytes, password: password)
    }

    /// Makes the replaced copy the document as one undo step, unless the document moved on while it was made.
    func adopt(_ made: Replacement) throws -> EditOutcome {
        if made.report.replaced == 0 { return report(made.report) }
        guard tab.session.current == made.start else {
            return EditOutcome(done: false, problem: L10n.t("The file changed meanwhile. Replace again."))
        }
        _ = try tab.session.commitBytes(L10n.t("Replace text"), made.file)
        tab.refresh()
        return report(made.report)
    }

    private func report(_ report: ReplaceReport) -> EditOutcome {
        let why = report.failed.first?.reason
        if report.replaced == 0 { return EditOutcome(done: false, problem: why ?? L10n.t("Nothing found to replace.")) }
        let done = L10n.plural(report.replaced, one: "Replaced {0} time.", other: "Replaced {0} times.")
        if report.failed.isEmpty { return EditOutcome(done: true, note: done) }
        let left = L10n.plural(report.failed.count, one: "{0} match was left as it was: {1}",
                               other: "{0} matches were left as they were: {1}", why ?? "")
        return EditOutcome(done: true, note: done + " " + left)
    }

    // MARK: Links

    func links(_ page: Int) -> [PdfLink] {
        PdfLinks.read(tab.document, tab.document.pages[page])
    }

    /// Adds a link over `area`, or points `old` somewhere else when it is given.
    func setLink(_ page: Int, _ area: PdfRect, _ target: PdfAction, _ old: PdfLink?) throws -> EditOutcome {
        let document = tab.document
        let p = document.pages[page]
        let label: String
        if let old {
            guard let annot = annotation(document, p, old) else { return stale() }
            annot.remove("Dest")
            annot["A"] = try PdfActions.toObject(document, target)
            label = L10n.t("Change link")
        } else {
            try PdfLinks.add(document, p, area, target)
            label = L10n.t("Add link")
        }
        return try tab.commit(label) ? EditOutcome(done: true) : EditOutcome(done: false, problem: EditingText.nothingChanged)
    }

    func removeLink(_ page: Int, _ link: PdfLink) throws -> EditOutcome {
        let document = tab.document
        let p = document.pages[page]
        var removed = false
        if let reference = link.reference {
            removed = PdfLinks.remove(document, p, reference)
        } else if let annot = annotation(document, p, link), let annots = document.array(p.dictionary, "Annots") {
            let before = annots.items.count
            annots.items.removeAll { $0 === annot }
            removed = annots.items.count < before
        }
        if !removed { return EditOutcome(done: false, problem: EditingText.nothingChanged) }
        return try tab.commit(L10n.t("Remove link")) ? EditOutcome(done: true) : EditOutcome(done: false, problem: EditingText.nothingChanged)
    }

    // The dictionary of a link, edited where it is so that its border, colour and place in the list stay; a link given
    // directly in /Annots has no reference and is found by its rectangle.
    private func annotation(_ document: PdfDocument, _ page: PdfPage, _ link: PdfLink) -> PdfDictionary? {
        if let reference = link.reference { return document.resolve(reference) as? PdfDictionary }
        guard let annots = document.array(page.dictionary, "Annots") else { return nil }
        return annots.items.compactMap { $0 as? PdfDictionary }
            .first { document.name($0, "Subtype") == "Link" && document.rect($0, "Rect") == link.rect }
    }

    /// A web address or a page number, as typed; nil when it is neither.
    static func target(toPage: Bool, _ typed: String, _ pageCount: Int) -> PdfAction? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if toPage {
            guard let n = Int(text), n >= 1, n <= pageCount else { return nil }
            return GoToAction(PdfDestination(n - 1))
        }
        if text.isEmpty || text.contains(" ") { return nil }
        let hasScheme = text.range(of: #"^(\w+://|mailto:|tel:)"#, options: [.regularExpression, .caseInsensitive]) != nil
        return UriAction(hasScheme ? text : "https://" + text)
    }

    // MARK: Results

    private func result(_ result: TextEditResult) -> EditOutcome {
        if !result.done { return EditOutcome(done: false, problem: result.problem) }
        tab.refresh()
        var note: String?
        if result.overlaps {
            note = L10n.t("The new text runs into other text.")
        } else if result.grew {
            note = L10n.t("The paragraph grew. Text below stayed put.")
        } else if !result.substitutions.isEmpty {
            var names: [String] = []
            for substitution in result.substitutions where !names.contains(substitution.replacement) { names.append(substitution.replacement) }
            note = L10n.t("Some letters use {0}.", names.joined(separator: ", "))
        }
        return EditOutcome(done: true, note: note)
    }

    private func result(_ result: ObjectEditResult) -> EditOutcome {
        let skipped = result.skipped.first?.reason
        if !result.done { return EditOutcome(done: false, problem: skipped ?? EditingText.nothingChanged) }
        tab.refresh()
        guard let skipped else { return EditOutcome(done: true) }
        return EditOutcome(done: true, note: L10n.t("Some objects were left as they were: {0}", skipped))
    }

    private func stale() -> EditOutcome {
        EditOutcome(done: false, problem: EditingText.staleObject)
    }
}
