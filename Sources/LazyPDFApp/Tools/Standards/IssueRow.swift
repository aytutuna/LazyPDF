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
    private var next = 0

    private init(_ first: PdfAIssue, count: Int, pages: [Int]) {
        self.first = first
        self.count = count
        self.pages = pages
    }

    public var message: String { first.message }

    public var clause: String { L10n.t("ISO 19005 clause {0}", first.clause) }

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
        let prefix = String(PdfAText.pageName(0).dropLast())
        var order: [Key] = []
        var groups: [Key: [PdfAIssue]] = [:]
        for issue in issues {
            let key = Key(clause: Array(issue.clause.utf8), message: Array(issue.message.utf8))
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(issue)
        }
        return order.map { key in
            let members = groups[key] ?? []
            let pages = Set(members.map { pageOf($0.where, prefix) }.filter { $0 >= 0 }).sorted()
            return IssueRow(members[0], count: members.count, pages: pages)
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
