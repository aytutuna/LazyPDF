import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Panels/Comments/CommentsSidePanel.xaml.cs. Answering a comment and the summary file are in
// CommentsModel+Review.swift.

/// The comments under one heading of the list.
public struct CommentGroup: Identifiable {
    public let name: String
    public let rows: [CommentRow]

    public var id: String { name }
}

/// Every comment and mark of the file, grouped and filtered; choosing one shows it on its page, and the one picked can be
/// answered.
@MainActor
@Observable
public final class CommentsModel: ToolPanelModel {
    public private(set) var groups: [CommentGroup] = []
    public private(set) var grouping = CommentOrder.page
    public private(set) var statusFilter: ReviewStatus?
    public private(set) var query = ""
    public private(set) var selected: Int?
    public private(set) var allowed = true
    public private(set) var hasComments = false

    /// The name of the person answering; the system's user name until the view gives a better one.
    @ObservationIgnored public var author = NSFullUserName()

    var tab: DocumentTab?
    var viewer: DocumentViewer?
    var host: ToolHost?
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var typing: Task<Void, Never>?
    @ObservationIgnored private var all: [PdfComment] = []

    public init() {}

    public var action: ToolAction? { nil }

    public var rows: [CommentRow] { groups.flatMap { $0.rows } }

    public var isEmpty: Bool { groups.isEmpty }

    public var emptyText: String { hasComments ? L10n.t("No comment matches.") : L10n.t("This file has no comments.") }

    public var selectedRow: CommentRow? { rows.first { $0.id == selected } }

    /// The replies to the picked comment, as the list under it shows them.
    public var replies: [String] {
        guard let row = selectedRow else { return [] }
        return row.comment.replies.filter { $0.state == nil && !($0.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { reply in
                let contents = reply.contents ?? ""
                return (reply.title ?? "").isEmpty ? contents : (reply.title ?? "") + ": " + contents
            }
    }

    /// An annotation written straight into the page's list has no object number to answer.
    public var canAnswer: Bool { allowed && selectedRow?.comment.annotation.reference != nil }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.viewer = viewer
        self.host = host
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.load() })
        load()
    }

    public func detach() {
        typing?.cancel()
        typing = nil
        watch?.stop()
        watch = nil
        groups = []
        all = []
        selected = nil
        tab = nil
        viewer = nil
        host = nil
    }

    public func setGrouping(_ order: CommentOrder) {
        guard order != grouping else { return }
        grouping = order
        if tab != nil { load() }
    }

    public func setStatusFilter(_ status: ReviewStatus?) {
        statusFilter = status
        if tab != nil { build() }
    }

    /// Filters by the words typed once typing has paused.
    public func setQuery(_ text: String) {
        query = text
        typing?.cancel()
        typing = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            self?.build()
        }
    }

    public func select(_ id: Int?) {
        selected = id
    }

    /// Shows the comment on its page.
    public func go(_ row: CommentRow) {
        guard let viewer, row.comment.pageIndex >= 0 else { return }
        let page = row.comment.pageIndex
        let box = viewer.geometry(page).toDisplay(row.comment.annotation.rect)
        viewer.goToPage(page)
        viewer.reveal(page, ViewRect(box.x, box.y, box.width, box.height))
    }

    // The file is read once per change; filtering and typing in the filter work on what was read.
    private func load() {
        guard let tab else { return }
        allowed = Self.canComment(tab.document)
        all = PdfComments.list(tab.document, nil, grouping)
        hasComments = !all.isEmpty
        build()
    }

    func visible() -> [PdfComment] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.filter { comment in
            (statusFilter == nil || comment.status == statusFilter) && (words.isEmpty || Self.mentions(comment, words))
        }
    }

    private func build() {
        guard let viewer else { return }
        let picked = selectedRow?.comment.annotation.reference?.number
        var order: [String] = []
        var byGroup: [String: [CommentRow]] = [:]
        for (i, comment) in visible().enumerated() {
            let row = CommentRow(id: comment.annotation.reference?.number ?? -(i + 1), comment: comment,
                                 page: L10n.t("Page {0}", viewer.pageLabel(comment.pageIndex)), group: groupName(comment, viewer))
            if byGroup[row.group] == nil { order.append(row.group) }
            byGroup[row.group, default: []].append(row)
        }
        groups = order.map { CommentGroup(name: $0, rows: byGroup[$0] ?? []) }
        selected = picked.flatMap { number in rows.first { $0.comment.annotation.reference?.number == number }?.id }
    }

    private func groupName(_ comment: PdfComment, _ viewer: DocumentViewer) -> String {
        switch grouping {
        case .author: return (comment.author ?? "").isEmpty ? L10n.t("No author") : comment.author ?? ""
        case .type: return AnnotationText.kindName(comment.type)
        default: return L10n.t("Page {0}", viewer.pageLabel(comment.pageIndex))
        }
    }

    private static func mentions(_ comment: PdfComment, _ words: String) -> Bool {
        has(comment.text, words) || has(comment.author, words) || comment.replies.contains { has($0.contents, words) || has($0.title, words) }
    }

    private static func has(_ text: String?, _ words: String) -> Bool {
        text?.localizedCaseInsensitiveContains(words) == true
    }

    // Marks may be added when the permissions allow annotating and a certification, if there is one, allows it too.
    static func canComment(_ document: PdfDocument) -> Bool {
        PdfAnnotations.canAnnotate(document) && (!document.isCertified || certifiedLevel(document) >= 3)
    }

    // The /DocMDP permission of the certification (ISO 32000-1 12.8.2.2); 2 when the file does not say.
    private static func certifiedLevel(_ document: PdfDocument) -> Int {
        var level = 2
        let signature = document.resolve(document.dict(document.catalog, "Perms")?["DocMDP"]) as? PdfDictionary
        for item in document.array(signature, "Reference")?.items ?? [] {
            if let reference = document.resolve(item) as? PdfDictionary, document.name(reference, "TransformMethod") == "DocMDP",
               let parameters = document.dict(reference, "TransformParams"), let p = document.integer(parameters, "P") {
                level = p
            }
        }
        return level
    }
}
