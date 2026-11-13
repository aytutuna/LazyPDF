import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Standards/IssueRow.cs: one rule the file breaks, with every place it breaks it in; the places
// that are pages can be visited in turn.

@Observable
public final class IssueRow: Identifiable {
    public let id = UUID()
    private let pages: [Int]
    private let first: PdfAIssue
    private let count: Int
    private let clauseText: String?
    private var next = 0

    private init(_ first: PdfAIssue, count: Int, pages: [Int], clause: String?) {
        self.first = first
        self.count = count
        self.pages = pages
        clauseText = clause
    }

    public var message: String { first.message }

    public var clause: String { clauseText ?? L10n.t("ISO 19005 clause {0}", first.clause) }

    /// The first place, and how many more there are.
    public var place: String { count > 1 ? L10n.t("{0}, and {1} more", first.where, count - 1) : first.where }

    public var summary: String { message + ". " + place + ". " + clause }

    public var hasPlaces: Bool { !pages.isEmpty }

    public var placeText: String { pages.isEmpty ? "" : L10n.t("Go to page {0}", pages[next % pages.count] + 1) }

    public func nextPage() -> Int {
        let page = pages[next % pages.count]
        next += 1
        return page
    }

    /// The issues with the same rule and sentence made into one row each, in the order they were found.
    public static func group(_ issues: [PdfAIssue]) -> [IssueRow] {
        group(issues.map { ($0, nil) })
    }

    /// The same for the PDF/UA check, whose rows name the Matterhorn condition and the clause of ISO 14289-1.
    public static func group(_ issues: [PdfUaIssue]) -> [IssueRow] {
        group(issues.map {
            (PdfAIssue($0.condition, $0.where, $0.message), L10n.t("Matterhorn {0}, ISO 14289-1 clause {1}", $0.condition, $0.clause))
        })
    }

    private static func group(_ issues: [(issue: PdfAIssue, clause: String?)]) -> [IssueRow] {
        let prefix = String(PdfAText.pageName(0).dropLast())
        var order: [Key] = []
        var groups: [Key: [(issue: PdfAIssue, clause: String?)]] = [:]
        for entry in issues {
            let key = Key(clause: Array(entry.issue.clause.utf8), message: Array(entry.issue.message.utf8))
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        return order.map { key in
            let members = groups[key] ?? []
            let pages = Set(members.map { pageOf($0.issue.where, prefix) }.filter { $0 >= 0 }).sorted()
            return IssueRow(members[0].issue, count: members.count, pages: pages, clause: members[0].clause)
        }
    }

    // Ordinal, as the C# tuple compares the two strings.
    private struct Key: Hashable {
        let clause: [UInt8]
        let message: [UInt8]
    }

    // "Page 3" and "Page 3, annotation 2" are the places that name a page; the word comes from the same text the validator used.
    private static func pageOf(_ place: String, _ prefix: String) -> Int {
        guard place.hasPrefix(prefix) else { return -1 }
        let digits = place.dropFirst(prefix.count).prefix { $0.isASCII && $0.isNumber }
        guard let page = Int(digits), page > 0 else { return -1 }
        return page - 1
    }
}
