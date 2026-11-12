import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionTypes.cs: the marks, the options and what an application returns.
//
// The redaction layer decides three things the C# gets from .NET. XmlDocument is `RedactionXml.swift` (the XMP packets are
// read without namespaces, and the Structure layer's reader refuses the undeclared prefixes producers leave). ZipArchive and
// GZipStream are `RedactionArchive.swift`. A text that must match "ordinally" (HashSet<string> with StringComparer.Ordinal,
// OrdinalIgnoreCase) is compared by UTF-16 units, never by Swift's own `==`, which treats canonical equivalents as equal and
// would merge two needles that differ in the bytes they search for.

/// An area to remove from one page, in user space. `fill` is the colour it is covered with (gray, RGB or CMYK, 0 to 1; black
/// when nil) and `overlayText` the text drawn on it, such as a reason code.
public struct RedactionMark {
    public var page: Int
    public var quads: [TextQuad]
    public var fill: [Double]?
    public var overlayText: String?

    public init(_ page: Int, _ quads: [TextQuad], _ fill: [Double]? = nil, _ overlayText: String? = nil) {
        self.page = page
        self.quads = quads
        self.fill = fill
        self.overlayText = overlayText
    }

    public static func fromRect(_ page: Int, _ rect: PdfRect, _ fill: [Double]? = nil, _ overlayText: String? = nil) -> RedactionMark {
        RedactionMark(page, [TextQuad(rect.left, rect.bottom, rect.right, rect.bottom, rect.right, rect.top, rect.left, rect.top)], fill, overlayText)
    }

    public static func fromMatch(_ match: SearchMatch, _ fill: [Double]? = nil, _ overlayText: String? = nil) -> RedactionMark {
        RedactionMark(match.page, match.quads, fill, overlayText)
    }
}

/// What `PdfRedactor.apply` does besides removing.
public struct RedactionOptions {
    /// Colour for marks that give none; black when nil.
    public var fill: [Double]?

    /// Text drawn on marks that give none.
    public var overlayText: String?

    /// Repeat the overlay text across the mark instead of drawing it once.
    public var repeatOverlay = false

    public var fontFamily = "Helvetica"

    /// The report lists the removed text. Off by default, so a report can be kept or shared.
    public var includeText = false

    /// Replace the removed text where /Info, the XMP packet and bookmark titles hold it. They are reported either way.
    public var changeMetadata = false

    /// Draws the pages that cannot be redacted as text (see `PdfRedactor.apply`). It draws the document handed to the
    /// redactor. Without one, such a page makes the call throw.
    public var renderer: PageRenderer?

    /// Every page with a mark becomes a picture, as a page that is not understood does; without a renderer the call throws.
    public var flattenMarkedPages = false

    /// The resolution a page is drawn at when it becomes a picture, at most 1200.
    public var flattenDpi = 200.0

    /// Write the output with the input's encryption. A file opened with a password needs it again to open.
    public var keepEncryption = true

    public init() {}
}

/// The output of an application: always a full rewrite with no earlier revision in it.
public struct RedactionResult {
    public let bytes: [UInt8]
    public let report: RedactionReport
    public let verification: RedactionVerification

    public init(_ bytes: [UInt8], _ report: RedactionReport, _ verification: RedactionVerification) {
        self.bytes = bytes
        self.report = report
        self.verification = verification
    }
}

/// What the check of the output found. Problems say where, never what.
public struct RedactionVerification {
    public let problems: [String]

    public init(_ problems: [String]) {
        self.problems = problems
    }

    public var isClean: Bool { problems.isEmpty }
}

/// A place outside the page content that held removed text.
public struct RedactionFinding {
    public let `where`: String
    public let changed: Bool

    public init(_ place: String, _ changed: Bool) {
        self.where = place
        self.changed = changed
    }
}

/// What was taken out of one page.
public struct PageRedaction {
    public let page: Int
    public let glyphs: Int
    public let images: Int
    public let paths: Int
    public let annotations: Int
    public let fields: Int

    /// The annotations and fields whose text was rewritten.
    public internal(set) var values: Int

    /// The pictures (already in `images`) that could not be cut and were removed whole.
    public let wholeImages: Int

    public init(_ page: Int, _ glyphs: Int, _ images: Int, _ paths: Int, _ annotations: Int, _ fields: Int, _ values: Int = 0, wholeImages: Int = 0) {
        self.values = values
        self.wholeImages = wholeImages
        self.page = page
        self.glyphs = glyphs
        self.images = images
        self.paths = paths
        self.annotations = annotations
        self.fields = fields
    }

    public var isEmpty: Bool { glyphs + images + paths + annotations + fields + values == 0 }
}

public struct RedactionReport: CustomStringConvertible {
    public let pages: [PageRedaction]
    public let findings: [RedactionFinding]
    public let signaturesRemoved: Int
    public let text: [String]

    /// The pages (from 0) that were turned into pictures; their text is no longer selectable.
    public var flattened: [Int] = []

    public init(_ pages: [PageRedaction], _ findings: [RedactionFinding], _ signaturesRemoved: Int, _ text: [String]) {
        self.pages = pages
        self.findings = findings
        self.signaturesRemoved = signaturesRemoved
        self.text = text
    }

    public var glyphs: Int { pages.reduce(0) { $0 + $1.glyphs } }
    public var images: Int { pages.reduce(0) { $0 + $1.images } }
    public var paths: Int { pages.reduce(0) { $0 + $1.paths } }
    public var annotations: Int { pages.reduce(0) { $0 + $1.annotations } }
    public var fields: Int { pages.reduce(0) { $0 + $1.fields } }

    /// The report in plain words, one line a page.
    public var description: String {
        var lines = pages.filter { !$0.isEmpty }.map { RedactionText.line($0) }
        if lines.isEmpty && flattened.isEmpty { lines.append(RedactionText.nothingFound) }
        lines.append(contentsOf: pages.filter { $0.wholeImages > 0 }.map { RedactionText.wholePicture($0.page, $0.wholeImages) })
        lines.append(contentsOf: flattened.map { RedactionText.flattened($0) })
        lines.append(contentsOf: findings.map { $0.changed ? RedactionText.metadataChanged($0.where) : RedactionText.metadataHolds($0.where) })
        if signaturesRemoved > 0 { lines.append(RedactionText.signaturesGone(signaturesRemoved)) }
        lines.append(contentsOf: text.map { RedactionText.removed($0) })
        return lines.joined(separator: "\n")
    }
}
