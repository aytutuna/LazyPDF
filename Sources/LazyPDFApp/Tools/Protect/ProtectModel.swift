import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Protect/ProtectPanel.xaml.cs and ProtectPanel.Recipients.cs: a password to open the file,
// limits on what people may do, or certificates for the people who may open it; or the protection taken off. The result is a
// rewrite, so it opens as a new document and the file in view stays as it was. The passwords live in this object only while the
// panel is on a document; detaching and a finished run clear them.

@MainActor
@Observable
public final class ProtectModel: ToolPanelModel {
    public var mode = ProtectMode.password
    public var limited = false
    public var openPassword = ""
    public var repeatPassword = ""
    public var ownerPassword = ""
    public var unlockPassword = ""
    public var canPrint = true
    public var canPrintSharp = true
    public var canCopy = true
    public var canEdit = true
    public var canAssemble = true
    public var canComment = true
    public var canFill = true
    public var aes128 = false

    public private(set) var recipients: [Recipient] = []

    /// What the keychain offers that is not on the list yet; read when the menu opens.
    public private(set) var storeChoices: [Recipient] = []

    // Bumped when the file changes, so what is derived from it is read again.
    private var fileVersion = 0
    var tab: DocumentTab?
    var host: ToolHost?
    @ObservationIgnored private var watch: ObservationWatch?

    public init() {}

