import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Create/CreatePanel.xaml.cs: makes a new document from blank pages, pictures, text or the
// pasteboard and opens it in a tab of its own. It is not tied to a document, so the Home tile presents it in a sheet and the
// tool strip shows it beside the document in view; the pictures chosen are kept with their grants while they are listed.

public enum CreateFrom: Int, CaseIterable { case blank, pictures, text, clipboard }

public enum CreatePaper: Equatable { case a4, letter, picture }

public enum CreateOrientation: Equatable { case automatic, portrait, landscape }

/// One picture in the list. Its grant is stopped when it is removed from the list, or when the grant itself goes.
public struct CreatePicture: Identifiable {
    public let id = UUID()
    public let file: ToolFile

    public var name: String { file.url.lastPathComponent }
}

@MainActor
@Observable
public final class CreateModel {
    public static let margins: [Double] = [0, 18, 36, 72]
    public static let fontSizes: [Double] = [9, 10, 11, 12, 14, 18]

    public private(set) var from = CreateFrom.blank
    public var blankPages = "1"
    public private(set) var pictures: [CreatePicture] = []
    public var selection: UUID?
    public var typedText = ""
    public private(set) var clipboard = ClipboardKind.nothing
    public private(set) var fileProblem: String?
    public var paper = CreatePaper.a4
    public var orientation = CreateOrientation.automatic
    public var margin = 36.0
    public var fontSize = 11.0

    @ObservationIgnored var host: ToolHost?
    @ObservationIgnored private let codec: ImageCodec
    @ObservationIgnored private let fonts: FontSource?

    public init(host: ToolHost?, codec: ImageCodec, fonts: FontSource?) {
        self.host = host
        self.codec = codec
        self.fonts = fonts
    }

    public var blankCount: Int? {
        guard let pages = Int(blankPages.trimmingCharacters(in: .whitespaces)), (1...PdfMaker.mostBlankPages).contains(pages) else { return nil }
        return pages
    }

    public var makesPictures: Bool { from == .pictures || (from == .clipboard && clipboard == .picture) }

    public var makesText: Bool { from == .text || (from == .clipboard && clipboard == .text) }

    public var canRun: Bool {
        switch from {
        case .blank: return blankCount != nil
        case .pictures: return !pictures.isEmpty
        case .text: return !typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .clipboard: return clipboard != .nothing
        }
    }

    public var blocker: String? {
        fileProblem ?? (from == .blank && blankCount == nil ? L10n.t("Type a number from 1 to {0}.", PdfMaker.mostBlankPages) : nil)
    }

    public var clipboardState: String {
        switch clipboard {
        case .text: return L10n.t("The clipboard holds text.")
        case .picture: return L10n.t("The clipboard holds a picture.")
        case .nothing: return L10n.t("Copy text or a picture, then come back.")
        }
    }

    public var showsSetup: Bool { from != .clipboard || clipboard != .nothing }
    public var showsMargin: Bool { from != .blank }
    public var orientationEnabled: Bool { paper != .picture }

    public func choose(_ from: CreateFrom) {
        self.from = from
        fileProblem = nil
        peekClipboard()
    }

    public func peekClipboard() {
        clipboard = from == .clipboard ? host.map { $0.clipboard.kind() } ?? .nothing : .nothing
        if !makesPictures && paper == .picture { paper = .a4 }
    }

    public func inputChanged() {
        fileProblem = nil
    }

    /// The files dropped on the panel: the pictures are added to the list.
    public func drop(_ files: [ToolFile]) {
        let kinds = ["jpg", "jpeg", "png", "tif", "tiff", "bmp", "gif", "heic", "heif"]
        let pictures = files.filter { kinds.contains($0.url.pathExtension.lowercased()) }
        for file in files where !pictures.contains(where: { $0.url == file.url }) { file.access?.stop() }
        if pictures.isEmpty {
            host?.setStatus(L10n.t("Only picture files can be added."))
            return
        }
        from = .pictures
        for file in pictures { self.pictures.append(CreatePicture(file: file)) }
    }

    public func addPictures() async {
        guard let host else { return }
        for file in await host.filePicker.pickFiles([.picture], multiple: true) { pictures.append(CreatePicture(file: file)) }
    }

