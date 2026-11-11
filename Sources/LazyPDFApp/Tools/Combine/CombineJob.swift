import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Combine/CombineJob.cs: the parts of Combine that do not need a window: how a file is cut, and
// what the parts are called.

public enum SplitBy: Int {
    case count, size, bookmarks
}

public enum CombineJob {
    public static let megabyteBytes = 1024 * 1024

    /// Pages per part, or megabytes per part, as typed; nil when it is not a number that makes sense for `by`.
    public static func amount(_ by: SplitBy, _ text: String, locale: Locale = .current) -> Double? {
        if by == .bookmarks { return 0 }
        guard let amount = PageEdits.number(text, locale: locale) else { return nil }
        switch by {
        case .count: return amount >= 1 && amount == amount.rounded(.down) && amount <= Double(Int32.max) ? amount : nil
        default: return amount >= 0.01 && amount <= 100_000 ? amount : nil
        }
    }

    public static func split(_ source: PdfDocument, _ by: SplitBy, _ amount: Double, _ token: CancelToken? = nil) throws -> [PdfDocument] {
        try token?.throwIfCancelled()
        switch by {
        case .count: return try PageAssembly.splitEvery(source, Int(amount))
        case .size: return try PageAssembly.splitBySize(source, Int(amount * Double(megabyteBytes)))
        case .bookmarks: return try PageAssembly.splitAt(source, bookmarkStarts(source))
        }
    }

    public static func partsOver(_ parts: [[UInt8]], _ limit: Int) -> Int {
        parts.filter { $0.count > limit }.count
    }

    /// The pages the top-level bookmarks point at, in the order of the outline.
    public static func bookmarkStarts(_ document: PdfDocument) -> [Int] {
        Outline.read(document).items
            .map { item in item.destination?.pageIndex ?? (item.action as? GoToAction)?.destination.pageIndex ?? -1 }
            .filter { $0 >= 0 && $0 < document.pages.count }
    }

    /// How many parts a split at the bookmarks makes: bookmarks on the same page, or on the first, add none.
    public static func bookmarkParts(_ document: PdfDocument) -> Int {
        Set(bookmarkStarts(document).filter { $0 != 0 }).count + 1
    }

    public static func partName(_ stem: String, _ part: Int, _ parts: Int) -> String {
        let width = max(String(parts).count, 1)
        let number = String(part + 1)
        return "\(stem) \(String(repeating: "0", count: max(width - number.count, 0)))\(number).pdf"
    }

    /// `name` in `folder`, or with " (2)", " (3)" and so on when the folder has it already.
    public static func uniquePath(_ folder: URL, _ name: String) -> URL {
        var path = folder.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: path.path) {
            path = folder.appendingPathComponent("\(stem) (\(n)).\(ext)")
            n += 1
        }
        return path
    }
}
