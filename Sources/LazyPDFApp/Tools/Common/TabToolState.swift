import Foundation

// The Swift counterpart of the static ConditionalWeakTables of the Windows tools: what a tool keeps for a document while
// another tab or tool is shown. The tables belong to a store the shells share, so a tab that moves to another window finds
// its marks, lists and drafts there.

/// A value kept for each tab, by the tab's id. A row goes when its tab is closed.
@MainActor
final class TabTable<Value> {
    private struct Row {
        weak var tab: DocumentTab?
        var value: Value
    }

    private var rows: [UUID: Row] = [:]

    nonisolated init() {}

    var count: Int { rows.count }

    subscript(_ tab: DocumentTab) -> Value? {
        get { rows[tab.id]?.value }
        set { rows[tab.id] = newValue.map { Row(tab: tab, value: $0) } }
    }

    /// Drops the rows of tabs that are gone, telling `gone` what each one held.
    func prune(_ gone: (Value) -> Void = { _ in }) {
        for (id, row) in rows where row.tab == nil || row.tab?.isDisposed == true {
            gone(row.value)
            rows[id] = nil
        }
    }

    func take(_ tab: DocumentTab) -> Value? {
        rows.removeValue(forKey: tab.id)?.value
    }
}

/// The per-tab tables of every tool. One store per app; a shell with one window makes its own.
@MainActor
public final class TabToolState {
    let redact = TabTable<RedactModel.State>()
    let combine = TabTable<[CombineEntry]>()
    let compare = TabTable<HeldComparison>()
    let measureLists = TabTable<PendingList>()
    let measureScales = TabTable<MeasureScale>()
    let figures = TabTable<AccessibilityModel.Kept>()
    let words = TabTable<OcrModel.KeptWord>()

    nonisolated public init() {}
}
