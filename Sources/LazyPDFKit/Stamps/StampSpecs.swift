import Foundation

// Twin of windows/LazyPDF.Core/Stamps/StampSpecs.cs: a text or image laid over or under the page, and what a run reports.
// Sizes and offsets are display points of the page as shown (rotation applied, y down); `pages` are 0-based indices, nil
// for every page.

public struct StampColor: Equatable {
    public let r: Double
    public let g: Double
    public let b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let black = StampColor(0, 0, 0)

    public static func gray(_ level: Double) -> StampColor { StampColor(level, level, level) }
}

public enum StampAnchor: Int {
    case topLeft, top, topRight
    case left, center, right
    case bottomLeft, bottom, bottomRight
}

public enum BackgroundFit {
    /// Covers the page, the overflow is clipped.
    case cover
    /// Fits inside the page.
    case contain
    /// Fills the page, the proportions give way.
    case stretch
}

public enum StampKind: Int, CaseIterable {
    case watermark, background, headerFooter, bates

    /// The C# name of the case, which the /LazyPDF marker stores.
    var name: String {
        switch self {
        case .watermark: return "Watermark"
        case .background: return "Background"
        case .headerFooter: return "HeaderFooter"
        case .bates: return "Bates"
        }
    }
}

public struct WatermarkSpec {
    /// The text, lines separated by a line feed. Set this or `image`.
    public var text: String?
    public var image: PdfImage?
    public var fontFamily: String
    public var fontStyle: FontStyles
    public var color: StampColor
    public var opacity: Double
    /// Degrees counter-clockwise as seen, about the centre of the watermark.
    public var rotation: Double
    /// The width of the watermark, unrotated, as a fraction of the page width.
    public var scale: Double
    public var anchor: StampAnchor
    /// Moves it right and down from the anchor.
    public var offsetX: Double
    public var offsetY: Double
    public var behind: Bool
    /// When set, the watermark is optional content under this name, so a viewer can switch it off.
    public var layerName: String?
    public var pages: [Int]?

    public init(text: String? = nil, image: PdfImage? = nil, fontFamily: String = "Helvetica", fontStyle: FontStyles = .bold,
                color: StampColor = .gray(0.5), opacity: Double = 0.3, rotation: Double = 0, scale: Double = 0.6,
                anchor: StampAnchor = .center, offsetX: Double = 0, offsetY: Double = 0, behind: Bool = false,
                layerName: String? = nil, pages: [Int]? = nil) {
        self.text = text
        self.image = image
        self.fontFamily = fontFamily
        self.fontStyle = fontStyle
        self.color = color
        self.opacity = opacity
        self.rotation = rotation
        self.scale = scale
        self.anchor = anchor
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.behind = behind
        self.layerName = layerName
        self.pages = pages
    }
}

/// A colour, an image or both behind the page content.
public struct BackgroundSpec {
    public var color: StampColor?
    public var image: PdfImage?
    public var fit: BackgroundFit
    public var opacity: Double
    public var layerName: String?
    public var pages: [Int]?

    public init(color: StampColor? = nil, image: PdfImage? = nil, fit: BackgroundFit = .cover, opacity: Double = 1,
                layerName: String? = nil, pages: [Int]? = nil) {
        self.color = color
        self.image = image
        self.fit = fit
        self.opacity = opacity
        self.layerName = layerName
        self.pages = pages
    }
}

/// Bates numbers (a running number with a prefix and suffix) for the pages of a batch of documents. The number of the
/// first page stamped is `start`.
public struct BatesSpec {
    public let prefix: String
    public let suffix: String
    public let digits: Int
    public let start: Int

    public init(prefix: String = "", suffix: String = "", digits: Int = 6, start: Int = 1) {
        self.prefix = prefix
        self.suffix = suffix
        self.digits = digits
        self.start = start
    }

    /// Pads to `digits` (1 to 18), as ToString("D18") does; a negative number keeps its sign in front.
    public func format(_ number: Int) -> String {
        let width = Swift.min(Swift.max(digits, 1), 18)
        let magnitude = String(number.magnitude)
        let padded = String(repeating: "0", count: Swift.max(0, width - magnitude.count)) + magnitude
        return prefix + (number < 0 ? "-" : "") + padded + suffix
    }
}

/// The three slots of a header or a footer. Text may hold `{page}`, `{pages}`, `{date}` or `{date:format}`, `{file}` and
/// `{bates}`; anything else, a brace included, stays as typed.
public struct HeaderFooterBand {
    public let left: String
    public let center: String
    public let right: String

    public init(_ left: String = "", _ center: String = "", _ right: String = "") {
        self.left = left
        self.center = center
        self.right = right
    }
}

public struct HeaderFooterSpec {
    public var header: HeaderFooterBand
    public var footer: HeaderFooterBand
    /// Used on even pages (the 2nd, 4th...) in place of the header; nil means the same as `header`.
    public var evenHeader: HeaderFooterBand?
    public var evenFooter: HeaderFooterBand?
    public var fontFamily: String
    public var fontStyle: FontStyles
    public var fontSize: Double
    public var color: StampColor
    public var marginX: Double
    public var marginTop: Double
    public var marginBottom: Double
    /// The number `{page}` shows on the first page of the document.
    public var startNumber: Int
    /// The date `{date}` shows; Core has no clock, the app passes it in.
    public var date: DateTimeOffset
    public var dateFormat: String
    public var culture: CultureInfo
    /// What `{file}` shows.
    public var fileName: String
    /// What `{bates}` shows; the stamped pages are numbered in document order.
    public var bates: BatesSpec?
    public var pages: [Int]?

    public init(header: HeaderFooterBand = HeaderFooterBand(), footer: HeaderFooterBand = HeaderFooterBand(),
                evenHeader: HeaderFooterBand? = nil, evenFooter: HeaderFooterBand? = nil, fontFamily: String = "Helvetica",
                fontStyle: FontStyles = .regular, fontSize: Double = 10, color: StampColor = .black, marginX: Double = 36,
                marginTop: Double = 36, marginBottom: Double = 36, startNumber: Int = 1,
                date: DateTimeOffset = DateTimeOffset(1, 1, 1, 0, 0, 0), dateFormat: String = "yyyy-MM-dd",
                culture: CultureInfo = .invariantCulture, fileName: String = "", bates: BatesSpec? = nil, pages: [Int]? = nil) {
        self.header = header
        self.footer = footer
        self.evenHeader = evenHeader
        self.evenFooter = evenFooter
        self.fontFamily = fontFamily
        self.fontStyle = fontStyle
        self.fontSize = fontSize
        self.color = color
        self.marginX = marginX
        self.marginTop = marginTop
        self.marginBottom = marginBottom
        self.startNumber = startNumber
        self.date = date
        self.dateFormat = dateFormat
        self.culture = culture
        self.fileName = fileName
        self.bates = bates
        self.pages = pages
    }
}

/// What one stamp run did. `nextBates` is where the next document of a batch starts, 0 without Bates numbers.
public struct StampRun {
    public let id: Int
    public let pages: Int
    public let nextBates: Int
    public let missing: [Int]
}

/// A run found in the file. `pages` are the 0-based pages carrying it.
public struct StampInfo {
    public let id: Int
    public let kind: StampKind
    public let label: String?
    public let behind: Bool
    public let pages: [Int]
}
