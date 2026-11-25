import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/PdfUa/UaCheck.cs: what the PDF/UA check found, and whether marking the file would be accepted.

public struct UaOutcome {
    public let report: PdfUaReport
    public let canMark: Bool

    /// Runs the check on a private copy. Marking is tried on the same copy, so the offer to mark is made only when it would
    /// work and the tab's file is not touched.
    static func of(_ copy: PdfDocument) throws -> UaOutcome {
        let report = try PdfUaValidator.validate(copy)
        let canMark = try !report.isValid && !report.truncated && PdfUaValidator.mark(copy, PanelDates.now()).marked
        return UaOutcome(report: report, canMark: canMark)
    }

    func verdict(_ rows: Int) -> String {
        report.isValid
            ? L10n.t("Passes Lazy PDF's checks for PDF/UA-1.")
            : L10n.t("Does not pass the checks for PDF/UA-1. Conditions broken: {0}.", rows)
    }

    var status: String {
        report.isValid ? L10n.t("Passes Lazy PDF's PDF/UA-1 checks.") : L10n.t("Fails PDF/UA-1 checks.")
    }
}
