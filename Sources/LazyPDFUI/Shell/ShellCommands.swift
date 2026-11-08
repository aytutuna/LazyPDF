#if canImport(SwiftUI)
import Foundation
import LazyPDFApp

/// What the window asks of the platform shell because it needs a system panel or a security-scoped grant: choosing files,
/// naming a copy, printing. The shell starts access to a chosen file before it opens it, as AppViewModel.open expects.
public struct ShellCommands {
    public var open: @MainActor () -> Void
    public var create: @MainActor () -> Void
    public var batch: @MainActor () -> Void

    /// Asks for a name and saves the tab there; true when it was saved.
    public var saveAs: @MainActor (DocumentTab) async -> Bool
    public var saveCompact: @MainActor (DocumentTab) -> Void
    /// Shows the system's print dialog for the tab, once Lazy Print has not taken it (AppViewModel.print).
    public var print: @MainActor (DocumentTab) -> Void

    /// Hands the tab's current file to the share sheet; nil where the platform has none.
    public var share: (@MainActor (DocumentTab) -> Void)?

    /// Chooses a .p12 or .pfx, imports it through PdfDigitalId into the keychain and returns the identity; nil when the
    /// person gave up. The password question offers it for a file encrypted for recipients.
    public var importCertificate: (@MainActor () async -> CertificateChoice?)?

    /// Opens files dropped on the window; nil lets the window open them without a grant of their own.
    public var openFiles: (@MainActor ([URL]) -> Void)?

    public init(open: @escaping @MainActor () -> Void = {}, create: @escaping @MainActor () -> Void = {},
                batch: @escaping @MainActor () -> Void = {}, saveAs: @escaping @MainActor (DocumentTab) async -> Bool = { _ in false },
                saveCompact: @escaping @MainActor (DocumentTab) -> Void = { _ in },
                print: @escaping @MainActor (DocumentTab) -> Void = { _ in },
                share: (@MainActor (DocumentTab) -> Void)? = nil,
                importCertificate: (@MainActor () async -> CertificateChoice?)? = nil,
                openFiles: (@MainActor ([URL]) -> Void)? = nil) {
        self.open = open
        self.create = create
        self.batch = batch
        self.saveAs = saveAs
        self.saveCompact = saveCompact
        self.print = print
        self.share = share
        self.importCertificate = importCertificate
        self.openFiles = openFiles
    }
}
#endif
