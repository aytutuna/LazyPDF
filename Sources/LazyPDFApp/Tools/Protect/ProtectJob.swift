import Foundation
import LazyPDFKit

// Follows the worker of RunAsync in windows/LazyPDF.App/Tools/Protect/ProtectPanel.xaml.cs: a copy of the file's bytes is
// opened, checked for the permissions password and rewritten, off the main actor.

public enum ProtectMode {
    case password, certificates, remove
}

public enum ProtectOutcome {
    /// The permissions password given did not open the file as its owner.
    case refused
    /// `opener` is the certificate (DER) of a recipient who opens the copy on this device.
    case made(bytes: [UInt8], opener: [UInt8]?)
}

public enum ProtectJob {
    public static func run(_ file: [UInt8], password: String?, certificate: X509Certificate?, locked: Bool, mode: ProtectMode,
                           openPassword: String, ownerPassword: String, allowed: PdfPermissions, strength: PdfCryptStrength,
                           recipients: [Recipient], token: CancelToken) throws -> ProtectOutcome {
        let document: PdfDocument
        do {
            document = try ToolDocuments.open(file, password: password, certificate: certificate)
        } catch let error as PdfReadException where locked && error.problem == .passwordRequired {
            return .refused
        }
        if locked && document.security?.openedAsOwner != true { return .refused }
        try token.throwIfCancelled()
        let made: ProtectOutcome
        switch mode {
        case .remove:
            made = .made(bytes: try ProtectWork.remove(document), opener: nil)
        case .certificates:
            #if canImport(Security)
            let (bytes, opener) = try ProtectWork.forRecipients(document, recipients.map { $0.toPdfRecipient(allowed) }, strength)
            made = .made(bytes: bytes, opener: opener.flatMap { Recipient($0)?.der })
            #else
            throw InvalidOperationException("Certificates need the system's Security framework.")
            #endif
        case .password:
            made = .made(bytes: try ProtectWork.withPassword(document, openPassword: openPassword, ownerPassword: ownerPassword,
                                                             allowed: allowed, strength: strength), opener: nil)
        }
        try token.throwIfCancelled()
        return made
    }
}
