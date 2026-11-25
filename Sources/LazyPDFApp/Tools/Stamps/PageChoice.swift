import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Stamps/PageChoice.cs: which pages a stamp goes on, as the form states it, and the way back
// from a run's pages to the form.

public enum PageSet: Int {
    case all, odd, even, typed
}

public enum PageChoice {
    /// The 0-based pages, nil for every page, or what is wrong with the typed range.
    public static func resolve(_ set: PageSet, _ typed: String, _ count: Int) -> (pages: [Int]?, error: String?) {
        switch set {
        case .all:
            return (nil, nil)
        case .odd:
            return ((0..<count).filter { $0 % 2 == 0 }, nil)
        case .even:
            return ((0..<count).filter { $0 % 2 == 1 }, nil)
        case .typed:
            let parsed = PageRange.parse(typed, count)
            return parsed.isSuccess ? (parsed.pages, nil) : ([], parsed.error?.message)
        }
    }

    /// The pages a stamp lands on, in order, as the engine takes them.
    public static func targets(_ pages: [Int]?, _ count: Int) -> [Int] {
        guard let pages else { return Array(0..<count) }
        return Array(Set(pages.filter { $0 >= 0 && $0 < count })).sorted()
    }

    /// "1-3, 5" for 0-based pages 0, 1, 2, 4.
    public static func describe(_ pages: [Int]) -> String {
        let sorted = Array(Set(pages)).sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var end = i
            while end + 1 < sorted.count && sorted[end + 1] == sorted[end] + 1 { end += 1 }
            parts.append(end > i ? "\(sorted[i] + 1)-\(sorted[end] + 1)" : "\(sorted[i] + 1)")
            i = end + 1
        }
        return parts.joined(separator: ", ")
    }
}
