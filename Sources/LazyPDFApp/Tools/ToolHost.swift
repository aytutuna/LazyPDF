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

    /// The system's panels for choosing files and folders to read, the shell's own.
    var filePicker: ToolFilePicker { get }

    /// Where finished files go: the save panel, or the document picker on iOS.
    var fileExporter: ToolFileExporter { get }

    var clipboard: ToolClipboard { get }

    /// The installed fonts and the picture reader the engine's editors take when they add text or pictures; nil where the
    /// platform has none.
    var fontSource: FontSource? { get }
    var imageCodec: ImageCodec? { get }

    /// How a tool writes a file that is open in a tab, over the file itself.
    var fileWriter: FileWriter { get }

    /// Puts the stage view of the tool's panel (`ToolPanel.stage`) where the pages are, or gives the pages back. The window
    /// gives them back by itself when the panel goes.
    func holdStage(_ on: Bool)
}

extension ToolHost {
    public func openSigning(_ field: String) {}

    public func takeSigningField() -> String? { nil }

    public var isDocumentBusy: Bool { false }

    public func verifyCertificate(_ choice: CertificateChoice) -> X509Certificate? { nil }

    public var filePicker: ToolFilePicker { NoToolServices.shared }

    public var fileExporter: ToolFileExporter { NoToolServices.shared }

    public var clipboard: ToolClipboard { NoToolServices.shared }

    public var fontSource: FontSource? { nil }

    public var imageCodec: ImageCodec? { nil }

    public var fileWriter: FileWriter { PlainFileWriter() }

    public func holdStage(_ on: Bool) {}
}

/// A kind of file a panel offers.
public enum ToolFileKind: Sendable {
    case pdf, picture, text
    /// A .p12 or .pfx identity.
    case certificate
    case any
}

/// A file or folder the person chose, with the grant the system gave for it, which the caller stops when it is done.
public struct ToolFile {
    public let url: URL
    public let access: FileAccess?

    public init(url: URL, access: FileAccess? = nil) {
        self.url = url
        self.access = access
    }
}

/// Create, Batch, Combine and Compare choose files and folders to read.
@MainActor
public protocol ToolFilePicker: AnyObject {
    /// Files of those kinds; empty when the person gave up.
    func pickFiles(_ kinds: [ToolFileKind], multiple: Bool) async -> [ToolFile]

    /// A folder; nil when the person gave up.
    func pickFolder() async -> ToolFile?
}

/// Export and Batch hand over files they wrote.
@MainActor
public protocol ToolFileExporter: AnyObject {
    /// Takes finished files, written to a folder of the app's own, to where the person says: a name for one file, a folder
    /// for several. The urls of the saved copies; empty when the person gave up.
    func export(_ files: [URL]) async -> [URL]
}

/// Create takes a picture or text from the pasteboard.
@MainActor
public protocol ToolClipboard: AnyObject {
    /// The bytes of a picture on the pasteboard, as a PNG or TIFF file.
    func pictureFile() -> [UInt8]?

    func text() -> String?
}

/// The services of a platform that has none of them: nobody is chosen, nothing is saved, the pasteboard is empty.
@MainActor
public final class NoToolServices: ToolFilePicker, ToolFileExporter, ToolClipboard {
    public static let shared = NoToolServices()

    public func pickFiles(_ kinds: [ToolFileKind], multiple: Bool) async -> [ToolFile] { [] }
    public func pickFolder() async -> ToolFile? { nil }
    public func export(_ files: [URL]) async -> [URL] { [] }
    public func pictureFile() -> [UInt8]? { nil }
    public func text() -> String? { nil }
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

    /// Puts text that is still being typed into the document; the window calls it before it saves, undoes, closes or asks
    /// about unsaved changes. False when the text waits for an answer and the caller must not go on as if it were kept.
    func handIn() -> Bool
}

extension ToolPanelModel {
    public func handIn() -> Bool { true }
}

extension AppViewModel: ToolHost {
    public var fontSource: FontSource? { opener.fonts }

    public var imageCodec: ImageCodec? { opener.codec }
}
