import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Forms/FormEdits.cs: changes to the form of a tab, each one undoable step. The engine's
// errors pass through to the caller.

/// Filling in fields one after another is one undo step. Another tool, an undo or a
/// redo starts a new one: the tab's revision moves with each of those, and the engine refuses a merge after a save.
@MainActor
public final class FillMerge {
    private weak var tab: DocumentTab?
    private var revision = 0

    public init() {}

    public func apply<T>(_ tab: DocumentTab, _ fonts: FontSource, _ label: String, _ edit: (PdfForm) throws -> T) throws -> T {
        let merge = tab === self.tab && tab.revision == revision
        let before = tab.revision
        let result = try FormEdits.apply(tab, fonts, label, merge: merge, edit)
        if tab.revision != before { (self.tab, revision) = (tab, tab.revision) }
        return result
    }

    public func forget() {
        tab = nil
    }
}

@MainActor
public enum FormEdits {
    public static func read(_ tab: DocumentTab, _ fonts: FontSource) -> PdfForm {
        PdfForm.read(tab.document, fonts)
    }

    // A refused edit may have changed the document before it threw; those changes go, so they do not ride into the next step.
    public static func apply<T>(_ tab: DocumentTab, _ fonts: FontSource, _ label: String, merge: Bool = false, _ edit: (PdfForm) throws -> T) throws -> T {
        do {
            let result = try edit(read(tab, fonts))
            try tab.commit(label, mergeWithPrevious: merge)
            return result
        } catch {
            try? tab.session.discard()
            throw error
        }
    }

    // The commit tells the window, so it stays on the main actor; only the edit leaves it. The edit works on the document of
    // the session, so when an undo swapped that document meanwhile, the work is lost and says so.
    public static func applyAsync<T>(_ tab: DocumentTab, _ fonts: FontSource, _ label: String, token: CancelToken? = nil,
                                     _ edit: @escaping @Sendable (PdfForm) throws -> T) async throws -> T {
        let document = tab.document
        do {
            let form = read(tab, fonts)
            let result: T
            if let token {
                result = try await ToolDocuments.run(token) { try edit(form) }
            } else {
                result = try await Task.detached { try edit(form) }.value
            }
            if document !== tab.document { throw InvalidOperationException(L10n.t("The file changed meanwhile. Run it again.")) }
            if token?.isCancelled == true { throw CancellationError() }
            try tab.commit(label)
            return result
        } catch {
            if document === tab.document { try? tab.session.discard() }
            throw error
        }
    }

    /// The proposals of the detector for the whole file, read from a copy so the work can leave the main actor. Scanned pages
    /// are drawn and read from their pixels.
    public static func detect(_ tab: DocumentTab, certificate: X509Certificate? = nil) throws -> [FieldProposal] {
        try detect(tab.session.current, password: tab.password, certificate: certificate, renderer: tab.renderer)
    }

    nonisolated public static func detect(_ bytes: [UInt8], password: String?, certificate: X509Certificate?,
                                          renderer: PageRenderer) throws -> [FieldProposal] {
        let copy = try ToolDocuments.open(bytes, password: password, certificate: certificate)
        return try FieldDetector.detect(copy, renderer)
    }

    /// As `detect(_:password:certificate:renderer:)` on its own thread, and ended at the next page once `token` is cancelled.
    public static func detect(_ bytes: [UInt8], password: String?, certificate: X509Certificate?, renderer: PageRenderer,
                              token: CancelToken) async throws -> [FieldProposal] {
        if token.isCancelled { throw CancellationError() }
        let job = Task.detached { try detect(bytes, password: password, certificate: certificate, renderer: renderer) }
        let watch = Task.detached {
            while !token.isCancelled && !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
            job.cancel()
        }
        defer { watch.cancel() }
        return try await job.value
    }

    public static func newName(_ form: PdfForm, _ kind: FieldKind) -> String {
        let stem: String
        switch kind {
        case .text: stem = "Text"
        case .checkBox: stem = "Check"
        case .radio: stem = "Radio"
        case .pushButton: stem = "Button"
        case .comboBox: stem = "Combo"
        case .listBox: stem = "List"
        case .signature: stem = "Signature"
        }
        var n = 1
        while form.find(stem + String(n)) != nil { n += 1 }
        return stem + String(n)
    }

    /// Points, for a field drawn with a click instead of a drag.
    public static func defaultSize(_ kind: FieldKind) -> (width: Double, height: Double) {
        switch kind {
        case .checkBox, .radio: return (14, 14)
        case .listBox: return (150, 60)
        case .pushButton: return (100, 24)
        case .signature: return (180, 40)
        default: return (150, 20)
        }
    }

    /// Adds a field of `kind`. A radio button joins the group `group` names, or the selected radio group when that is empty,
    /// and starts a group of that name when there is none yet. Returns the field's name and the index of the new widget.
    public static func add(_ form: PdfForm, _ kind: FieldKind, _ page: Int, _ rect: PdfRect, _ selected: FormField?,
                           group: String = "") throws -> (name: String, widget: Int) {
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        let named: String? = kind == .radio && !trimmed.isEmpty ? trimmed : nil
        if kind == .radio, let joined = named == nil ? selected : form.find(named!), joined.kind == .radio {
            _ = try form.addWidget(joined, page, rect)
            return (joined.name, (form.find(joined.name)?.widgets.count ?? 1) - 1)
        }
        var spec = FieldSpec(kind, named ?? newName(form, kind), page, rect)
        spec.caption = kind == .pushButton ? L10n.t("Button") : nil
        spec.rotation = pageRotation(form, page)
        return (try form.addField(spec).name, 0)
    }

