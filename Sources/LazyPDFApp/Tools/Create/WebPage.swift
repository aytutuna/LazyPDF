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

    /// A WKContentRuleList that refuses every request that is not a local file.
    public static let blockNetwork = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp):"},"action":{"type":"block"}}]"#

    /// True when the page asks for a picture, style, font or other part from the internet, which the rule leaves out of
    /// the PDF. Links to other pages do not count.
    public static func namesRemoteParts(_ html: String) -> Bool {
        let remote = #"(?:https?:)?//"#
        let patterns = [
            #"<(?:img|script|link|source|video|audio|iframe|embed|object|input|image|use)\b[^>]{0,2000}?\b(?:src|href|poster|data|srcset)\s*=\s*["']?\s*"# + remote,
            #"url\(\s*["']?\s*"# + remote,
            #"@import\s+(?:url\(\s*)?["']?\s*"# + remote,
        ]
        let range = NSRange(html.startIndex..., in: html)
        return patterns.contains { pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
            return expression.firstMatch(in: html, options: [], range: range) != nil
        }
    }
}
