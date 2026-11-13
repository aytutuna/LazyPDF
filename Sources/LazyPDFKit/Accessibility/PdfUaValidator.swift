import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/PdfUaValidator.cs: the machine-checkable failure conditions of the Matterhorn
// Protocol 1.1 for ISO 14289-1 (PDF/UA-1). What needs a person (reading order, whether alt text says the right thing,
// contrast) is not here; AccessibilityChecker lists those for the user. Nothing is changed except by `mark`, which takes the
// date for the metadata. The C# CancellationToken is the task's (`CancellationError`).

public enum PdfUaValidator {
    // The conditions marking settles itself: the identifier, the title shown, and a packet made from /Info.
    private static let settledByMark: Set<String> = ["06-001", "06-002", "06-003", "07-001", "07-002"]

    public static func validate(_ document: PdfDocument) throws -> PdfUaReport {
        let checker = PdfUaChecker(document)
        try checker.run()
        return checker.report()
    }

    /// Writes pdfuaid:part 1 to the XMP (a packet is made when the file has none) and sets DisplayDocTitle, but only when
    /// nothing else fails. The caller commits the document.
    public static func mark(_ document: PdfDocument, _ date: DateTimeOffset) throws -> PdfUaMarkResult {
        let report = try validate(document)
        let title = !DotNetText.isNullOrWhiteSpace(DocumentMetadata.read(document).title)
        let blocking = report.issues.filter { !settledByMark.contains($0.condition) || ($0.condition == "06-003" && !title) }
        if !blocking.isEmpty || report.truncated { return PdfUaMarkResult(false, PdfUaReport(blocking, report.truncated)) }
        if !(try PdfUaMarker.write(document, date)) { return PdfUaMarkResult(false, report) }
        return PdfUaMarkResult(true, PdfUaReport([], false))
    }
}
