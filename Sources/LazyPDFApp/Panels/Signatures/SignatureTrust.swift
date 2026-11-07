import Foundation
import LazyPDFKit

// Follows the trust part of windows/LazyPDF.App/Tools/Certificates/SigningSettings.cs and Panels/Signatures/
// SignaturesSidePanel.Trust.cs. The file is signing.json, which the Certificates tool keeps its own settings in too, so
// every change reads it again first and keeps what it does not know.

/// A certificate the user trusts, as the list shows it. `der` is the certificate in base64, as signing.json keeps it.
public struct TrustRow: Identifiable, Equatable {
    public let der: String
    public let name: String
    public let detail: String

    public var id: String { der }
}

private struct SigningFile: Codable {
    var trustWindowsStore = true
    var trustedCertificates: [String] = []
    var timestampUrl = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case trustWindowsStore, trustedCertificates, timestampUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trustWindowsStore = c.decodeLenient(forKey: .trustWindowsStore, default: trustWindowsStore)
        trustedCertificates = c.decodeLenient(forKey: .trustedCertificates, default: trustedCertificates)
        timestampUrl = c.decodeLenient(forKey: .timestampUrl, default: timestampUrl)
    }
}

/// Whether the roots the system trusts count, and the certificates the user added by hand.
public final class SignatureTrust {
    private let file: URL

    public init(directory: URL) {
        file = directory.appendingPathComponent("signing.json")
    }

    /// Roots the system trusts count as trusted here too.
    public var trustsSystem: Bool { load().trustWindowsStore }

    /// The certificates added by hand, as the list shows them.
    public var rows: [TrustRow] { load().trustedCertificates.map(Self.describe) }

    public func setTrustsSystem(_ on: Bool) {
        update { $0.trustWindowsStore = on }
    }

    /// Adds a certificate file, DER or PEM; false when it is not one.
    public func add(_ bytes: [UInt8]) -> Bool {
        guard let der = Self.der(bytes), X509Certificate(der) != nil else { return false }
        let text = Data(der).base64EncodedString()
        update { if !$0.trustedCertificates.contains(text) { $0.trustedCertificates.append(text) } }
        return true
    }

    public func remove(_ row: TrustRow) {
        update { $0.trustedCertificates.removeAll { $0 == row.der } }
    }

    /// The options the verifier gets for a file; certificates that no longer parse are left out.
    public func verifyOptions(password: String?, now: DateTimeOffset) -> VerifyOptions {
        let settings = load()
        var options = VerifyOptions()
        options.useSystemStore = settings.trustWindowsStore
        options.trustAnchors = settings.trustedCertificates.compactMap { Data(base64Encoded: $0).flatMap { X509Certificate([UInt8]($0)) } }
        options.now = now
        options.password = password
        return options
    }

    private func load() -> SigningFile {
        StoreFiles.load(SigningFile.self, from: file) ?? SigningFile()
    }

    private func update(_ change: (inout SigningFile) -> Void) {
        var settings = load()
        change(&settings)
        StoreFiles.write(settings, to: file)
    }

    private static func describe(_ text: String) -> TrustRow {
        guard let data = Data(base64Encoded: text), let certificate = X509Certificate([UInt8](data)) else {
            return TrustRow(der: text, name: L10n.t("Unreadable certificate"), detail: "")
        }
        let format = DateFormatter()
        format.dateStyle = .short
        format.timeStyle = .none
        let name = certificate.simpleName
        return TrustRow(der: text, name: name.isEmpty ? certificate.subject : name,
                        detail: L10n.t("Expires {0}", format.string(from: PanelDates.date(certificate.notAfter))))
    }

    // A PEM file wraps the same bytes in base64 between two lines.
    private static func der(_ bytes: [UInt8]) -> [UInt8]? {
        guard let text = String(bytes: bytes, encoding: .utf8), text.contains("-----BEGIN") else { return bytes }
        let body = text.split(whereSeparator: { $0.isNewline }).filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body).map { [UInt8]($0) }
    }
}
