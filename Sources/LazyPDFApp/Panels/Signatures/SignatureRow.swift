import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Panels/Signatures/SignatureRow.cs.

public enum SignatureLevel {
    case good
    case caution
    case bad
    case unknown
}

/// A heading and the plain lines under it, in the details of one signature.
public struct SignatureSection: Equatable {
    public let heading: String
    public let lines: [String]
}

/// One signature in the list, in the words the engine has for it.
public struct SignatureRow: Identifiable {
    public let id: Int
    public let report: SignatureReport

    /// The page the signature's field is on, or -1 when it has none.
    public let page: Int

    /// The field on that page, in page space; nil when it has none.
    public let area: ViewRect?

    public init(_ report: SignatureReport, page: Int, area: ViewRect?) {
        id = report.index
        self.report = report
        self.page = page
        self.area = area
    }

    public var title: String { report.signerName ?? report.fieldName ?? L10n.t("Signature {0}", report.index + 1) }

    public var status: String { flaw.map { SignatureText.title($0) } ?? SignatureText.status(report.verdict) }

    public var sentence: String { flaw.map { SignatureText.title($0) + ". " + SignatureText.advice($0) } ?? report.sentence }

    public var summary: String { title + ", " + status + ". " + sentence }

    public var level: SignatureLevel {
        switch report.verdict {
        case .valid: return .good
        case .validButUntrusted: return flaw == .certificateRevoked ? .bad : .caution
        case .changedAfterSigning, .broken: return .bad
        default: return .unknown
        }
    }

    /// An SF Symbol for the level.
    public var symbol: String {
        switch level {
        case .good: return "checkmark.seal"
        case .caution: return "exclamationmark.triangle"
        case .bad: return "xmark.octagon"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Whether the open file goes on past this signature, so that its signed version differs from it.
    public var hasLaterRevisions: Bool { report.revision > 0 && !report.coversWholeFile }

    // A signer that is only unknown reads as such. One whose certificate was withdrawn, or that has some other flaw, reads as that.
    private var flaw: SignatureProblem? {
        guard report.verdict == .validButUntrusted else { return nil }
        if report.problems.contains(.certificateRevoked) { return .certificateRevoked }
        return report.problems.first { $0 != .untrustedSigner }
    }

    /// What is known about the signature, then what changed since, what is wrong, and what could not be checked.
    public var sections: [SignatureSection] {
        [
            SignatureSection(heading: L10n.t("About the signature"), lines: facts()),
            SignatureSection(heading: L10n.t("Changed since signing"), lines: changes()),
            SignatureSection(heading: L10n.t("Problems"), lines: problems()),
            SignatureSection(heading: L10n.t("Not checked"), lines: notChecked()),
        ].filter { !$0.lines.isEmpty }
    }

    private func facts() -> [String] {
        var lines: [String] = []
        if let issuer = report.certificate?.issuerSimpleName, !issuer.isEmpty { lines.append(L10n.t("Certificate from {0}.", issuer)) }
        if let reason = report.reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append(L10n.t("Reason: {0}", reason)) }
        if let place = report.location, !place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append(L10n.t("Place: {0}", place)) }
        if report.kind == .certification {
            switch report.certification {
            case .noChanges: lines.append(L10n.t("Certified: no changes are allowed."))
            case .formFill: lines.append(L10n.t("Certified: form filling is allowed."))
            case .annotate: lines.append(L10n.t("Certified: form filling and comments are allowed."))
            default: break
            }
        }
        if report.level >= .lt { lines.append(L10n.t("Proof of the certificate is stored in the file.")) }
        return lines
    }

    private func changes() -> [String] {
        var lines: [String] = []
        for change in report.changes.changes {
            let line = change.allowed ? SignatureText.describe(change) : L10n.t("{0}, not allowed", SignatureText.describe(change))
            if !lines.contains(line) { lines.append(line) }
        }
        return lines
    }

    private func problems() -> [String] {
        report.problems.map { SignatureText.title($0) + ". " + SignatureText.advice($0) }
    }

    private func notChecked() -> [String] {
        var lines: [String] = []
        if report.verdict == .unknown { return lines }
        if report.certificate != nil && !report.revocationChecked { lines.append(L10n.t("Whether the certificate was withdrawn.")) }
        if report.kind != .documentTimestamp && report.timestampTime == nil { lines.append(L10n.t("When it was signed. The time is the signer's word.")) }
        return lines
    }
}
