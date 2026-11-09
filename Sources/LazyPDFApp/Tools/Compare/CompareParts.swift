import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Compare/Parts.cs.

/// The kinds of difference the filters switch on and off.
public struct CompareParts: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let text = CompareParts(rawValue: 1)
    public static let pictures = CompareParts(rawValue: 2)
    public static let annotations = CompareParts(rawValue: 4)
    public static let forms = CompareParts(rawValue: 8)
    public static let pages = CompareParts(rawValue: 16)
    public static let details = CompareParts(rawValue: 32)
    public static let all = CompareParts(rawValue: 63)
}

public enum ChangeParts {
    // The engine words a form field change as "Form field {0}"; cutting at a marker finds it in any language.
    private static var formWords: [String] { CompareText.formField("\u{1}").components(separatedBy: "\u{1}") }

    public static func of(_ change: CompareChange) -> CompareParts {
        switch change.area {
        case .text, .format: return .text
        case .image: return .pictures
        case .annotation: return .annotations
        case .page: return .pages
        default:
            let words = formWords
            if let detail = change.detail, detail.hasPrefix(words[0]), detail.hasSuffix(words[1]) { return .forms }
            return .details
        }
    }

    /// The result with only the changes of `parts`, and the counts of those.
    public static func only(_ result: ComparisonResult, _ parts: CompareParts) -> ComparisonResult {
        if parts == .all { return result }
        let kept = result.changes.filter { parts.contains(of($0)) }
        func kind(_ k: ChangeKind) -> Int { kept.filter { $0.kind == k }.count }
        func area(_ a: ChangeArea) -> Int { kept.filter { $0.area == a }.count }
        let old = result.summary
        let summary = ComparisonSummary(kind(.added), kind(.removed), kind(.changed), kind(.moved), area(.text), area(.format),
                                        area(.image), area(.annotation), area(.page), area(.document), old.wordsAdded, old.wordsRemoved)
        // The report lists removed pages from the pages, not from the changes.
        let pages = parts.contains(.pages) ? result.pages : result.pages.filter { !$0.isRemoved }
        return ComparisonResult(pages, kept, summary, result.oldPageCount, result.newPageCount)
    }
}
