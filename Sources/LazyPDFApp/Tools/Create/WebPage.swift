import Foundation
import LazyPDFKit

// The web page source of Create. The page is drawn by the system web view of the platform (LazyPDFUI); what is decided
// without a view is here: the page size, the rule that keeps the network out, and which pages name something that will
// not load.

public enum WebPageError: Error, Equatable {
    case tooBig
    case couldNotLoad
    case timedOut
    case tooLong
}

/// Page and margin in points, as the print path of the web view takes them.
public struct WebPageLayout: Equatable {
    public let width: Double
    public let height: Double
    public let margin: Double

    /// A picture-sized page makes no sense for a page of text, so it is A4 here; Automatic is portrait.
    public init(_ setup: PdfPageSetup) {
        var (short, long) = setup.paper == .letter ? (612.0, 792.0) : (595.276, 841.89)
        if setup.orientation == .landscape { swap(&short, &long) }
        width = short
        height = long
        margin = setup.margin
    }

    public var contentWidth: Double { width - 2 * margin }
    public var contentHeight: Double { height - 2 * margin }
}

/// Draws a local HTML file as a paginated PDF with scripts off and the network blocked.
@MainActor
public protocol WebPageRenderer: AnyObject {
    /// The bytes and page count of the PDF. Throws WebPageError.
    func render(_ page: URL, _ layout: WebPageLayout) async throws -> (bytes: [UInt8], pages: Int)
}

public enum WebPageRules {
    /// The largest page file taken; a bigger one is more likely a crafted file than a document.
    public static let mostBytes = 20 << 20

    /// The most pages a page may make before the work is given up.
    public static let mostPages = 2000

    /// Seconds a page may take to load.
    public static let loadSeconds = 30.0

    /// Seconds the Mac print run may take to write the pages.
    public static let printSeconds = 120.0

    /// A WKContentRuleList that refuses every request that is not a local file.
    public static let blockNetwork = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp):"},"action":{"type":"block"}}]"#

    /// True when the page asks for a picture, style, font or other part from the internet, which the rule leaves out of
    /// the PDF. Links to other pages do not count.
    public static func namesRemoteParts(_ html: String) -> Bool {
        if namesRemoteTagPart(Array(html.utf8)) { return true }
        let remote = #"(?:https?:)?//"#
        let patterns = [
            #"url\(\s*["']?\s*"# + remote,
            #"@import\s+(?:url\(\s*)?["']?\s*"# + remote,
        ]
        let range = NSRange(html.startIndex..., in: html)
        return patterns.contains { pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
            return expression.firstMatch(in: html, options: [], range: range) != nil
        }
    }

    private static let loadingTags: Set<String> = ["img", "script", "link", "source", "video", "audio", "iframe", "embed", "object", "input", "image", "use"]
    private static let loadingAttributes: Set<String> = ["src", "href", "poster", "data", "srcset"]
    private static let mostTagBytes = 2000

    /// Reads the bytes once from left to right: a tag that loads something is looked at up to its '>' or 2000 bytes, and
    /// the scan goes on after that, so a file of tag starts costs no more than its length.
    private static func namesRemoteTagPart(_ b: [UInt8]) -> Bool {
        func isWord(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        func lower(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c + 32 : c }
        func word(_ from: Int) -> (text: String, end: Int) {
            var end = from
            while end < b.count && isWord(b[end]) { end += 1 }
            return (String(decoding: b[from..<end].map(lower), as: UTF8.self), end)
        }
        func isSpace(_ c: UInt8) -> Bool { c == 32 || (c >= 9 && c <= 13) }
        func remoteAt(_ from: Int) -> Bool {
            var i = from
            if i + 1 < b.count && b[i] == 0x2F && b[i + 1] == 0x2F { return true }
            for letter in Array("http".utf8) {
                guard i < b.count, lower(b[i]) == letter else { return false }
                i += 1
            }
            if i < b.count && lower(b[i]) == 0x73 { i += 1 }
            return i + 2 < b.count && b[i] == 0x3A && b[i + 1] == 0x2F && b[i + 2] == 0x2F
        }

        var i = 0
        while i < b.count {
            guard b[i] == 0x3C else { i += 1; continue }
            let name = word(i + 1)
            guard name.end > i + 1, loadingTags.contains(name.text) else { i += 1; continue }
            var end = name.end
            while end < b.count && b[end] != 0x3E && end - name.end < mostTagBytes { end += 1 }
            var j = name.end
            while j < end {
                guard isWord(b[j]), !isWord(b[j - 1]) else { j += 1; continue }
                let attribute = word(j)
                j = attribute.end
                guard loadingAttributes.contains(attribute.text) else { continue }
                var k = j
                while k < end && isSpace(b[k]) { k += 1 }
                guard k < b.count, b[k] == 0x3D else { continue }
                k += 1
                while k < end && isSpace(b[k]) { k += 1 }
                if k < b.count && (b[k] == 0x22 || b[k] == 0x27) { k += 1 }
                while k < end && isSpace(b[k]) { k += 1 }
                if remoteAt(k) { return true }
            }
            i = end
        }
        return false
    }
}
