import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Accessibility/CheckRow.cs.

public enum RowAction {
    case none, setTabOrder, addTags, describeFigures
}

/// Title and language carry a box of their own so they can be changed whether the check passed or not.
public enum RowEditor: Hashable {
    case none, title, language
}

/// One line of the check: the result in plain words, what can be done about it, and where the trouble is.
@Observable
public final class CheckRow: Identifiable {
    private let item: AccessibilityItem
    private let start: String
    private let pages: [Int]
    private let canAddTags: Bool
    private var next = 0

    /// What the title or language box holds.
    public var value: String

    public init(_ item: AccessibilityItem, value: String = "", canAddTags: Bool = true) {
        self.item = item
        self.value = value
        start = value
        self.canAddTags = canAddTags
        var seen = Set<Int>()
        pages = item.where.map(\.pageIndex).filter { $0 >= 0 && seen.insert($0).inserted }
    }

    public var id: AccessibilityRule { item.rule }

    public var name: String { item.name }

    public var message: String { item.message }

    /// The box holds something other than what it started with.
    public var edited: Bool { Self.trimmed(value) != Self.trimmed(start) }

    public var level: AccessibilityStatus { item.status }

    public var status: String {
        switch item.status {
        case .passed: return L10n.t("Passed")
        case .failed: return L10n.t("Failed")
        default: return L10n.t("Needs a person")
        }
    }

    /// An SF Symbol for the status.
    public var symbol: String {
        switch item.status {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    public var summary: String { name + ", " + status + ". " + message }

    public var editor: RowEditor {
        switch item.rule {
        case .title: return .title
        case .language: return .language
        default: return .none
        }
    }

    public var hasEditor: Bool { editor != .none }

    public var editorName: String { editor == .title ? L10n.t("Title") : L10n.t("Language") }

    public var saveText: String { editor == .title ? L10n.t("Save title") : L10n.t("Save language") }

    public var action: RowAction {
        if item.status != .failed { return .none }
        if item.fix == .setTabOrder { return .setTabOrder }
        switch item.rule {
        case .tagged: return canAddTags ? .addTags : .none
        case .figureAlt: return .describeFigures
        default: return .none
        }
    }

    public var hasAction: Bool { action != .none }

    public var actionText: String {
        switch action {
        case .setTabOrder: return L10n.t("Set the tab order")
        case .addTags: return L10n.t("Add tags")
        case .describeFigures: return L10n.t("Describe figures")
        case .none: return ""
        }
    }

    public var hasPlaces: Bool { !pages.isEmpty }

    public var placeText: String { pages.isEmpty ? "" : L10n.t("Go to page {0}", pages[next % pages.count] + 1) }

    /// The page the place button goes to; the next press goes to the following place.
    public func nextPage() -> Int {
        let page = pages[next % pages.count]
        next += 1
        return page
    }

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
