import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Create/CreatePanel.xaml.cs: makes a new document from blank pages, pictures, text or the
// pasteboard and opens it in a tab of its own. It is not tied to a document, so the Home tile presents it in a sheet and the
// tool strip shows it beside the document in view; the pictures chosen are kept with their grants while they are listed.

public enum CreateFrom: Int, CaseIterable { case blank, pictures, text, office, clipboard, webPage }

public enum CreatePaper: String, Codable, Equatable { case a4, a3, a5, letter, legal, custom, picture }

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
    public private(set) var webPage: ToolFile?
    public var typedText = ""
    public private(set) var officeFile: ToolFile?
    public private(set) var clipboard = ClipboardKind.nothing
    public private(set) var fileProblem: String?
    public var paper = CreatePaper.a4 {
        didSet { if !fitting { chosen = paper } }
    }
    public var orientation = CreateOrientation.automatic
    public var margin = 36.0
    public var fontSize = 11.0
    public var customWidth = ""
    public var customHeight = ""

    @ObservationIgnored var host: ToolHost?
    @ObservationIgnored private let codec: ImageCodec
    @ObservationIgnored private let fonts: FontSource?
    @ObservationIgnored private let web: WebPageRenderer?
    @ObservationIgnored private let settings: URL?
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private var chosen = CreatePaper.a4
    @ObservationIgnored private var fitting = false

    /// Whether the custom size is typed in millimeters or inches.
    @ObservationIgnored public let metric: Bool

    /// With a settings folder the paper and custom size are read from it now and saved when a file is made.
    public init(host: ToolHost?, codec: ImageCodec, fonts: FontSource?, settings: URL? = nil, web: WebPageRenderer? = nil,
                metric: Bool = Locale.current.measurementSystem == .metric, locale: Locale = .current) {
        self.host = host
        self.codec = codec
        self.fonts = fonts
        self.settings = settings
        self.web = web
        self.metric = metric
        self.locale = locale
        let saved = settings.map { AppPreferencesStore.load($0) } ?? AppPreferences()
        chosen = saved.createPaper
        customWidth = shown(saved.createWidth > 0 ? saved.createWidth : metric ? 210 * PageEdits.pointsPerMillimetre : 612)
        customHeight = shown(saved.createHeight > 0 ? saved.createHeight : metric ? 297 * PageEdits.pointsPerMillimetre : 792)
        fitPaper()
    }

    public var unit: String { metric ? "mm" : "in" }

    private var pointsPerUnit: Double { metric ? PageEdits.pointsPerMillimetre : 72 }

    private func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? ""
    }

    private func shown(_ points: Double) -> String { number(points / pointsPerUnit) }

    // The page sides the engine accepts, in points.
    private static let leastSide = 3.0
    private static let mostSide = 14400.0

    /// The custom size in points; nil while it is not a number within what a page can be.
    private var customPoints: (width: Double, height: Double)? {
        guard let width = PageEdits.number(customWidth, locale: locale), let height = PageEdits.number(customHeight, locale: locale) else { return nil }
        let w = (width * pointsPerUnit * 1000).rounded() / 1000, h = (height * pointsPerUnit * 1000).rounded() / 1000
        let sides = Self.leastSide...Self.mostSide
        return sides.contains(w) && sides.contains(h) ? (w, h) : nil
    }

    private var customFits: Bool { paper != .custom || customPoints != nil }

    private var sizeLimits: String {
        let least = (Self.leastSide / pointsPerUnit * 100).rounded(.up) / 100
        let most = (Self.mostSide / pointsPerUnit * 100).rounded() / 100
        return L10n.t("Type a size from {0} to {1} {2}.", number(least), number(most), unit)
    }

    // The paper of the picture only exists for pictures, but it is remembered for when pictures come back.
    private func fitPaper() {
        fitting = true
        paper = chosen == .picture && !makesPictures ? .a4 : chosen
        fitting = false
    }

    public var blankCount: Int? {
        guard let pages = Int(blankPages.trimmingCharacters(in: .whitespaces)), (1...PdfMaker.mostBlankPages).contains(pages) else { return nil }
        return pages
    }

    public var makesPictures: Bool { from == .pictures || (from == .clipboard && clipboard == .picture) }

    public var makesText: Bool { from == .text || (from == .clipboard && clipboard == .text) }

    public var canRun: Bool {
        switch from {
        case .blank: return blankCount != nil && customFits
        case .pictures: return !pictures.isEmpty && customFits
        case .text: return !typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && customFits
        case .office: return officeFile != nil
        case .clipboard: return clipboard != .nothing && customFits
        case .webPage: return webPage != nil && customFits
        }
    }

    public var blocker: String? {
        if let fileProblem { return fileProblem }
        if from == .blank && blankCount == nil { return L10n.t("Type a number from 1 to {0}.", PdfMaker.mostBlankPages) }
        return showsSetup && !customFits ? sizeLimits : nil
    }

    public var clipboardState: String {
        switch clipboard {
        case .text: return L10n.t("The clipboard holds text.")
        case .picture: return L10n.t("The clipboard holds a picture.")
        case .nothing: return L10n.t("Copy text or a picture, then come back.")
        }
    }

    public var showsSetup: Bool { from == .clipboard ? clipboard != .nothing : from != .office }
    public var showsMargin: Bool { from != .blank }
    public var offersWebPage: Bool { web != nil }
    public var orientationEnabled: Bool { paper != .picture }
    public var showsCustomSize: Bool { showsSetup && paper == .custom }

    public func choose(_ from: CreateFrom) {
        self.from = from
        fileProblem = nil
        peekClipboard()
    }

    public func peekClipboard() {
        clipboard = from == .clipboard ? host.map { $0.clipboard.kind() } ?? .nothing : .nothing
        fitPaper()
    }

    public func inputChanged() {
        fileProblem = nil
    }

    /// The files dropped on the panel: a web page becomes the source, otherwise the pictures are added to the list.
    public func drop(_ files: [ToolFile]) {
        if offersWebPage, let page = files.first(where: { FileKinds.isWebPage($0.url) }) {
            for file in files where file.url != page.url { file.access?.stop() }
            webPage?.access?.stop()
            webPage = page
            fileProblem = nil
            from = .webPage
            fitPaper()
            return
        }
        let kinds = ["jpg", "jpeg", "png", "tif", "tiff", "bmp", "gif", "heic", "heif"]
        let pictures = files.filter { kinds.contains($0.url.pathExtension.lowercased()) }
        for file in files where !pictures.contains(where: { $0.url == file.url }) { file.access?.stop() }
        if pictures.isEmpty {
            host?.setStatus(L10n.t("Only picture files can be added."))
            return
        }
        from = .pictures
        fitPaper()
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

    public func chooseOffice() async {
        guard let host, let file = await host.filePicker.pickFiles([.office], multiple: false).first else { return }
        officeFile?.access?.stop()
        officeFile = file
        fileProblem = nil
    }

    public func pickWebPage() async {
        guard let host, let file = await host.filePicker.pickFiles([.webPage], multiple: false).first else { return }
        webPage?.access?.stop()
        webPage = file
        fileProblem = nil
    }

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

    // The engine turns a custom size to portrait under Automatic, so a wide size typed for a blank or text page is sent as landscape.
    private func pageSetup(pictures: Bool = false) -> PdfPageSetup {
        let sheet: PdfPaper = switch paper {
        case .a4: .a4
        case .a3: .a3
        case .a5: .a5
        case .letter: .letter
        case .legal: .legal
        case .custom: .custom
        case .picture: .picture
        }
        let size = customPoints ?? (595.276, 841.89)
        let turn: PdfOrientation = switch orientation {
        case .automatic: paper == .custom && !pictures ? (size.0 > size.1 ? .landscape : .portrait) : .auto
        case .portrait: .portrait
        case .landscape: .landscape
        }
        return PdfPageSetup(paper: sheet, orientation: turn, margin: from == .blank ? 36 : margin, customWidth: size.0, customHeight: size.1)
    }

    /// What the model is set to make; nil when the pasteboard emptied since it was looked at.
    public func request() -> CreateRequest? {
        let setup = pageSetup(pictures: from == .pictures)
        remember()
        switch from {
        case .blank:
            return CreateRequest(.blank, setup, L10n.t("Blank.pdf"), pages: blankCount ?? 1)
        case .pictures:
            let title = pictures.count == 1 ? (pictures[0].name as NSString).deletingPathExtension + ".pdf" : L10n.t("Pictures.pdf")
            return CreateRequest(.pictures, setup, title, files: pictures.map { $0.file.url })
        case .text:
            return CreateRequest(.text, setup, L10n.t("Text.pdf"), text: typedText, fontSize: fontSize)
        case .office:
            guard let url = officeFile?.url else { return nil }
            return CreateRequest(.office, setup, (url.lastPathComponent as NSString).deletingPathExtension + ".pdf", files: [url])
        case .clipboard:
            let content = host.map { ClipboardContent.read($0.clipboard) }
            if let text = content?.text { return CreateRequest(.text, setup, L10n.t("Clipboard.pdf"), text: text, fontSize: fontSize) }
            if let picture = content?.picture { return CreateRequest(.pictures, pageSetup(pictures: true), L10n.t("Clipboard.pdf"), picture: picture) }
            peekClipboard()
            return nil
        case .webPage:
            guard let page = webPage else { return nil }
            return CreateRequest(.web, setup, (page.url.lastPathComponent as NSString).deletingPathExtension + ".pdf", files: [page.url])
        }
    }

    private func remember() {
        guard let settings else { return }
        let size = customPoints
        AppPreferencesStore.update(settings) {
            $0.createPaper = chosen
            if let size { ($0.createWidth, $0.createHeight) = size }
        }
    }

    /// Makes the document of `request` and opens it in a new tab.
    public func create(_ request: CreateRequest) async {
        guard let host else { return }
        await ChangeGate.guardedAsync(host, L10n.t("Create")) { [codec, fonts, web] in
            try await CreateJob.run(host, codec, fonts, request, web: web)
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

    public init(codec: ImageCodec, fonts: FontSource?, settings: URL? = nil, web: WebPageRenderer? = nil) {
        create = CreateModel(host: nil, codec: codec, fonts: fonts, settings: settings, web: web)
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
