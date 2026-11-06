import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Documents/ITab.cs.

/// An entry of the tab strip: the Home tab or an open document.
@MainActor
public protocol StripTab: AnyObject {
    var title: String { get }

    /// What a screen reader says for the tab: the title, and that it has unsaved changes.
    var automationName: String { get }

    /// An SF Symbol name.
    var symbol: String { get }

    var isDirty: Bool { get }

    var canClose: Bool { get }
}

/// The first tab: recent files and the jobs people come for. It stays open.
@MainActor
public final class HomeTab: StripTab {
    public static let shared = HomeTab()

    private init() {}

    public var title: String { L10n.t("Home") }

    public var automationName: String { title }

    public var symbol: String { "house" }

    public var isDirty: Bool { false }

    public var canClose: Bool { false }
}
