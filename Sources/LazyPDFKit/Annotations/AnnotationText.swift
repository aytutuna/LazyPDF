import Foundation

// Twin of windows/LazyPDF.Core/Annotations/AnnotationText.cs: the words this layer shows, and the names of the stamps.

/// The C# ArgumentException of a call that a click, a selection or a file can make impossible: no area, too few points, a
/// reply to a direct annotation.
public struct ArgumentException: Error, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// The C# InvalidOperationException, for what a user's input or a missing font can cause (a caller's own mistake is a
/// precondition).
public struct InvalidOperationException: Error, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

public enum AnnotationText {
    public static var noFont: String { L10n.t("No font can draw this text. Choose another font.") }

    public static func kindName(_ type: AnnotationType) -> String {
        switch type {
        case .text: return L10n.t("Note")
        case .freeText: return L10n.t("Text box")
        case .line: return L10n.t("Line")
        case .square: return L10n.t("Rectangle")
        case .circle: return L10n.t("Oval")
        case .polygon: return L10n.t("Polygon")
        case .polyLine: return L10n.t("Polyline")
        case .highlight: return L10n.t("Highlight")
        case .underline: return L10n.t("Underline")
        case .squiggly: return L10n.t("Squiggly underline")
        case .strikeOut: return L10n.t("Strikethrough")
        case .stamp: return L10n.t("Stamp")
        case .caret: return L10n.t("Insert text")
        case .ink: return L10n.t("Drawing")
        case .fileAttachment: return L10n.t("Attachment")
        case .redact: return L10n.t("Redaction")
        case .link: return L10n.t("Link")
        default: return L10n.t("Annotation")
        }
    }

    public static func statusName(_ status: ReviewStatus) -> String {
        switch status {
        case .accepted: return L10n.t("Accepted")
        case .rejected: return L10n.t("Rejected")
        case .cancelled: return L10n.t("Cancelled")
        case .completed: return L10n.t("Completed")
        case .marked: return L10n.t("Marked")
        case .unmarked: return L10n.t("Unmarked")
        default: return L10n.t("None")
        }
    }

    public static func statusSetBy(_ status: ReviewStatus, _ author: String) -> String {
        L10n.t("{0} set by {1}", statusName(status), author)
    }

    /// The standard stamp names of ISO 32000-1 12.5.6.12, in the order a palette shows them.
    public static let standardStamps: [String] = [
        "Approved", "NotApproved", "Draft", "Final", "Confidential", "ForComment", "ForPublicRelease", "NotForPublicRelease",
        "AsIs", "Experimental", "Expired", "Sold", "Departmental", "TopSecret",
    ]

    /// What a stamp says: the words of a standard name in capitals, a custom name as it is.
    public static func stampLabel(_ name: String) -> String {
        switch name {
        case "Approved": return "APPROVED"
        case "NotApproved": return "NOT APPROVED"
        case "Draft": return "DRAFT"
        case "Final": return "FINAL"
        case "Confidential": return "CONFIDENTIAL"
        case "ForComment": return "FOR COMMENT"
        case "ForPublicRelease": return "FOR PUBLIC RELEASE"
        case "NotForPublicRelease": return "NOT FOR PUBLIC RELEASE"
        case "AsIs": return "AS IS"
        case "Experimental": return "EXPERIMENTAL"
        case "Expired": return "EXPIRED"
        case "Sold": return "SOLD"
        case "Departmental": return "DEPARTMENTAL"
        case "TopSecret": return "TOP SECRET"
        default: return name
        }
    }
}
