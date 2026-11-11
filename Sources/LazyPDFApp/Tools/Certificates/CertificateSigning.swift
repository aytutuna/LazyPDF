import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Certificates/CertificateSigning.cs and CancellableTransport.cs: signing with what the panel
// collects, and the transport that Cancel can end.

/// What the person picked in the panel. `field` is an empty signature field of the file, nil for a new one or none; `rect` the
/// box of a new visible signature in user space, nil with no field makes it invisible; `timestampUrl` nil or empty for no time
/// stamp; `longTerm` adds the revocation data (PAdES B-LT) and needs a time stamp.
struct SignChoices {
    var certificate: X509Certificate
    var field: String?
    var page: Int
    var rect: PdfRect?
    var reason: String
    var location: String
    var certify: CertificationLevel
    var timestampUrl: String?
    var longTerm: Bool
}

/// Posts and fetches for a signing, and says why a request failed; `cancel` ends the one in flight.
public protocol SigningTransport: SignatureTransport {
    var lastFailure: String? { get }
    func cancel()
}

#if canImport(Darwin)
extension UrlSessionTransport: SigningTransport {}
#endif

/// Lets Cancel end a signing that waits on a server: once the token is cancelled a request gets no answer, and neither does one
/// that was answered after Cancel. The protocol cannot throw, so the engine fails the step and the caller sees the token.
final class CancellableTransport: SignatureTransport {
    private let inner: SignatureTransport
    private let token: CancelToken

    init(_ inner: SignatureTransport, _ token: CancelToken) {
        self.inner = inner
        self.token = token
    }

    func post(_ url: String, _ contentType: String, _ body: [UInt8]) -> [UInt8]? {
        if token.isCancelled { return nil }
        let answer = inner.post(url, contentType, body)
        return token.isCancelled ? nil : answer
    }

    func get(_ url: String) -> [UInt8]? {
        if token.isCancelled { return nil }
        let answer = inner.get(url)
        return token.isCancelled ? nil : answer
    }
}

enum CertificateSigning {
    static func request(_ choices: SignChoices, _ transport: SignatureTransport, _ fonts: FontSource?, _ now: DateTimeOffset) -> PdfSignRequest {
        let stamp = choices.timestampUrl.flatMap { $0.isEmpty ? nil : TimestampSettings(transport, url: $0) }
        var request = PdfSignRequest(choices.certificate, now)
        request.fieldName = choices.field
        request.pageIndex = choices.page
        request.rect = choices.rect
        request.reason = blank(choices.reason)
        request.location = blank(choices.location)
        request.certify = choices.certify
        request.timestamp = stamp
        request.level = stamp == nil ? .b : choices.longTerm ? .lt : .t
        request.fonts = fonts
        return request
    }

    /// Signs the session's file. A step that fails or is cancelled leaves nothing of itself behind: what it had added but not
    /// committed is dropped, so the file is never left holding a signature that was not finished.
    static func sign(_ session: PdfEditSession, _ choices: SignChoices, _ transport: SignatureTransport, _ fonts: FontSource?,
                     _ now: DateTimeOffset, token: CancelToken = CancelToken()) throws {
        try guarded(session, token) { try PdfSigner.sign(session, request(choices, transport, fonts, now)) }
    }

    static func addValidation(_ session: PdfEditSession, _ transport: SignatureTransport, _ now: DateTimeOffset,
                              token: CancelToken = CancelToken()) throws {
        try guarded(session, token) { try PdfLongTermValidation.add(session, transport, now) }
    }

    /// Whether every signature of the file now has proof from the certificate servers that its certificates were not withdrawn.
    static func revocationCovered(_ file: [UInt8], _ options: VerifyOptions) throws -> Bool {
        try PdfSignatureVerifier.verify(file, options).filter { $0.certificate != nil }.allSatisfy(\.revocationChecked)
    }

    /// Why the file may not be signed; nil when it may. A field of the file needs less than a new one.
    static func refusal(_ document: PdfDocument, newField: Bool) -> Problem? {
        guard let security = document.security, !security.openedAsOwner else { return nil }
        let permissions = security.permissions
        let allowed = newField
            ? permissions.contains(.annotate) && permissions.contains(.modify)
            : permissions.contains(.fillForms) || permissions.contains(.annotate)
        return allowed ? nil : Problem(L10n.t("This file cannot be signed"), L10n.t("Its permissions do not allow it. Open it with the owner password."))
    }

    static func isWebAddress(_ text: String) -> Bool {
        guard let address = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = address.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = address.host else { return false }
        return !host.isEmpty
    }

    /// The empty signature fields of a file, by name.
    static func emptyFields(_ document: PdfDocument) -> [String] {
        PdfForm.read(document).fields.filter { $0.kind == .signature && !$0.isSigned }.map(\.name)
    }

    /// The place choice to keep after the file changed: 0 not visible, 1 a drawn box, 2 and up the fields in order.
    static func keptPlace(oldIndex: Int, oldField: String?, fields: [String]) -> Int {
        if oldIndex == 0 || oldIndex == 1 { return oldIndex }
        guard let oldField, let at = fields.firstIndex(of: oldField) else { return 0 }
        return at + 2
    }

    // The transport answers nobody once the token is cancelled, which the engine takes for servers that are down: it goes on and
    // commits what it can. A cancelled run adds nothing, so what was committed is taken back, and the error is the cancel.
    private static func guarded(_ session: PdfEditSession, _ token: CancelToken, _ work: () throws -> Void) throws {
        let length = session.current.count
        do {
            try token.throwIfCancelled()
            try work()
            try token.throwIfCancelled()
        } catch {
            try? session.discard()
            if token.isCancelled {
                while session.current.count != length && session.canUndo {
                    if (try? session.undo()) != true { break }
                }
                throw CancellationError()
            }
            throw error
        }
    }

    private static func blank(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
