import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Panels/Signatures/SignaturesSidePanel.xaml.cs and SignaturesSidePanel.Trust.cs.

/// Counts the requests the check makes, since the engine asks only when a chain is missing a certificate that a server could
/// give; a signer with nothing to fetch must not be reported as checked with the servers.
private final class CountingTransport: SigningTransport, @unchecked Sendable {
    private let inner: SigningTransport
    private let lock = NSLock()
    private var count = 0

    init(_ inner: SigningTransport) { self.inner = inner }

    var requests: Int { lock.withLock { count } }
    var lastFailure: String? { inner.lastFailure }
    func cancel() { inner.cancel() }

    func post(_ url: String, _ contentType: String, _ body: [UInt8]) -> [UInt8]? {
        lock.withLock { count += 1 }
        return inner.post(url, contentType, body)
    }

    func get(_ url: String) -> [UInt8]? {
        lock.withLock { count += 1 }
        return inner.get(url)
    }
}

private typealias Found = (reports: [SignatureReport], fields: [String: (page: Int, rect: PdfRect)])

/// The signatures of the file and what the engine found when it checked them. Choosing one shows the field; the details say
/// what changed since, what is wrong and what could not be checked, and offer the signed version of the file.
@MainActor
@Observable
public final class SignaturesModel: ToolPanelModel {
    public private(set) var rows: [SignatureRow] = []

    /// What stands in place of the list: that the check is running, that it failed, or that there is nothing to check.
    public private(set) var note: String?

    public private(set) var selected: Int?

    /// What went wrong with the signed version, shown under its buttons.
    public private(set) var versionProblem: String?

    public private(set) var trustsSystem: Bool
    public private(set) var trusted: [TrustRow]
    public private(set) var trustNote: String?

    /// Shows the signer's certificate without adding it to anything; false when nothing could. The view sets it.
    @ObservationIgnored public var showCertificate: ((X509Certificate) -> Bool)?

    var tab: DocumentTab?
    var viewer: DocumentViewer?
    var host: ToolHost?
    @ObservationIgnored private let trust: SignatureTrust
    @ObservationIgnored private let makeTransport: (() -> SigningTransport)?
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var ticket = 0
    @ObservationIgnored private var asking: SigningTransport?
    private var signedFields: Set<String> = []

    /// `transport`, when given, lets the person ask the servers the certificates name for a certificate the chain lacks.
    public init(trust: SignatureTrust, transport: (() -> SigningTransport)? = nil) {
        self.trust = trust
        makeTransport = transport
        trustsSystem = trust.trustsSystem
        trusted = trust.rows
    }

    public var action: ToolAction? { nil }

    public var selectedRow: SignatureRow? { rows.first { $0.id == selected } }

    public var canViewSigned: Bool { (selectedRow?.hasLaterRevisions ?? false) && !(tab?.document.isEncrypted ?? true) }

    public var canSaveSigned: Bool { selectedRow?.hasLaterRevisions ?? false }

    /// The line under the buttons for the signed version.
    public var versionText: String? {
        if let versionProblem { return versionProblem }
        guard let row = selectedRow else { return nil }
        if !row.hasLaterRevisions { return L10n.t("This is the signed version.") }
        return tab?.document.isEncrypted == true ? L10n.t("A protected file cannot open as a copy. Save the signed version, then open it.") : nil
    }

    /// Whether the picked signature failed only for want of trust in a certificate that the person could add.
    public var canTrustSigner: Bool {
        guard let row = selectedRow, let certificate = row.report.certificate, row.report.problems.contains(.untrustedSigner) else { return false }
        return !trusted.contains { $0.der == Data(certificate.rawData).base64EncodedString() }
    }

    /// Whether the picked signature sits in a signed field of the open file, and the file may be changed.
    public var canClearSignature: Bool {
        guard let tab, let name = selectedRow?.report.fieldName else { return false }
        return signedFields.contains(name) && ChangeGate.refusal(tab.document) == nil
    }