    public var action: ToolAction? {
        let text: String
        switch mode {
        case .remove: text = L10n.t("Remove protection")
        case .certificates: text = L10n.t("Protect for them")
        case .password: text = L10n.t("Protect the file")
        }
        return ToolAction(text, symbol: mode == .remove ? "lock.open" : "lock", canRun: { [self] in canRun }, run: { [self] in await run() })
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.host = host
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.fileChanged() })
        fileChanged()
    }

    public func detach() {
        watch?.stop()
        watch = nil
        clearSecrets()
        recipients = []
        storeChoices = []
        tab = nil
        host = nil
    }

    private func fileChanged() {
        fileVersion += 1
        if !isEncrypted && mode == .remove { mode = .password }
    }

    private func clearSecrets() {
        unlockPassword = ""
        openPassword = ""
        repeatPassword = ""
        ownerPassword = ""
    }

    // MARK: What the file is

    public var isEncrypted: Bool {
        _ = fileVersion
        return tab?.document.isEncrypted ?? false
    }

    public var locked: Bool {
        _ = fileVersion
        return tab.map { ProtectWork.isLockedAgainstChange($0.document) } ?? false
    }

    /// A certificate holder without the right to change the protection has no password to give.
    public var lockedForGood: Bool { locked && tab?.document.security?.isPublicKey == true }

    public var asksForUnlock: Bool { locked && !lockedForGood }

    public var canRun: Bool {
        guard tab != nil, !lockedForGood, !(locked && unlockPassword.isEmpty) else { return false }
        switch mode {
        case .remove: return isEncrypted
        case .certificates: return !recipients.isEmpty
        case .password: return ProtectWork.passwordsAgree(openPassword, repeatPassword, limited: limited, owner: ownerPassword)
        }
    }

    // MARK: What the panel says

    public var stateSymbol: String { locked ? "lock.trianglebadge.exclamationmark" : "lock.shield" }

    public var stateNote: String {
        _ = fileVersion
        guard let document = tab?.document else { return "" }
        if lockedForGood { return L10n.t("Opened with limited rights. Your certificate may not change the protection.") }
        if locked { return L10n.t("Opened with limited rights. Enter its permissions password to change the protection.") }
        if !document.isEncrypted { return L10n.t("This file is not protected.") }
        return document.security?.isPublicKey == true ? L10n.t("Protected for certificate holders.") : L10n.t("Protected with a password.")
    }

    public var warnNote: String {
        _ = fileVersion
        guard let document = tab?.document else { return "" }
        let notes = [document.isSigned ? L10n.t("The copy will not keep the signatures.") : nil,
                     document.pdfAPart != nil && mode != .remove ? L10n.t("The copy will no longer be PDF/A.") : nil]
        return notes.compactMap { $0 }.joined(separator: " ")
    }

    public var limitNote: String {
        mode == .certificates
            ? L10n.t("These limits are a request, not a lock. Some programs ignore them. Only the certificates keep the file private.")
            : L10n.t("These limits are a request, not a lock. Some programs ignore them. Only a password to open keeps the file private.")
    }

    public var strengthNote: String {
        aes128 && (openPassword + ownerPassword).unicodeScalars.contains { $0.value > 0xFF }
            ? L10n.t("Older readers may not accept these letters. Use AES 256-bit.") : ""
    }

    public var strength: PasswordRating { PasswordStrength.rate(openPassword) }

    public var strengthHint: String { PasswordStrength.hint(strength) }

    public var passwordNote: String {
        !repeatPassword.isEmpty && repeatPassword != openPassword ? L10n.t("The passwords do not match.") : ""
    }

    public var ownerNote: String {
        if !limited || mode != .password { return "" }
        if ownerPassword.isEmpty { return L10n.t("Type a Permissions password to apply the limits.") }
        return ownerPassword == openPassword ? L10n.t("Use a different password here.") : ""
    }

    public var recipientNote: String {
        if recipients.isEmpty { return L10n.t("Add at least one certificate.") }
        return recipients.contains { $0.hasPrivateKey } ? ""
            : L10n.t("None of these has its key on this computer. You could not open the copy. Add your own certificate too.")
    }

    // Adding comments always allows filling in forms.
    public var fillForms: Bool { canComment || canFill }

    public func choices() -> PermissionChoices {
        !limited ? .everything
            : PermissionChoices(print: canPrint, printHighQuality: canPrintSharp, copy: canCopy, edit: canEdit, comment: canComment,
                                fillForms: fillForms, assemble: canAssemble)
    }

    // MARK: Recipients

    public func add(_ recipient: Recipient) {
        if recipients.contains(where: { $0.thumbprint == recipient.thumbprint }) { return }
        recipients.append(recipient)
    }

    public func remove(_ recipient: Recipient) {
        recipients.removeAll { $0.thumbprint == recipient.thumbprint }
    }

    public func refreshStore() {
        #if canImport(Security)
        storeChoices = RecipientSource.fromStore().filter { found in !recipients.contains { $0.thumbprint == found.thumbprint } }
        #endif
    }

    public func addFromFiles() async {
        guard let host else { return }
        for file in await host.filePicker.pickFiles([.any], multiple: true) {
            defer { file.access?.stop() }
            #if canImport(Security)
            if let data = try? Data(contentsOf: file.url), let recipient = RecipientSource.fromFile([UInt8](data)) {
                add(recipient)
                continue
            }
            #endif
            host.showProblem(Problem(L10n.t("Not a usable certificate"),
                                     L10n.t("{0} is not an RSA certificate. Ask for the person's certificate file.", file.url.lastPathComponent)))
        }
    }

    // MARK: The run

    private func run() async {
        guard let tab, let host else { return }
        let mode = self.mode
        let allowed = choices().toPermissions()
        let open = openPassword
        let owner = limited ? ownerPassword : open
        let strength: PdfCryptStrength = aes128 ? .aes128 : .aes256
        let list = recipients
        let file = tab.session.current
        let wasLocked = locked
        let password = wasLocked ? unlockPassword : tab.password
        let certificate = tab.certificate.flatMap { host.verifyCertificate($0) }
        let name = (tab.title as NSString).deletingPathExtension

        var outcome: ProtectOutcome?
        var lockedOut = false
        do {
            try await host.runBusy(mode == .remove ? L10n.t("Removing protection") : L10n.t("Protecting the file")) { token in
                do {
                    outcome = try await ToolDocuments.run(token) {
                        try ProtectJob.run(file, password: password, certificate: certificate, locked: wasLocked, mode: mode,
                                           openPassword: open, ownerPassword: owner, allowed: allowed, strength: strength,
                                           recipients: list, token: token)
                    }
                } catch is PdfPermissionException {
                    lockedOut = true
                }
            }
        } catch {
            host.showProblem(Problem(L10n.t("Could not protect the file"), L10n.t("The file could not be rewritten. Save a copy, then protect that.")))
            return
        }
        if lockedOut {
            host.showProblem(Problem(L10n.t("Protection is locked"), L10n.t("Enter the permissions password, then try again.")))
            return
        }
        guard let outcome else { return }
        guard case .made(let bytes, let opener) = outcome else {
            host.showProblem(Problem(L10n.t("Wrong password"), L10n.t("That is not the permissions password. Check it and try again.")))
            return
        }

        let title = "\(name) \(mode == .remove ? L10n.t("unprotected") : L10n.t("protected")).pdf"
        if mode == .certificates && opener == nil {
            if !(await saveCopy(host, bytes, title)) { return }
            host.setStatus(L10n.t("Protected copy saved."))
            host.showNotice(L10n.t("Copy for the others"), L10n.t("You cannot open it here. Send it to the people you chose."), nil)
        } else {
            let choice = opener.flatMap { X509Certificate($0) }.map { CertificateChoice($0) }
            await host.openNew(bytes, title: title, password: mode == .password && !open.isEmpty ? open : nil, certificate: choice)
            host.setStatus(mode == .remove ? L10n.t("Protection removed from a copy.") : L10n.t("Protected copy made."))
            host.showNotice(mode == .remove ? L10n.t("Copy without protection") : L10n.t("Copy with protection"),
                            L10n.t("The original is unchanged. Save the copy to keep it."), nil)
        }
        clearSecrets()
    }

    // The copy is for other people's keys, so it cannot be a tab here: nobody could open it. It is written to a folder of its
    // own, handed to the exporter and removed again.
    private func saveCopy(_ host: ToolHost, _ bytes: [UInt8], _ title: String) async -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(title)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(bytes).write(to: file)
        } catch {
            host.showProblem(Problems.save(error, title))
            return false
        }
        return !(await host.fileExporter.export([file])).isEmpty
    }
}
