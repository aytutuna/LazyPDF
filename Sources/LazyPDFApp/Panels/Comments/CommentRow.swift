import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Panels/Comments/CommentRow.cs and CommentSummary.cs.

/// One comment in the list. `group` is the heading it sits under.
public struct CommentRow: Identifiable {
    public let id: Int
    public let comment: PdfComment
    public let group: String
    public let location: String

    init(id: Int, comment: PdfComment, page: String, group: String) {
        self.id = id
        self.comment = comment
        self.group = group
        location = Self.details(comment, page)
    }

    public var title: String {
        let kind = AnnotationText.kindName(comment.type)
        return (comment.author ?? "").isEmpty ? kind : kind + " · " + (comment.author ?? "")
    }

    public var text: String { comment.text ?? "" }

    public var summary: String { title + ", " + location + (text.isEmpty ? "" : ", " + text) }

    private static func details(_ comment: PdfComment, _ page: String) -> String {
        var text = page
        if comment.status != .none { text += " · " + AnnotationText.statusName(comment.status) }
        let answers = comment.replies.filter { $0.state == nil }.count
        if answers > 0 { text += " · " + L10n.plural(answers, one: "{0} reply", other: "{0} replies") }
        return text
    }
}

/// The comments of a file as plain text, to hand to someone who has no PDF reader open.
public enum CommentSummary {
    public static func text(_ title: String, _ comments: [PdfComment], _ pageLabel: (Int) -> String) -> String {
        var lines = [title, L10n.plural(comments.count, one: "{0} comment", other: "{0} comments")]
        for comment in comments {
            lines.append("")
            var head = [L10n.t("Page {0}", pageLabel(comment.pageIndex)), AnnotationText.kindName(comment.type)]
            if let author = comment.author, !author.isEmpty { head.append(author) }
            if let date = comment.date { head.append(String(format: "%04d-%02d-%02d", date.year, date.month, date.day)) }
            lines.append(head.joined(separator: ", "))
            if let text = comment.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append("  " + oneLine(text)) }
            if comment.status != .none { lines.append("  " + L10n.t("Status: {0}", AnnotationText.statusName(comment.status))) }
            for reply in comment.replies where reply.state == nil {
                guard let contents = reply.contents, !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                lines.append("  " + L10n.t("Reply from {0}: {1}", reply.title ?? "", oneLine(contents)))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func oneLine(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).joined(separator: " ")
    }
}
