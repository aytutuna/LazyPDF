import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Certificates/CertificatesPanel.xaml.cs: sign with an identity from the keychain or a .p12
// file, add validation data to the signatures a file already has. The signing is done in the open document's own session, so
// it is one undo step in the tab like any other change, and the person saves it as usual.

/// Where the signature goes on the page.
public enum SignaturePlace: Equatable {
    case invisible
    case box
    case field(String)
}

public struct SignaturePlaceChoice: Equatable, Identifiable {
    public let text: String
    public let place: SignaturePlace

    public var id: String { text }
}

public struct CertifyLevelChoice: Equatable {
    public let text: String
    public let level: CertificationLevel
}

/// Tells the code that waits for a job that Cancel let go of, once that job really ends.
final class JobHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    private var after: (@Sendable () -> Void)?

    func end() {
        lock.lock()
        ended = true
        let run = after
        after = nil
        lock.unlock()
        run?()
    }

    /// Runs `work` when the job ends, at once if it has.
    func whenEnded(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        let done = ended
        if !done { after = work }
        lock.unlock()
        if done { work() }
    }
}

@MainActor
@Observable
public final class CertificatesModel: ToolPanelModel {
    public var useKeychain = true
    public var selectedIdentity: String?
    public var placeIndex = 0
    public var reason = ""
    public var location = ""
    public var certifyIndex = 0
    public var timestamp = false
    public var timestampUrl = ""
    public static let suggestedTimestampUrl = "http://timestamp.digicert.com"
    public var longTerm = false
    public var pfxPassword = ""

    public private(set) var identities: [CertificateChoice] = []
    public private(set) var places: [SignaturePlaceChoice] = []
    public private(set) var pfxName = ""
    public private(set) var boxText = ""
    public private(set) var working = false

    // Bumped when the file changes, so what is derived from it is read again.
    private var fileVersion = 0
    var tab: DocumentTab?
    var viewer: DocumentViewer?
    var host: ToolHost?
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var tool: SignatureBoxTool?
    private var box: (page: Int, area: ViewRect)?
    @ObservationIgnored private var boxKey: PageKey?
    @ObservationIgnored private var pfx: [UInt8]?
    @ObservationIgnored private let trust: SignatureTrust
    @ObservationIgnored private let fonts: FontSource?
    @ObservationIgnored private let makeTransport: () -> SigningTransport
    @ObservationIgnored private let importIdentity: ([UInt8], String) throws -> X509Certificate

    /// `importIdentity` reads a .p12 or .pfx file and its password into a certificate with its key.
    public init(trust: SignatureTrust, fonts: FontSource? = nil, transport: @escaping () -> SigningTransport,
                importIdentity: @escaping ([UInt8], String) throws -> X509Certificate) {
        self.trust = trust
        self.fonts = fonts
        makeTransport = transport
        self.importIdentity = importIdentity
    }

    public var action: ToolAction? {
        ToolAction(L10n.t("Sign"), symbol: "signature", canRun: { [self] in canSign }, run: { [self] in await sign() })
    }

    public static var certifyChoices: [CertifyLevelChoice] {
        [
            CertifyLevelChoice(text: L10n.t("Do not certify"), level: .none),
            CertifyLevelChoice(text: L10n.t("No changes allowed"), level: .noChanges),
            CertifyLevelChoice(text: L10n.t("Form filling allowed"), level: .formFill),
            CertifyLevelChoice(text: L10n.t("Form filling and comments allowed"), level: .annotate),
        ]
    }

    var place: SignaturePlaceChoice? { places.indices.contains(placeIndex) ? places[placeIndex] : nil }

    public var drawsBox: Bool { place?.place == .box }

    public var canSign: Bool {
        guard !working, tab != nil else { return false }
        if useKeychain ? selectedIdentity == nil : pfxName.isEmpty { return false }
        if let place, place.place == .box, box == nil { return false }
        return !timestamp || CertificateSigning.isWebAddress(timestampUrl)
    }

