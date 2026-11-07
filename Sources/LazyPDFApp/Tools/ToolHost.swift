import Foundation
import LazyPDFKit

// Twins of windows/LazyPDF.App/Tools/IToolHost.cs and ToolPanel.cs.

/// The pinned button under a tool's panel: what it does, when it can, and what it runs. `symbol` is an SF Symbol name;
/// `hint` is one sentence on what the button does, shown as its help and read out with it.
public struct ToolAction {
    public let text: String
    public let symbol: String
    public let canRun: @MainActor () -> Bool
    public let run: @MainActor () async -> Void
    public let hint: String?

    public init(_ text: String, symbol: String, hint: String? = nil, canRun: @escaping @MainActor () -> Bool,
                run: @escaping @MainActor () async -> Void) {
        self.text = text
        self.symbol = symbol
        self.hint = hint
        self.canRun = canRun
        self.run = run
    }
}

/// What a tool panel can ask of the window besides the document and the viewer: the busy bar, the info bar, the status
/// line and new tabs.
@MainActor
public protocol ToolHost: AnyObject {
    /// Runs `work` with the busy bar showing `text` and a Cancel that ends it through the token.
    func runBusy(_ text: String, _ work: @MainActor (CancelToken) async throws -> Void) async throws

    /// Changes the text of the busy bar while `runBusy` runs, for a step count.
    func setBusyText(_ text: String)

    func showProblem(_ problem: Problem)
    func showNotice(_ title: String, _ text: String, _ action: NoticeAction?)
    func setStatus(_ sentence: String)

    /// Opens a file in a tab, or shows the tab it is already in.
    func open(_ url: URL, access: FileAccess?) async

    /// Opens PDF bytes as a new document with unsaved changes and no file, so saving asks for a name: the result of
    /// Combine, Compare, Export or Create. The password or certificate of encrypted bytes is kept for the tab.
    func openNew(_ pdf: [UInt8], title: String, password: String?, certificate: CertificateChoice?) async

    /// Reads the tab's file from disk again and puts it in the tab's place, after a tool wrote the file; false when the
    /// tab was not replaced, and the info bar says why.
    func tryReload(_ tab: DocumentTab) async -> Bool

    /// Opens the Certificates tool with the empty signature field of that name chosen as the place to sign.
    func openSigning(_ field: String)

    /// The field `openSigning` named, once: the tool asks for it when it is shown.
    func takeSigningField() -> String?

    /// True while a tool changes the document off the main actor and nothing else may touch it.
    var isDocumentBusy: Bool { get }

    /// The certificate of an identity the file was opened with, as the engine checks signatures with it; nil when the
    /// platform cannot give it.
    func verifyCertificate(_ choice: CertificateChoice) -> X509Certificate?
}

extension ToolHost {
    public func openSigning(_ field: String) {}

    public func takeSigningField() -> String? { nil }

    public var isDocumentBusy: Bool { false }

    public func verifyCertificate(_ choice: CertificateChoice) -> X509Certificate? { nil }
}

/// A tool's panel in the inspector, or a side panel on the rail: the state behind its view. The shell attaches it when
/// the panel is shown for a document and detaches it when the panel goes or the document changes. The class behind it
/// is `@Observable`, so the shell follows `action`.
@MainActor
public protocol ToolPanelModel: AnyObject {
    /// The accent button pinned under the panel; nil when the tool has none.
    var action: ToolAction? { get }

    func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost)
    func detach()
}

extension AppViewModel: ToolHost {}
