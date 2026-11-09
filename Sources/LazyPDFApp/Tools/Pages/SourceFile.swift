import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Pages/SourceFile.cs, SourcePasswordWindow.xaml.cs and SourceCertificateWindow.xaml.cs:
// another PDF a tool takes pages from, and the questions its password or certificate ask.

/// Whoever answers for the person when a file asks for a password or an identity; nil when the person gives up.
@MainActor
public protocol SourceAsker: AnyObject {
    /// `wrong` is set when the last password did not open the file.
    func password(for name: String, wrong: Bool) async -> String?

    func certificate(for name: String, wrong: Bool) async -> CertificateChoice?
}

@MainActor
public enum SourceFile {
    /// Reads and opens the file off the main actor, asking for its password or certificate when it has one; nil, with the reason
    /// shown, when it cannot be used. The grant of the file ends when it has been read.
    public static func open(_ host: ToolHost, _ file: ToolFile, _ asker: SourceAsker) async -> PdfDocument? {
        defer { file.access?.stop() }
        let url = file.url
        return await open(host, name: url.lastPathComponent, asker) { [UInt8](try Data(contentsOf: url)) }
    }

    /// The same for bytes that `read` fetches, again for every try.
    public static func open(_ host: ToolHost, name: String, _ asker: SourceAsker,
                            read: @escaping @Sendable () throws -> [UInt8]) async -> PdfDocument? {
        var password: String?
        var choice: CertificateChoice?
        while true {
            var document: PdfDocument?
            let typed = password
            let held = choice.flatMap { host.verifyCertificate($0) }
            do {
                try await host.runBusy(L10n.t("Reading file")) { token in
                    document = try await ToolDocuments.run(token) {
                        try ToolDocuments.open(read(), password: typed, certificate: held)
                    }
                }
                return document
            } catch let error as PdfReadException where error.problem == .passwordRequired {
                choice = nil
                guard let answer = await asker.password(for: name, wrong: password != nil) else { return nil }
                password = answer
            } catch let error as PdfReadException where error.problem == .certificateRequired {
                guard let answer = await asker.certificate(for: name, wrong: choice != nil) else { return nil }
                choice = answer
            } catch {
                host.showProblem(Problems.open(error, name))
                return nil
            }
        }
    }
}

/// The question on screen while a source file waits for an answer: the views show it as a sheet.
@MainActor
@Observable
public final class SourceQuestion: SourceAsker {
    public enum Kind {
        case password, certificate
    }

    public struct Ask: Identifiable {
        public let id = UUID()
        public let kind: Kind
        public let name: String
        public let problem: String?
        public let choices: [CertificateChoice]
    }

    public private(set) var asking: Ask?

    /// The identities a file for recipients can be opened with; the model sets it when it is attached.
    @ObservationIgnored public var choices: () -> [CertificateChoice] = { [] }

    @ObservationIgnored private var passwordWaiting: CheckedContinuation<String?, Never>?
    @ObservationIgnored private var certificateWaiting: CheckedContinuation<CertificateChoice?, Never>?

    public init() {}

    public func password(for name: String, wrong: Bool) async -> String? {
        await withCheckedContinuation { waiting in
            passwordWaiting = waiting
            asking = Ask(kind: .password, name: name, problem: wrong ? L10n.t("That password is not right.") : nil, choices: [])
        }
    }

    public func certificate(for name: String, wrong: Bool) async -> CertificateChoice? {
        let found = CertificateChoice.order(choices())
        let problem = found.isEmpty ? L10n.t("No certificate with a private key was found on this computer.")
            : wrong ? L10n.t("That certificate does not open this file.") : nil
        return await withCheckedContinuation { waiting in
            certificateWaiting = waiting
            asking = Ask(kind: .certificate, name: name, problem: problem, choices: found)
        }
    }

    public func answer(password: String?) {
        asking = nil
        let waiting = passwordWaiting
        passwordWaiting = nil
        waiting?.resume(returning: password)
    }

    public func answer(certificate: CertificateChoice?) {
        asking = nil
        let waiting = certificateWaiting
        certificateWaiting = nil
        waiting?.resume(returning: certificate)
    }

    /// The tool went away with the question open: it counts as given up.
    public func giveUp() {
        answer(password: nil)
        answer(certificate: nil)
    }
}