    /// The document is signed already, so it cannot be certified and may take validation data.
    public var isSigned: Bool {
        _ = fileVersion
        return tab?.document.isSigned ?? false
    }

    public var certificateNote: String {
        if identities.isEmpty { return L10n.t("The keychain has no certificate with a private key for you. Use a .p12 file.") }
        if let choice = identities.first(where: { $0.id == selectedIdentity }), !choice.isValidNow {
            return L10n.t("This certificate is not valid today. The signature will show as not trusted.")
        }
        return ""
    }

    public var urlNote: String {
        !timestampUrl.trimmingCharacters(in: .whitespaces).isEmpty && !CertificateSigning.isWebAddress(timestampUrl)
            ? L10n.t("Use a web address that starts with http:// or https://.") : ""
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.viewer = viewer
        self.host = host
        if timestampUrl.isEmpty { timestampUrl = trust.timestampUrl.isEmpty ? Self.suggestedTimestampUrl : trust.timestampUrl }
        let chosen = selectedIdentity
        identities = host.certificateChoices()
        selectedIdentity = identities.contains { $0.id == chosen } ? chosen : identities.first?.id
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in
            self?.refill()
        })
        refill()
        if let field = host.takeSigningField(), let at = places.firstIndex(where: { $0.place == .field(field) }) { placeIndex = at }
    }

    public func detach() {
        watch?.stop()
        watch = nil
        stop()
        clearBox()
        pfxPassword = ""
        pfx = nil
        pfxName = ""
        tab = nil
        viewer = nil
        host = nil
    }

    // What depends on the file: its empty signature fields, and whether it can still be certified.
    private func refill() {
        guard let tab else { return }
        fileVersion += 1
        stop()
        var choices = [SignaturePlaceChoice(text: L10n.t("Not visible"), place: .invisible), SignaturePlaceChoice(text: L10n.t("A box I draw on the page"), place: .box)]
        choices += CertificateSigning.emptyFields(tab.document).map { SignaturePlaceChoice(text: L10n.t("Field {0}", $0), place: .field($0)) }
        var field: String?
        if case .field(let name)? = place?.place { field = name }
        places = choices
        let kept = CertificateSigning.keptPlace(oldIndex: placeIndex, oldField: field, fields: choices.dropFirst(2).compactMap { choice -> String? in
            if case .field(let name) = choice.place { return name }
            return nil
        })
        let keepBox = kept == 1 && box.map { $0.page < tab.pageCount && PageKey.of(tab.document.pages[$0.page]) == boxKey } ?? false
        if !keepBox { clearBox() }
        placeIndex = kept
        if keepBox, let box {
            viewer?.overlay(box.page).set(SignatureBoxTool.outline(SignatureBoxTool.outlineId, box.area))
        } else {
            boxText = kept == 1 ? L10n.t("No box yet.") : ""
        }
        if tab.document.isSigned { certifyIndex = 0 }
    }

    public func setPlace(_ index: Int) {
        guard places.indices.contains(index) else { return }
        stop()
        clearBox()
        placeIndex = index
        boxText = places[index].place == .box ? L10n.t("No box yet.") : ""
    }

    public func chooseFile() async {
        guard let host else { return }
        guard let file = await host.filePicker.pickFiles([.certificate], multiple: false).first else { return }
        defer { file.access?.stop() }
        guard let data = try? Data(contentsOf: file.url) else {
            host.showProblem(Problem(L10n.t("Certificate not opened"), L10n.t("The .p12 file could not be opened. Check the password and that the file is a .p12.")))
            return
        }
        pfx = [UInt8](data)
        pfxName = file.url.lastPathComponent
    }

    // MARK: The box

    public func drawBox() {
        guard let viewer else { return }
        stop()
        clearBox()
        let tool = SignatureBoxTool(viewer, drawn: { [weak self] page, area in self?.boxDrawn(page, area) }, stopped: { [weak self] in self?.toolEnded() })
        self.tool = tool
        viewer.pointerTool = tool
        boxText = L10n.t("Drag on the page where it goes.")
    }

    private func toolEnded() {
        stop()
        if box == nil && place?.place == .box { boxText = L10n.t("No box yet.") }
    }

    private func boxDrawn(_ page: Int, _ area: ViewRect) {
        stop()
        box = (page, area)
        if let tab { boxKey = PageKey.of(tab.document.pages[page]) }
        viewer?.overlay(page).set(SignatureBoxTool.outline(SignatureBoxTool.outlineId, area))
        boxText = L10n.t("Box drawn on page {0}.", page + 1)
    }

    private func stop() {
        guard let tool else { return }
        self.tool = nil
        if viewer?.pointerTool === tool { viewer?.pointerTool = nil }
    }

    private func clearBox() {
        if let box { viewer?.overlay(box.page).remove(SignatureBoxTool.outlineId) }
        box = nil
    }

    // MARK: Signing

    private func choices(_ certificate: X509Certificate, _ place: SignaturePlaceChoice) -> SignChoices {
        var field: String?
        if case .field(let name) = place.place { field = name }
        var rect: PdfRect?
        if place.place == .box, let box, let viewer {
            rect = viewer.geometry(box.page).toUser(DisplayRect(box.area.x, box.area.y, box.area.width, box.area.height))
        }
        let levels = Self.certifyChoices
        return SignChoices(certificate: certificate, field: field, page: place.place == .box ? box?.page ?? 0 : 0, rect: rect, reason: reason,
                           location: location, certify: levels[min(max(certifyIndex, 0), levels.count - 1)].level,
                           timestampUrl: timestamp ? timestampUrl.trimmingCharacters(in: .whitespaces) : nil, longTerm: longTerm)
    }

    private func sign() async {
        guard let tab, let host, let place else { return }
        let newField: Bool
        if case .field = place.place { newField = false } else { newField = true }
        if let refusal = CertificateSigning.refusal(tab.document, newField: newField) {
            host.showProblem(refusal)
            return
        }
        // The controls can change while the signing waits on a server, so what they say is read now.
        let stamped = timestamp
        let certificate: X509Certificate
        if useKeychain {
            guard let choice = identities.first(where: { $0.id == selectedIdentity }), let held = host.verifyCertificate(choice) else {
                host.showProblem(Problem(L10n.t("Key cannot be used"), L10n.t("The system would not let Lazy PDF use this key. Check the PIN or choose another certificate.")))
                return
            }
            certificate = held
        } else {
            do {
                certificate = try importIdentity(pfx ?? [], pfxPassword)
            } catch {
                host.showProblem(Problem(L10n.t("Certificate not opened"), L10n.t("The .p12 file could not be opened. Check the password and that the file is a .p12.")))
                return
            }
        }
        let picked = choices(certificate, place)
        let fonts = self.fonts
        await run(tab, host, L10n.t("Signing the file"), failedTitle: L10n.t("Not signed"), checksRevocation: picked.longTerm) { session, transport, now, token in
            try CertificateSigning.sign(session, picked, transport, fonts, now, token: token)
        } afterwards: { finished, covered, changed, transport in
            if !changed { return }
            if stamped { self.trust.setTimestampUrl(picked.timestampUrl ?? "") }
            if !finished {
                host.setStatus(L10n.t("Signed without validation data."))
                return
            }
            host.setStatus(L10n.t("File signed."))
            if !covered { self.noProof(host, transport) }
        }
    }

    /// Asks the certificate servers for proof about the signatures the file has and stores it in the file.
    public func addValidation() async {
        guard let tab, let host else { return }
        if let refusal = CertificateSigning.refusal(tab.document, newField: false) {
            host.showProblem(refusal)
            return
        }
        await run(tab, host, L10n.t("Adding validation data"), failedTitle: L10n.t("Validation data not added"), checksRevocation: true) { session, transport, now, token in
            try CertificateSigning.addValidation(session, transport, now, token: token)
        } afterwards: { finished, covered, changed, transport in
            if !finished { return }
            if !changed {
                host.setStatus(L10n.t("Nothing new to add."))
                return
            }
            if covered { host.setStatus(L10n.t("Validation data added.")) } else { self.noProof(host, transport) }
        }
    }

    // Work on the document's own session off the main actor. The panel stays shut while it runs, so nothing else touches the
    // session. A failed step is explained first and the file is read again, then `afterwards` says what came of it.
    private func run(_ tab: DocumentTab, _ host: ToolHost, _ busy: String, failedTitle: String, checksRevocation: Bool,
                     _ job: @escaping @Sendable (PdfEditSession, SignatureTransport, DateTimeOffset, CancelToken) throws -> Void,
                     afterwards: (_ finished: Bool, _ covered: Bool, _ changed: Bool, SigningTransport) -> Void) async {
        let session = tab.session
        let verify = withCertificate(trust.verifyOptions(password: tab.password, now: PanelDates.now()), tab, host)
        let before = session.current.count
        let transport = makeTransport()
        let handoff = JobHandoff()
        var finished = false, covered = true, letGo = false
        working = true
        do {
            try await host.runBusy(busy) { token in
                let ender = Task.detached {
                    while !token.isCancelled && !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
                    if token.isCancelled { transport.cancel() }
                }
                defer { ender.cancel() }
                do {
                    covered = try await ToolDocuments.run(token) {
                        defer { handoff.end() }
                        try job(session, CancellableTransport(transport, token), PanelDates.now(), token)
                        return try checksRevocation ? CertificateSigning.revocationCovered(session.current, verify) : true
                    }
                    finished = true
                } catch is CancellationError {
                    letGo = true
                    // The busy bar stays until the job has stopped using the session, so nothing else edits it meanwhile.
                    await withCheckedContinuation { continuation in handoff.whenEnded { continuation.resume() } }
                    throw CancellationError()
                }
            }
        } catch {
            host.showProblem(Self.failure(error, transport, failedTitle))
        }
        if letGo {
            if !tab.isDisposed { tab.reload() }
            working = false
            return
        }
        working = false
        let changed = session.current.count != before
        if changed { clearBox() }
        if !finished || changed { tab.reload() }
        afterwards(finished, covered, changed, transport)
    }

    private func withCertificate(_ options: VerifyOptions, _ tab: DocumentTab, _ host: ToolHost) -> VerifyOptions {
        var options = options
        if let choice = tab.certificate { options.certificate = host.verifyCertificate(choice) }
        return options
    }

    private func noProof(_ host: ToolHost, _ transport: SigningTransport) {
        host.setStatus(L10n.t("Added without proof of revocation."))
        let advice = L10n.t("The signature may not be checkable after its certificate expires. Add validation data again when the servers answer.")
        host.showNotice(L10n.t("Proof of revocation is missing"), transport.lastFailure.map { $0 + " " + advice } ?? advice, nil)
    }

    // The engine's sentence says what failed; the transport knows why a server could not be reached.
    static func failure(_ error: Error, _ transport: SigningTransport, _ title: String) -> Problem {
        func said(_ message: String) -> Problem {
            Problem(title, transport.lastFailure.map { message + " " + $0 } ?? message)
        }
        switch error {
        case is SignatureCryptoException:
            return Problem(L10n.t("Key cannot be used"), L10n.t("The system would not let Lazy PDF use this key. Check the PIN or choose another certificate."))
        case is PdfReadException:
            return Problem(L10n.t("File cannot be signed"), L10n.t("The file could not be read for signing. Save it under another name and try again."))
        case let error as InvalidOperationException:
            return said(error.message)
        case let error as ArgumentException:
            return said(error.message)
        default:
            return Problem(L10n.t("Something went wrong"), L10n.t("{0} could not be finished. If part of it was done, Undo takes it back.", title))
        }
    }
}
