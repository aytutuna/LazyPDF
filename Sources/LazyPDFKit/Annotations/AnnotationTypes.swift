import Foundation

// Twin of windows/LazyPDF.Core/Annotations/AnnotationTypes.cs: the annotation subtypes of ISO 32000-1 12.5.6 this layer
// tells apart, and the values that describe, style and give an annotation.
//
// What this layer takes from the .NET libraries, and what stands in for it:
// - System.Xml (rich text, XFDF): the Structure layer's XmlTree reads, and XfdfXml.swift writes the way an XmlWriter with
//   Indent does. Rich text nested deeper than 999 levels reads as no text; XmlReader has no such limit.
// - MD5 and the deflate are the engine's own (Digests.swift, Deflate.swift); Guid.NewGuid is UUID.
// - double.TryParse, int.TryParse and ToString("0.##") are InvariantNumbers.swift.
// - The comment list orders and searches text ignoring case, without the machine's culture.
// - InvalidOperationException and ArgumentException are thrown structs of those names.
// - A call that adds an object throws, as PdfDocument.add does.

public enum AnnotationType: String {
    case other = "Other"
    case text = "Text"
    case link = "Link"
    case freeText = "FreeText"
    case line = "Line"
    case square = "Square"
    case circle = "Circle"
    case polygon = "Polygon"
    case polyLine = "PolyLine"
    case highlight = "Highlight"
    case underline = "Underline"
    case squiggly = "Squiggly"
    case strikeOut = "StrikeOut"
    case stamp = "Stamp"
    case caret = "Caret"
    case ink = "Ink"
    case popup = "Popup"
    case fileAttachment = "FileAttachment"
    case redact = "Redact"
    case widget = "Widget"
}

/// The /F bits (ISO 32000-1 12.5.3, table 165).
public struct AnnotationFlags: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let none = AnnotationFlags([])
    public static let invisible = AnnotationFlags(rawValue: 1)
    public static let hidden = AnnotationFlags(rawValue: 2)
    public static let print = AnnotationFlags(rawValue: 4)
    public static let noZoom = AnnotationFlags(rawValue: 8)
    public static let noRotate = AnnotationFlags(rawValue: 16)
    public static let noView = AnnotationFlags(rawValue: 32)
    public static let readOnly = AnnotationFlags(rawValue: 64)
    public static let locked = AnnotationFlags(rawValue: 128)
    public static let toggleNoView = AnnotationFlags(rawValue: 256)
    public static let lockedContents = AnnotationFlags(rawValue: 512)
}

/// Line ending styles of /LE (ISO 32000-1 12.5.6.7, table 176).
public enum LineEnding: String {
    case none = "None"
    case square = "Square"
    case circle = "Circle"
    case diamond = "Diamond"
    case openArrow = "OpenArrow"
    case closedArrow = "ClosedArrow"
    case butt = "Butt"
    case rOpenArrow = "ROpenArrow"
    case rClosedArrow = "RClosedArrow"
    case slash = "Slash"
}

public enum BorderStyle {
    case solid, dashed, beveled, inset, underline
}

/// The states of the review and marked models (ISO 32000-1 12.5.6.3, table 172).
public enum ReviewStatus: String {
    case none = "None"
    case accepted = "Accepted"
    case rejected = "Rejected"
    case cancelled = "Canceled"
    case completed = "Completed"
    case marked = "Marked"
    case unmarked = "Unmarked"
}

/// Width, style and dash of a border, from /BS or the older /Border.
public struct AnnotationBorder: Equatable {
    public var width: Double
    public var style: BorderStyle
    public var dash: [Double]

    public init(_ width: Double, _ style: BorderStyle, _ dash: [Double]) {
        self.width = width
        self.style = style
        self.dash = dash
    }
}

/// A quadrilateral of a text markup, corners in the order Acrobat writes: top left, top right, bottom left, bottom
/// right (the spec's counter-clockwise order is not what files hold).
public struct MarkupQuad: Equatable {
    public let x1, y1, x2, y2, x3, y3, x4, y4: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x3: Double, _ y3: Double, _ x4: Double, _ y4: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        self.x3 = x3
        self.y3 = y3
        self.x4 = x4
        self.y4 = y4
    }

    public static func fromRect(_ r: PdfRect) -> MarkupQuad {
        MarkupQuad(r.left, r.top, r.right, r.top, r.left, r.bottom, r.right, r.bottom)
    }

    public var bounds: PdfRect {
        PdfRect(min(min(x1, x2), min(x3, x4)), min(min(y1, y2), min(y3, y4)),
                max(max(x1, x2), max(x3, x4)), max(max(y1, y2), max(y3, y4)))
    }

    func toNumbers() -> [Double] { [x1, y1, x2, y2, x3, y3, x4, y4] }
}

/// Who wrote an annotation, what it says and when; the caller supplies the date (nothing here reads a clock).
public struct AnnotationInfo {
    public var author: String?
    public var contents: String?
    public var subject: String?
    public var date: DateTimeOffset?
    public var flags: AnnotationFlags

    public init(author: String? = nil, contents: String? = nil, subject: String? = nil, date: DateTimeOffset? = nil,
                flags: AnnotationFlags = .print) {
        self.author = author
        self.contents = contents
        self.subject = subject
        self.date = date
        self.flags = flags
    }
}

/// How an annotation looks. Colours are 1, 3 or 4 numbers (gray, RGB, CMYK) from 0 to 1; a nil `color` takes the colour
/// the kind has by default. `cloud` is the cloud intensity, 1 or 2 (0 for a plain outline).
public struct AnnotationStyle {
    public var color: [Double]?
    public var width: Double
    public var dash: [Double]?
    public var fill: [Double]?
    public var opacity: Double
    public var cloud: Int

    public init(color: [Double]? = nil, width: Double = 1, dash: [Double]? = nil, fill: [Double]? = nil, opacity: Double = 1,
                cloud: Int = 0) {
        self.color = color
        self.width = width
        self.dash = dash
        self.fill = fill
        self.opacity = opacity
        self.cloud = cloud
    }
}

/// The text of a free text annotation: font, colour, alignment and optional XHTML rich text (/RC).
public struct FreeTextStyle {
    public var family: String
    public var size: Double
    public var font: FontStyles
    public var textColor: [Double]?
    public var alignment: Int
    public var richText: String?

    public init(family: String = "Helvetica", size: Double = 12, font: FontStyles = .regular, textColor: [Double]? = nil,
                alignment: Int = 0, richText: String? = nil) {
        self.family = family
        self.size = size
        self.font = font
        self.textColor = textColor
        self.alignment = alignment
        self.richText = richText
    }
}
