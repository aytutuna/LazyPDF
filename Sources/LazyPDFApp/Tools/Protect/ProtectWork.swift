import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Protect/ProtectWork.cs.

/// What the person allows once the file is open. Print in high quality only counts while printing is allowed, and adding
/// comments always allows filling in forms. Reading aloud stays allowed: readers ignore that bit in the current standard.
public struct PermissionChoices: Equatable {
    public var print: Bool
    public var printHighQuality: Bool
    public var copy: Bool
    public var edit: Bool
    public var comment: Bool
    public var fillForms: Bool
    public var assemble: Bool

    public init(print: Bool, printHighQuality: Bool, copy: Bool, edit: Bool, comment: Bool, fillForms: Bool, assemble: Bool) {
        self.print = print
        self.printHighQuality = printHighQuality
        self.copy = copy
        self.edit = edit
        self.comment = comment
        self.fillForms = fillForms
        self.assemble = assemble
    }

    public static let everything = PermissionChoices(print: true, printHighQuality: true, copy: true, edit: true, comment: true,
                                                     fillForms: true, assemble: true)

    public func toPermissions() -> PdfPermissions {
        var allowed = PdfPermissions.none
        if print { allowed.insert(.print) }
        if print && printHighQuality { allowed.insert(.printHighQuality) }
        if copy { allowed.insert(.copy) }
        if edit { allowed.insert(.modify) }
        if comment { allowed.insert(.annotate) }
        if fillForms || comment { allowed.insert(.fillForms) }
        if assemble { allowed.insert(.assemble) }
        allowed.insert(.extractForAccessibility)
        return allowed
    }
}

/// Writes a protected or an open copy of a document. Encryption is made by a rewrite, which an update on top of the file
/// cannot do.
public enum ProtectWork {
    public static func withPassword(_ document: PdfDocument, openPassword: String, ownerPassword: String, allowed: PdfPermissions,
                                    strength: PdfCryptStrength) throws -> [UInt8] {
        var id = [UInt8](repeating: 0, count: 16)
        for at in id.indices { id[at] = UInt8.random(in: 0...255) }
        let security = PdfSecurity.create(userPassword: openPassword, ownerPassword: ownerPassword, permissions: allowed,
                                          strength: strength, firstId: id)
        let bytes = try document.saveRewrite(PdfSaveOptions(useObjectStreams: document.pdfAPart != 1, security: security, documentId: id))
        try checkPages(PdfDocument.open(bytes, password: openPassword), document)
        return bytes
    }

    public static func remove(_ document: PdfDocument) throws -> [UInt8] {
        let bytes = try document.saveRewrite(PdfSaveOptions(useObjectStreams: document.pdfAPart != 1))
        try checkPages(PdfDocument.open(bytes), document)
        return bytes
    }

    static func checkPages(_ written: PdfDocument, _ source: PdfDocument) throws {
        if written.pages.count != source.pages.count { throw PdfReadException.damaged("The copy has another number of pages.") }
    }

    /// Whether the boxes describe a protection that can be made: the two passwords agree, and the permissions password, when
    /// limits are set, is another word than the one to open. An empty password to open is fine when the limits are what the
    /// file is for.
    public static func passwordsAgree(_ open: String, _ repeated: String, limited: Bool, owner: String) -> Bool {
        (!open.isEmpty || limited) && open == repeated && (!limited || (!owner.isEmpty && owner != open))
    }

    /// True when the file restricts what its reader may do and the reader may not lift that: the engine refuses to rewrite it.
    public static func isLockedAgainstChange(_ document: PdfDocument) -> Bool {
        guard let security = document.security else { return false }
        return !security.openedAsOwner && security.permissions != .all
    }
}

#if canImport(Security)
extension ProtectWork {
    /// The copy for the recipients, and the certificate of one of them that opens it here; nil when none does.
    public static func forRecipients(_ document: PdfDocument, _ recipients: [PdfRecipient],
                                     _ strength: PdfCryptStrength) throws -> (bytes: [UInt8], opener: PdfCertificate?) {
        let security = try PdfSecurity.createPublicKey(recipients, strength)
        let bytes = try document.saveRewrite(PdfSaveOptions(useObjectStreams: document.pdfAPart != 1, security: security))
        // Holding a private key does not mean it can decrypt: a card may be out, or the key may be for signing only.
        for recipient in recipients where recipient.certificate.privateKey != nil {
            let back: PdfDocument
            do {
                back = try PdfDocument.open(bytes, certificate: recipient.certificate)
            } catch let error as PdfReadException where error.problem == .certificateRequired || error.problem == .unsupported {
                continue
            }
            try checkPages(back, document)
            return (bytes, recipient.certificate)
        }
        return (bytes, nil)
    }
}
#endif
