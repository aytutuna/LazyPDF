import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfALevel.cs: a PDF/A part and conformance level (ISO 19005). Part 4 has no
// level B or U; the plain "4" is meant. The C# PdfALevels extension methods are methods of the enum here.

public enum PdfALevel {
    case a1b
    case a2b
    case a2u
    case a3b
    case a3u
    case a4

    public func part() -> Int {
        switch self {
        case .a1b: return 1
        case .a2b, .a2u: return 2
        case .a3b, .a3u: return 3
        case .a4: return 4
        }
    }

    /// "B" or "U"; nil for part 4, which has none.
    public func conformance() -> String? {
        switch self {
        case .a1b, .a2b, .a3b: return "B"
        case .a2u, .a3u: return "U"
        case .a4: return nil
        }
    }

    /// The level asks for Unicode text mappings (level U).
    public func needsUnicode() -> Bool { self == .a2u || self == .a3u }

    public func name() -> String {
        guard let conformance = conformance() else { return "PDF/A-4" }
        return "PDF/A-\(part())\(conformance.lowercased())"
    }
}

/// One rule a file breaks: the clause of the standard, where in the file, and what is wrong in a sentence.
public struct PdfAIssue: Hashable {
    public let clause: String
    public let `where`: String
    public let message: String

    public init(_ clause: String, _ place: String, _ message: String) {
        self.clause = clause
        self.where = place
        self.message = message
    }

    // Ordinal, as the C# record compares: String's own == equates canonical equivalents, and the texts here are arbitrary Unicode from the XMP.
    public static func == (a: PdfAIssue, b: PdfAIssue) -> Bool {
        a.clause.utf8.elementsEqual(b.clause.utf8) && a.where.utf8.elementsEqual(b.where.utf8) && a.message.utf8.elementsEqual(b.message.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Array(clause.utf8))
        hasher.combine(Array(`where`.utf8))
        hasher.combine(Array(message.utf8))
    }
}

/// What the validator found. `truncated` is set when it stopped listing at the cap.
public struct PdfAReport {
    public let level: PdfALevel
    public let issues: [PdfAIssue]
    public let truncated: Bool

    public init(_ level: PdfALevel, _ issues: [PdfAIssue], _ truncated: Bool) {
        self.level = level
        self.issues = issues
        self.truncated = truncated
    }

    public var isValid: Bool { issues.isEmpty }
}

/// Checks a document against PDF/A (ISO 19005) rule by rule. It reads the file as the reader sees
/// it, so a file the reader had to repair is reported for the repair.
public enum PdfAValidator {
    public static func validate(_ document: PdfDocument, _ level: PdfALevel) -> PdfAReport {
        let checker = PdfAChecker(document, level)
        checker.run()
        return checker.report()
    }
}
