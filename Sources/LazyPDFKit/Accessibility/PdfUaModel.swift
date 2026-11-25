import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/PdfUaModel.cs.

/// One failure condition the file hits. `condition` is the Matterhorn Protocol id ("06-002", whose first two digits are the
/// checkpoint), empty when the protocol has no condition for the finding, and `clause` the clause of ISO 14289-1 behind it.
public struct PdfUaIssue {
    public let condition: String
    public let clause: String
    public let `where`: String
    public let message: String

    public init(_ condition: String, _ clause: String, _ place: String, _ message: String) {
        self.condition = condition
        self.clause = clause
        self.where = place
        self.message = message
    }

    public var checkpoint: String { String(condition.prefix(2)) }
}

/// What the PDF/UA-1 check found. `truncated` is set when it stopped listing at the cap.
public struct PdfUaReport {
    public let issues: [PdfUaIssue]
    public let truncated: Bool

    public init(_ issues: [PdfUaIssue], _ truncated: Bool) {
        self.issues = issues
        self.truncated = truncated
    }

    public var isValid: Bool { issues.isEmpty }
}

/// `marked`: the file now names PDF/UA-1; false leaves it as it was. `blocking`: the issues that stood in the way, empty when
/// marked. Those the marking itself would have settled are not in it.
public struct PdfUaMarkResult {
    public let marked: Bool
    public let blocking: PdfUaReport

    public init(_ marked: Bool, _ blocking: PdfUaReport) {
        self.marked = marked
        self.blocking = blocking
    }
}