    /// Adds the fields the detector found; a name another field already holds, or sits under, gets a number. A proposal for a
    /// page the file no longer has is refused.
    public static func addFound(_ form: PdfForm, _ found: [FieldProposal]) throws -> Int {
        var added = 0
        for proposal in found {
            var spec = proposal.toSpec()
            guard spec.pageIndex >= 0 && spec.pageIndex < form.document.pages.count else { throw ArgumentException("pageIndex") }
            let stem = spec.name.replacingOccurrences(of: ".", with: "_")
            var name = taken(form, spec.name) ? stem : spec.name
            var n = 2
            while taken(form, name) {
                name = stem + "_" + String(n)
                n += 1
            }
            spec.name = name
            spec.rotation = pageRotation(form, spec.pageIndex)
            _ = try form.addField(spec)
            added += 1
        }
        return added
    }

    // A widget is drawn along the page as the person sees it, so a turned page turns the widget the same way.
    private static func pageRotation(_ form: PdfForm, _ page: Int) -> Int {
        (form.document.pages[page].rotate % 360 + 360) % 360
    }

    private static func taken(_ form: PdfForm, _ name: String) -> Bool {
        form.fields.contains { $0.name == name || $0.name.hasPrefix(name + ".") || name.hasPrefix($0.name + ".") }
    }

    /// Whether the file's permissions let the fields themselves change, which filling does not need.
    public static func canModify(_ document: PdfDocument) -> Bool {
        guard let security = document.security else { return true }
        return security.openedAsOwner || security.permissions.contains(.modify)
    }

    public static func caption(of form: PdfForm, _ field: FormField) -> String {
        for widget in field.widgets {
            guard let mk = form.document.resolve(widget.dictionary["MK"]) as? PdfDictionary,
                  let text = PdfText.read(form.document, mk["CA"]) else { continue }
            return text
        }
        return ""
    }

    public static func setCaption(_ form: PdfForm, _ field: FormField, _ caption: String) throws {
        for widget in field.widgets {
            let mk: PdfDictionary
            if let known = form.document.resolve(widget.dictionary["MK"]) as? PdfDictionary {
                mk = known
            } else {
                mk = PdfDictionary()
                widget.dictionary["MK"] = mk
            }
            mk["CA"] = PdfText.toObject(caption)
        }
        try form.regenerate([field])
    }

    /// The address a link or a submit goes to: web addresses and mailto links as typed, a bare e-mail address with mailto:
    /// before it, anything else with https://. Nil when it is not an address.
    public static func address(of text: String) -> String? {
        var typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty || typed.contains(" ") { return nil }
        if !typed.contains(":") { typed = (typed.contains("@") && !typed.contains("/") ? "mailto:" : "https://") + typed }
        guard let colon = typed.firstIndex(of: ":") else { return nil }
        let scheme = typed[..<colon].lowercased()
        if scheme == "mailto" { return typed.count > 7 ? typed : nil }
        guard scheme == "http" || scheme == "https" else { return nil }
        var rest = typed[typed.index(after: colon)...]
        guard rest.hasPrefix("//") else { return nil }
        rest = rest.dropFirst(2)
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        // https://name@host reads as a web address with a user name, which is rarely what was meant.
        if authority.isEmpty || authority.contains("@") { return nil }
        return typed
    }

    /// Whether two text colours (1, 3 or 4 numbers) are the same on screen.
    public static func sameColour(_ a: [Double], _ b: [Double]) -> Bool {
        zip(rgb(a), rgb(b)).allSatisfy { abs($0 - $1) < 0.02 }
    }

    private static func rgb(_ c: [Double]) -> [Double] {
        switch c.count {
        case 1: return [c[0], c[0], c[0]]
        case 4: return [(1 - c[0]) * (1 - c[3]), (1 - c[1]) * (1 - c[3]), (1 - c[2]) * (1 - c[3])]
        case 3: return c
        default: return [0, 0, 0]
        }
    }

    public static func parseOptions(_ text: String) -> [FieldOption] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { line in
                guard let equals = line.firstIndex(of: "="), equals != line.startIndex else { return FieldOption(line) }
                return FieldOption(line[..<equals].trimmingCharacters(in: .whitespaces),
                                   line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            }
    }

    public static func formatOptions(_ options: [FieldOption]) -> String {
        options.map { $0.export == $0.display ? $0.export : "\($0.export)=\($0.display)" }.joined(separator: "\r\n")
    }

    public static func problem(of error: Error) -> Problem {
        if let read = error as? PdfReadException {
            if read.problem == .unsupported { return Problem(L10n.t("Form not supported"), FormText.dynamicXfa) }
            return Problem(L10n.t("Form cannot be read"), L10n.t("Lazy PDF cannot change this form. Try an earlier copy of the file."))
        }
        if error is ArgumentException {
            return Problem(L10n.t("Field not changed"), L10n.t("Check the name and the size of the field, then try again."))
        }
        let text = (error as? InvalidOperationException)?.message ?? String(describing: error)
        return Problem(L10n.t("Field not changed"), text)
    }
}