    public func removeSelected() {
        guard let at = pictures.firstIndex(where: { $0.id == selection }) else { return }
        pictures.remove(at: at).file.access?.stop()
        selection = pictures.isEmpty ? nil : pictures[min(at, pictures.count - 1)].id
    }

    public func move(_ step: Int) {
        guard let at = pictures.firstIndex(where: { $0.id == selection }), pictures.indices.contains(at + step) else { return }
        pictures.swapAt(at, at + step)
    }

    public var canMoveUp: Bool { pictures.firstIndex(where: { $0.id == selection }).map { $0 > 0 } ?? false }

    public var canMoveDown: Bool { pictures.firstIndex(where: { $0.id == selection }).map { $0 < pictures.count - 1 } ?? false }

    public func openTextFile() async {
        guard let host, let file = await host.filePicker.pickFiles([.text], multiple: false).first else { return }
        defer { file.access?.stop() }
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > TextFiles.mostBytes {
                fileProblem = L10n.t("That file is too big. Pick a text file under 1 MB.")
            } else {
                fileProblem = nil
                typedText = TextFiles.decode([UInt8](try Data(contentsOf: file.url)))
            }
        } catch {
            fileProblem = L10n.t("That file could not be read. Check that no other program has it open.")
        }
    }

    private var setup: PdfPageSetup {
        let sheet: PdfPaper = switch paper {
        case .a4: .a4
        case .letter: .letter
        case .picture: .picture
        }
        let turn: PdfOrientation = switch orientation {
        case .automatic: .auto
        case .portrait: .portrait
        case .landscape: .landscape
        }
        return PdfPageSetup(paper: sheet, orientation: turn, margin: from == .blank ? 36 : margin)
    }

    /// What the model is set to make; nil when the pasteboard emptied since it was looked at.
    public func request() -> CreateRequest? {
        let setup = setup
        switch from {
        case .blank:
            return CreateRequest(.blank, setup, L10n.t("Blank.pdf"), pages: blankCount ?? 1)
        case .pictures:
            let title = pictures.count == 1 ? (pictures[0].name as NSString).deletingPathExtension + ".pdf" : L10n.t("Pictures.pdf")
            return CreateRequest(.pictures, setup, title, files: pictures.map { $0.file.url })
        case .text:
            return CreateRequest(.text, setup, L10n.t("Text.pdf"), text: typedText, fontSize: fontSize)
        case .clipboard:
            let content = host.map { ClipboardContent.read($0.clipboard) }
            if let text = content?.text { return CreateRequest(.text, setup, L10n.t("Clipboard.pdf"), text: text, fontSize: fontSize) }
            if let picture = content?.picture { return CreateRequest(.pictures, setup, L10n.t("Clipboard.pdf"), picture: picture) }
            peekClipboard()
            return nil
        }
    }

    /// Makes the document of `request` and opens it in a new tab.
    public func create(_ request: CreateRequest) async {
        guard let host else { return }
        await ChangeGate.guardedAsync(host, L10n.t("Create")) { [codec, fonts] in
            try await CreateJob.run(host, codec, fonts, request)
        }
    }

    /// The pinned button and the sheet's Create button: makes what the model is set to, or says the pasteboard is empty.
    public func run() async {
        guard let host else { return }
        guard let request = request() else {
            host.showProblem(Problem(L10n.t("Clipboard is empty"), L10n.t("Copy text or a picture, then try again.")))
            return
        }
        await create(request)
    }
}

/// The Create tool of the strip: the same model as the sheet, attached to the document in view.
@MainActor
@Observable
public final class CreatePanelModel: ToolPanelModel {
    public let create: CreateModel

    public init(codec: ImageCodec, fonts: FontSource?) {
        create = CreateModel(host: nil, codec: codec, fonts: fonts)
    }

    public var action: ToolAction? {
        ToolAction(L10n.t("Create"), symbol: "doc.badge.plus", canRun: { [self] in create.canRun }, run: { [self] in await create.run() })
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        create.host = host
        create.peekClipboard()
    }

    public func detach() {
        create.host = nil
    }
}
