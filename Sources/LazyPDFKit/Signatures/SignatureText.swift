import Foundation

// Twin of windows/LazyPDF.Core/Signatures/SignatureText.cs: the texts of signing and verifying.

public enum SignatureText {
    public static var noPrivateKey: String { L10n.t("This certificate has no private key. Choose another one or sign with a token.") }
    public static var notCertifiable: String { L10n.t("Only the first signature of a file can certify it. Sign without certifying.") }
    public static var certifiedClosed: String { L10n.t("This file is certified so that nothing may change. Another signature would break that.") }
    public static var fieldLocked: String { L10n.t("An earlier signature locked this field. Choose another one.") }
    public static var fieldTaken: String { L10n.t("This field is already signed. Choose another one.") }
    public static var noFont: String { L10n.t("No font can draw the signature text. Choose another font.") }
    public static var noPage: String { L10n.t("The page is not in the document.") }
    public static var noTimestamp: String { L10n.t("The time stamp server gave no answer. Try again later.") }
    public static var noTimestampServer: String { L10n.t("This signature needs a time stamp server.") }
    public static var noRoom: String { L10n.t("The signature does not fit in the space kept for it.") }
    public static var seedFormat: String { L10n.t("The field asks for a different signature format.") }
    public static var seedDigest: String { L10n.t("The field asks for a different digest.") }
    public static var seedReason: String { L10n.t("The field asks for one of its listed reasons.") }
    public static var seedCertificate: String { L10n.t("The field asks for another certificate.") }
    public static var seedCertification: String { L10n.t("The field asks for another certification level.") }
    public static var seedUnsupported: String { L10n.t("The field asks for something Lazy PDF cannot do.") }
    public static var notSigned: String { L10n.t("The file has no signature to add validation data to.") }

    // The wording of the visible signature.
    public static let signedBy = "Digitally signed by"
    public static let datePrefix = "Date:"
    public static let reasonPrefix = "Reason:"
    public static let locationPrefix = "Location:"

    /// Six words at most.
    public static func status(_ verdict: SignatureVerdict) -> String {
        switch verdict {
        case .valid: return L10n.t("Signature is valid")
        case .validButUntrusted: return L10n.t("Signer is not trusted")
        case .changedAfterSigning: return L10n.t("Changed after signing")
        case .broken: return L10n.t("Signature is not valid")
        case .unknown: return L10n.t("Signature not checked")
        }
    }

    /// One line a person can read.
    public static func sentence(_ report: SignatureReport) -> String {
        let when = date(report.timestampTime ?? report.signingTime)
        let who = report.signerName ?? L10n.t("an unknown signer")
        let stamp = report.kind == .documentTimestamp
        let head: String
        if when.isEmpty {
            head = stamp ? L10n.t("Time stamped.") : L10n.t("Signed by {0}.", who)
        } else {
            head = stamp ? L10n.t("Time stamped on {0}.", when) : L10n.t("Signed by {0} on {1}.", who, when)
        }
        switch report.verdict {
        case .valid:
            return report.changes.isEmpty ? head + " " + L10n.t("Not changed since.") : head + " " + L10n.t("Changed only as the signer allowed.")
        case .validButUntrusted:
            return head + " " + (report.changes.isEmpty ? "" : L10n.t("Changed only as allowed.") + " ") + L10n.t("The signer is not trusted.")
        case .changedAfterSigning:
            return head + " " + L10n.t("Changed since.")
        case .broken:
            return stamp ? L10n.t("The time stamp is not valid.") : L10n.t("The signature by {0} is not valid.", who)
        case .unknown:
            return L10n.t("This signature could not be checked.")
        }
    }

    /// What is wrong, as a title.
    public static func title(_ problem: SignatureProblem) -> String {
        switch problem {
        case .unsupportedFormat: return L10n.t("Signature format not supported")
        case .badByteRange: return L10n.t("Signature does not cover the file")
        case .digestMismatch: return L10n.t("File does not match the signature")
        case .badSignature: return L10n.t("Signature is damaged")
        case .noCertificate: return L10n.t("Signer's certificate is missing")
        case .untrustedSigner: return L10n.t("Signer is not trusted")
        case .certificateNotValid: return L10n.t("Certificate was not valid when signing")
        case .certificateRevoked: return L10n.t("Certificate was revoked")
        case .changedAfterSigning: return L10n.t("File changed after signing")
        case .damagedStructure: return L10n.t("File structure is damaged")
        case .timestampInvalid: return L10n.t("Time stamp is not valid")
        case .weakDigest: return L10n.t("Signature uses a weak digest")
        }
    }

    /// What to do about it.
    public static func advice(_ problem: SignatureProblem) -> String {
        switch problem {
        case .unsupportedFormat: return L10n.t("Check the file with the program that signed it.")
        case .badByteRange: return L10n.t("Do not rely on this signature. Ask for a new copy.")
        case .digestMismatch: return L10n.t("Do not rely on this file. Ask for a new copy.")
        case .badSignature: return L10n.t("Do not rely on this signature. Ask for a new copy.")
        case .noCertificate: return L10n.t("Ask the signer to sign again with the certificate included.")
        case .untrustedSigner: return L10n.t("Trust the signer's certificate only after checking it with them.")
        case .certificateNotValid: return L10n.t("Check the date on the signature and the certificate.")
        case .certificateRevoked: return L10n.t("Do not rely on this signature.")
        case .changedAfterSigning: return L10n.t("Open the signed version from the file's history.")
        case .damagedStructure: return L10n.t("Open the signed version from the file's history.")
        case .timestampInvalid: return L10n.t("Treat the signing time as the signer's claim.")
        case .weakDigest: return L10n.t("Ask the signer to sign again with SHA-256.")
        }
    }

    /// A change in words.
    public static func describe(_ change: SignatureChange) -> String {
        let place: String
        if let field = change.field {
            place = L10n.t(" in field {0}", field)
        } else if change.page >= 0 {
            place = L10n.t(" on page {0}", change.page + 1)
        } else {
            place = ""
        }
        switch change.kind {
        case .formFill: return L10n.t("Form filled") + place
        case .signature: return L10n.t("Signature added") + place
        case .validationData: return L10n.t("Validation data added")
        case .comment: return L10n.t("Comment changed") + place
        case .metadata: return L10n.t("Document information changed")
        case .pageContent: return L10n.t("Page content changed") + place
        case .pageStructure: return L10n.t("Pages changed") + place
        case .form: return L10n.t("Form changed") + place
        case .unreadable: return L10n.t("Added data cannot be checked")
        case .other: return L10n.t("Document changed") + place
        }
    }

    // The abbreviated month names are those of the language in use: English or Turkish, as the culture type knows them.
    private static func date(_ time: DateTimeOffset?) -> String {
        guard let time else { return "" }
        let culture = CultureInfo(L10n.override?.language ?? Bundle.main.preferredLocalizations.first ?? "en")
        return (try? time.toString("d MMM yyyy", culture)) ?? ""
    }
}
