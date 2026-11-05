import Foundation

// Twin of windows/LazyPDF.Core/Annotations/PdfAnnotation.cs: an annotation as read (ISO 32000-1 12.5). The values are a
// snapshot; `dictionary` is the live dictionary, so keys this layer does not know stay where they are when it is changed
// or saved. Geometry is in user space.

public struct PdfAnnotation {
    public var dictionary: PdfDictionary

    /// Nil for an annotation written directly in the page's /Annots array.
    public var reference: PdfReference?

    /// The page it is on, from 0; -1 when read without one.
    public var pageIndex = -1

    public var subtype = ""
    public var type = AnnotationType.other
    public var rect = PdfRect(0, 0, 0, 0)
    public var contents: String?
    public var title: String?
    public var subject: String?
    public var name: String?
    public var created: DateTimeOffset?
    public var modified: DateTimeOffset?
    public var flags: AnnotationFlags = []

    /// /C: nil when absent, empty for transparent, else gray, RGB or CMYK.
    public var color: [Double]?
    public var interiorColor: [Double]?
    public var opacity = 1.0
    public var border = AnnotationBorder(1, .solid, [])

    public var inReplyTo: PdfReference?

    /// /RT: "R" (a reply) or "Group".
    public var replyType: String?

    /// /State with /StateModel, nil when the annotation has none.
    public var state: ReviewStatus?

    public var quadPoints: [Double] = []
    public var inkList: [[Double]] = []
    public var vertices: [Double] = []

    /// /L: x1 y1 x2 y2, empty when absent.
    public var line: [Double] = []
    public var startEnding = LineEnding.none
    public var endEnding = LineEnding.none

    /// /CL: two or three points of a callout line.
    public var callout: [Double] = []
    public var intent: String?

    /// /RD: left, bottom, right, top insets of the drawn shape from `rect`, empty when absent.
    public var rectDifference: [Double] = []

    /// /BE with /S /C: the intensity (0, 1 or 2), 0 when the border is not a cloud.
    public var cloud = 0

    public var defaultAppearance: String?
    public var defaultStyle: String?
    public var richText: String?
    public var alignment = 0
    public var iconName: String?
    public var popup: PdfReference?
    public var hasAppearance = false

    public init(dictionary: PdfDictionary) {
        self.dictionary = dictionary
    }

    /// The corner points of the quads, as `MarkupQuad`s.
    public var quads: [MarkupQuad] {
        var quads: [MarkupQuad] = []
        var i = 0
        while i + 8 <= quadPoints.count {
            quads.append(MarkupQuad(quadPoints[i], quadPoints[i + 1], quadPoints[i + 2], quadPoints[i + 3],
                                    quadPoints[i + 4], quadPoints[i + 5], quadPoints[i + 6], quadPoints[i + 7]))
            i += 8
        }
        return quads
    }

    /// True for the subtypes that carry a comment (12.5.6.2): everything but links, widgets and popups.
    public var isMarkup: Bool {
        switch type {
        case .link, .widget, .popup, .other: return false
        default: return true
        }
    }
}
