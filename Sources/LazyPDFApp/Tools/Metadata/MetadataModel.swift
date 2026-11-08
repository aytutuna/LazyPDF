import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Metadata/MetadataPanel.xaml.cs: the properties stored in the file, and how it opens and
// prints in other viewers. The form is the model's own state; the file is read again whenever it changes, and what is typed
// stays unless the panel is shown for another document.

@MainActor
@Observable
public final class MetadataModel: ToolPanelModel {
    public var title = ""
    public var author = ""
    public var subject = ""
    public var keywords = ""

    /// The day the file was made, at the start of the person's own day; nil for none.
    public var created: Date?

    /// The changed date moves to now when the properties are saved.
    public var touchModified = true

    public var modeIndex = 0
    public var layoutIndex = 0
    public var language = ""
    public var displayDocTitle = false
    public var hideToolbar = false
    public var hideMenubar = false
    public var hideWindowUI = false
    public var fitWindow = false
    public var centerWindow = false
    public var rightToLeft = false
    public var printScalingNone = false
    public var sidesIndex = 0

    /// 0 for the printer's own, then 2 to 5 copies.
    public var copiesIndex = 0

    public private(set) var modifiedText = ""
    public private(set) var makerText = ""

    private var metadata = DocumentMetadata(nil, nil, nil, nil, nil, nil, nil, nil, OrderedStrings())
    private var view = ViewerSettings(nil, false, .useNone, .singlePage, false, false, false, false, false, false, false, nil, nil)
    var tab: DocumentTab?
    var host: ToolHost?
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var editedTab: UUID?

    public init() {}

    public var action: ToolAction? {
        ToolAction(L10n.t("Save properties"), symbol: "checkmark", canRun: { [self] in isChanged }, run: { [self] in save() })
    }

    /// The form differs from the file.
    public var isChanged: Bool {
        let (typedMetadata, typedView) = readForm()
        return typedMetadata != metadata || typedView != view
    }

    /// A signed file asks before it is changed, so leaving a field does not ask again.
    public var asksFirst: Bool {
        guard let tab else { return false }
        return tab.document.isSigned && ChangeGate.refusal(tab.document) == nil
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        let keep = isChanged && editedTab == tab.id
        self.tab = tab
        self.host = host
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.load(keepEdits: self?.isChanged ?? false) })
        load(keepEdits: keep)
    }

    public func detach() {
        watch?.stop()
        watch = nil
        editedTab = isChanged ? tab?.id : nil
        tab = nil
        host = nil
    }

    // Typed properties go into the file on Save, on leaving a field and on close, as one undo step each time. A signed file
    // asks first, so there the caller is told to wait.
    public func handIn() -> Bool {
        guard isChanged, tab != nil else { return true }
        let asks = asksFirst
        save()
        return !asks
    }

    // Typed properties are not in the file yet, so a change made elsewhere reads the file again but keeps them.
    private func load(keepEdits: Bool) {
        guard let tab else { return }
        metadata = DocumentMetadata.read(tab.document)
        view = ViewerSettings.read(tab.document)
        if let modified = metadata.modified {
            modifiedText = L10n.t("Changed {0}", PanelDates.date(modified).formatted(date: .numeric, time: .shortened))
        } else {
            modifiedText = L10n.t("No changed date.")
        }
        makerText = [metadata.creator, metadata.producer].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        if !keepEdits { showForm() }
    }

    private func showForm() {
        title = metadata.title ?? ""
        author = metadata.author ?? ""
        subject = metadata.subject ?? ""
        keywords = metadata.keywords ?? ""
        created = metadata.created.map { Self.calendar.startOfDay(for: PanelDates.date($0)) }
        modeIndex = MetadataEdit.modes.firstIndex(of: view.pageMode) ?? 0
        layoutIndex = MetadataEdit.layouts.firstIndex(of: view.pageLayout) ?? 0
        language = view.language ?? ""
        displayDocTitle = view.displayDocTitle
        hideToolbar = view.hideToolbar
        hideMenubar = view.hideMenubar
        hideWindowUI = view.hideWindowUI
        fitWindow = view.fitWindow
        centerWindow = view.centerWindow
        rightToLeft = view.rightToLeft
        printScalingNone = view.printScalingNone
        sidesIndex = MetadataEdit.sides.firstIndex(of: view.duplex) ?? 0
        copiesIndex = view.numCopies.map { $0 - 1 } ?? 0
    }

    private func readForm() -> (DocumentMetadata, ViewerSettings) {
        func text(_ value: String) -> String? { value.isEmpty ? nil : value }
        var typed = metadata
        typed.title = text(title)
        typed.author = text(author)
        typed.subject = text(subject)
        typed.keywords = text(keywords)
        typed.created = createdValue()
        var shown = view
        shown.pageMode = MetadataEdit.modes[min(max(modeIndex, 0), MetadataEdit.modes.count - 1)]
        shown.pageLayout = MetadataEdit.layouts[min(max(layoutIndex, 0), MetadataEdit.layouts.count - 1)]
        shown.language = text(language)
        shown.displayDocTitle = displayDocTitle
        shown.hideToolbar = hideToolbar
        shown.hideMenubar = hideMenubar
        shown.hideWindowUI = hideWindowUI
        shown.fitWindow = fitWindow
        shown.centerWindow = centerWindow
        shown.rightToLeft = rightToLeft
        shown.printScalingNone = printScalingNone
        shown.duplex = MetadataEdit.sides[min(max(sidesIndex, 0), MetadataEdit.sides.count - 1)]
        shown.numCopies = copiesIndex > 0 ? copiesIndex + 1 : nil
        return (typed, shown)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    // A date outside this range may not fit the local offset, so the form does not write a typed one.
    private static func inRange(_ day: Date) -> Bool {
        let parts = calendar.dateComponents([.year], from: day)
        return (1900...2099).contains(parts.year ?? 0)
    }

    // The day picked is kept as the file's own date when it is the day the file has, or outside the range the form allows.
    private func createdValue() -> DateTimeOffset? {
        guard let picked = created else { return nil }
        let calendar = Self.calendar
        let day = calendar.startOfDay(for: picked)
        let known = metadata.created.map { calendar.startOfDay(for: PanelDates.date($0)) }
        if day == known || !Self.inRange(day) { return metadata.created }
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return DateTimeOffset(valid: parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1, 0, 0, 0,
                              offsetMinutes: calendar.timeZone.secondsFromGMT(for: day) / 60) ?? metadata.created
    }

    private func save() {
        guard let tab, let host else { return }
        let (typedMetadata, typedView) = readForm()
        let touch = touchModified
        ChangeGate.run(tab, host, L10n.t("Save properties")) { [self] in
            try MetadataEdit.write(tab.document, typedMetadata, typedView, touchModified: touch, now: PanelDates.now())
            if try tab.commit(L10n.t("Properties")) {
                host.setStatus(L10n.t("Properties changed."))
                load(keepEdits: true)
            }
        }
    }
}