    /// Whether the servers can be asked for the certificates the signer's chain lacks.
    public var canAskServers: Bool {
        makeTransport != nil && (selectedRow?.report.problems.contains(.untrustedSigner) ?? false) && tab?.certificate == nil
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.viewer = viewer
        self.host = host
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.check() })
        showTrust()
        check()
    }

    public func detach() {
        watch?.stop()
        watch = nil
        ticket += 1
        stopAsking()
        rows = []
        selected = nil
        tab = nil
        viewer = nil
        host = nil
    }

    /// Checks the signatures of the file as it is; the task ends when the list is shown.
    @discardableResult
    public func check(online: Bool = false) -> Task<Void, Never> {
        ticket += 1
        stopAsking()
        let mine = ticket
        guard let tab else { return Task {} }
        show([], L10n.t("Checking the signatures"))
        let bytes = tab.session.current
        let password = tab.password
        var options = trust.verifyOptions(password: password, now: PanelDates.now())
        if let choice = tab.certificate {
            // The tab keeps the choice; the key comes from the platform, and without it the file cannot be read.
            guard let certificate = host?.verifyCertificate(choice) else {
                show([], L10n.t("The signatures could not be checked."))
                return Task {}
            }
            options.certificate = certificate
        }
        let transport = online ? makeTransport.map { CountingTransport($0()) } : nil
        options.transport = transport
        asking = transport
        let certificate = options.certificate
        let host = host
        return Task {
            let verify = { () async -> Found? in
                await Task.detached { () -> Found? in
                    do {
                        return (try PdfSignatureVerifier.verify(bytes, options), try SignatureFields.locate(bytes, password, certificate))
                    } catch {
                        return nil
                    }
                }.value
            }
            var found: Found?
            var stopped = false
            if let transport, let host {
                // Cancel ends the request in flight; the engine then fails the fetch and the rest of the check goes on without it.
                try? await host.runBusy(L10n.t("Asking the certificate servers")) { token in
                    let ender = Task.detached {
                        while !token.isCancelled && !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
                        if token.isCancelled { transport.cancel() }
                    }
                    defer { ender.cancel() }
                    found = await verify()
                    stopped = token.isCancelled
                }
            } else {
                found = await verify()
            }
            guard mine == self.ticket, self.tab === tab else { return }
            guard let found else {
                self.show([], L10n.t("The signatures could not be checked."))
                return
            }
            self.signedFields = Self.signedFields(tab)
            self.show(found.reports.map { self.row($0, found.fields) }, found.reports.isEmpty ? L10n.t("This file has no signatures.") : nil)
            self.selected = self.rows.first?.id
            if let transport, !stopped, !found.reports.isEmpty {
                if transport.requests == 0 {
                    self.note = L10n.t("The certificates name no servers to ask.")
                } else {
                    self.note = L10n.t("Checked with the certificate servers just now. The file is not changed.") + (transport.lastFailure.map { " " + $0 } ?? "")
                }
            }
        }
    }

    /// Names the servers the check would ask and checks again, fetching the certificate of an issuer the chain lacks from the
    /// address the certificate names, once the person agrees.
    public func askServers() {
        guard canAskServers, let tab, let host else { return }
        let bytes = tab.session.current
        let password = tab.password
        Task {
            let hosts = await ServerPreview.hosts(bytes, password)
            guard self.tab === tab else { return }
            if hosts.isEmpty {
                self.note = L10n.t("The certificates name no servers to ask.")
                return
            }
            host.showNotice(L10n.t("These servers will be asked"),
                            L10n.t("Lazy PDF will contact {0}. Servers named by certificates found on the way may be asked too. The file itself is not sent.", ServerPreview.describe(hosts)),
                            NoticeAction(L10n.t("Ask them")) { [weak self] in
                if let self, self.tab === tab { self.check(online: true) }
            })
        }
    }

    /// Asks, then adds the picked signature's certificate to those the user trusts.
    public func trustSigner() {
        guard let tab, let host, let row = selectedRow, let certificate = row.report.certificate else { return }
        let der = certificate.rawData
        host.showNotice(L10n.t("Trust {0}?", row.title),
                        L10n.t("Signatures made with this certificate will count as trusted. Check its fingerprint with the signer first. You can remove it under Trust settings."),
                        NoticeAction(L10n.t("Trust")) { [weak self] in
            if let self, self.tab === tab { self.addTrusted(der) }
        })
    }

    /// Asks, then takes the signature out of the picked field so that it can be signed again.
    public func clearSignature() {
        guard canClearSignature, let tab, let host, let row = selectedRow, let name = row.report.fieldName else { return }
        host.showNotice(L10n.t("Clear the signature of {0}?", name), Self.clearText(rows, row),
                        NoticeAction(L10n.t("Clear signature")) { [weak self] in
            if let self, self.tab === tab { self.clear(name) }
        })
    }

    // Taking a value out of a signature field counts as a change to every signature made after it.
    static func clearText(_ rows: [SignatureRow], _ row: SignatureRow) -> String {
        let text = L10n.t("The signature is removed from the field, and the field can be signed again. The file keeps the earlier signed version in its history. Undo brings the signature back.")
        guard rows.contains(where: { $0.report.revision > row.report.revision }) else { return text }
        return text + " " + L10n.t("Signatures made after it will show the file as changed.")
    }

    /// Clears the field as one undoable step; false when nothing changed, which the info bar then explains.
    @discardableResult
    func clear(_ name: String) -> Bool {
        guard let tab, let host else { return false }
        do {
            let form = PdfForm.read(tab.document)
            guard let field = form.find(name) else { throw InvalidOperationException(FormText.notSigned) }
            try form.clearSignature(field)
            return try tab.commit(L10n.t("Clear signature"))
        } catch {
            try? tab.session.discard()
            host.showProblem(FormEdits.problem(of: error))
            return false
        }
    }

    public func select(_ id: Int?) {
        selected = id
        versionProblem = nil
    }

    /// Shows the field of the signature on its page.
    public func go(_ row: SignatureRow) {
        guard row.page >= 0, let area = row.area, let viewer else { return }
        viewer.goToPage(row.page)
        viewer.reveal(row.page, area)
    }

    /// Opens the file as it was when the picked signature closed it, as a copy.
    public func viewSigned() async {
        guard let tab, let host, let row = selectedRow else { return }
        guard let bytes = SignedVersion.of(tab.session.current, row.report) else {
            versionProblem = L10n.t("The signed version is not in the file's history.")
            return
        }
        await host.openNew(bytes, title: L10n.t("{0} (signed by {1})", stem, row.title), password: nil, certificate: nil)
    }

    /// Shows the picked signature's certificate.
    public func viewCertificate() {
        guard let certificate = selectedRow?.report.certificate else { return }
        if showCertificate?(certificate) != true { versionProblem = L10n.t("The certificate could not be shown.") }
    }

    /// What a certificate says about itself, a line each, for a view with no system panel to show it.
    public static func facts(of certificate: X509Certificate) -> [String] {
        let format = DateFormatter()
        format.dateStyle = .medium
        format.timeStyle = .none
        return [
            L10n.t("Issued to {0}", certificate.subject),
            L10n.t("Issued by {0}", certificate.issuer),
            L10n.t("Valid from {0} to {1}", format.string(from: PanelDates.date(certificate.notBefore)), format.string(from: PanelDates.date(certificate.notAfter))),
            L10n.t("Thumbprint {0}", certificate.thumbprint),
        ]
    }

    /// The signed version of the picked signature and the name to offer for it; nil when it is not in the history, which the
    /// note then says.
    public func signedVersionFile() -> (name: String, bytes: [UInt8])? {
        guard let tab, let row = selectedRow else { return nil }
        guard let bytes = SignedVersion.of(tab.session.current, row.report) else {
            versionProblem = L10n.t("The signed version is not in the file's history.")
            return nil
        }
        if tab.certificate == nil, (try? PdfDocument.open(bytes, password: tab.password)) == nil {
            versionProblem = L10n.t("The signed version is not in the file's history.")
            return nil
        }
        return (L10n.t("{0} (signed)", stem) + ".pdf", bytes)
    }

    /// `access` starts the system's grant to read the saved file again, which a file outside the app's folders needs; it
    /// is asked for only when the person chooses to open the file.
    public func signedVersionSaved(_ result: Result<URL, Error>, access: @escaping (URL) -> FileAccess? = { _ in nil }) {
        guard let host else { return }
        switch result {
        case .success(let url):
            if let open = tab?.url, open.standardizedFileURL == url.standardizedFileURL {
                versionProblem = L10n.t("That is the open file. Choose another name.")
                return
            }
            versionProblem = nil
            host.setStatus(L10n.t("Signed version saved."))
            host.showNotice(L10n.t("Signed version saved"), url.lastPathComponent, NoticeAction(L10n.t("Open it"), {
                Task { await host.open(url, access: access(url)) }
            }))
        case .failure:
            versionProblem = L10n.t("The file could not be saved. Check the folder and try again.")
        }
    }

    public func setTrustsSystem(_ on: Bool) {
        trust.setTrustsSystem(on)
        showTrust()
        check()
    }

    /// Adds the certificate in a file to those the user trusts.
    public func addTrusted(_ bytes: [UInt8]) {
        guard trust.add(bytes) else {
            trustNote = L10n.t("That file is not a certificate. Choose a .cer or .crt file.")
            return
        }
        trustNote = nil
        showTrust()
        check()
    }

    public func removeTrusted(_ row: TrustRow) {
        trust.remove(row)
        showTrust()
        check()
    }

    private static func signedFields(_ tab: DocumentTab) -> Set<String> {
        Set(PdfForm.read(tab.document).fields.filter { $0.kind == .signature && $0.isSigned }.map(\.name))
    }

    private var stem: String {
        URL(fileURLWithPath: tab?.title ?? "").deletingPathExtension().lastPathComponent
    }

    private func stopAsking() {
        asking?.cancel()
        asking = nil
    }

    private func showTrust() {
        trustsSystem = trust.trustsSystem
        trusted = trust.rows
    }

    private func show(_ list: [SignatureRow], _ text: String?) {
        rows = list
        selected = nil
        versionProblem = nil
        note = text
    }

    func row(_ report: SignatureReport, _ fields: [String: (page: Int, rect: PdfRect)]) -> SignatureRow {
        guard let name = report.fieldName, let at = fields[name], let viewer, at.page >= 0, at.page < viewer.pageCount else {
            return SignatureRow(report, page: -1, area: nil)
        }
        let box = viewer.geometry(at.page).toDisplay(at.rect)
        return SignatureRow(report, page: at.page, area: ViewRect(box.x, box.y, box.width, box.height))
    }
}
