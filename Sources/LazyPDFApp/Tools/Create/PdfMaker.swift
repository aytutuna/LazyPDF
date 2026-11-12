import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Create/PdfMaker.cs, CreateJob.cs and CreateProblems.cs.

public enum CreateSource { case blank, pictures, text, web, office }

/// `files` are picture files to read, in page order, or the one Office file; `picture` is one already in memory that stands for them: the pasteboard's.
public struct CreateRequest {
    public var source: CreateSource
    public var setup: PdfPageSetup
    public var title: String
    public var pages: Int
    public var files: [URL]
    public var picture: [UInt8]?
    public var text: String
    public var fontSize: Double

    public init(_ source: CreateSource, _ setup: PdfPageSetup, _ title: String, pages: Int = 1, files: [URL] = [], picture: [UInt8]? = nil,
                text: String = "", fontSize: Double = 11) {
        self.source = source
        self.setup = setup
        self.title = title
        self.pages = pages
        self.files = files
        self.picture = picture
        self.text = text
        self.fontSize = fontSize
    }
}

/// `unreadable` counts the pictures that could not be read, or the letters the font lacks; `tooLarge` the picture frames
/// too big to decode that were left out.
public struct MadePdf {
    public let bytes: [UInt8]
    public let pages: Int
    public let unreadable: Int
    public let tooLarge: Int
    /// True when a web page named parts from the internet that were left out.
    public let leftOutRemote: Bool

    /// What an Office file had that the converter left out.
    public let skipped: [SkippedFeature]

    init(bytes: [UInt8], pages: Int, unreadable: Int, tooLarge: Int = 0, leftOutRemote: Bool = false, skipped: [SkippedFeature] = []) {
        self.bytes = bytes
        self.pages = pages
        self.unreadable = unreadable
        self.tooLarge = tooLarge
        self.leftOutRemote = leftOutRemote
        self.skipped = skipped
    }
}

public enum PdfMaker {
    public static let mostBlankPages = 500
    public static let mostOfficeBytes = 100 << 20

    /// The engine calls stop through the task `ToolDocuments.run` cancels; the token is also looked at between the files read.
    public static func make(_ request: CreateRequest, _ codec: ImageCodec, _ fonts: FontSource?, _ token: CancelToken = CancelToken()) throws -> MadePdf {
        switch request.source {
        case .blank:
            // A form feed ends a page, so n of them make n empty pages.
            let blank = try PdfFromText.create(String(repeating: "\u{0C}", count: request.pages), fonts: fonts, setup: request.setup)
            return MadePdf(bytes: blank.bytes, pages: blank.pages, unreadable: 0)
        case .pictures:
            let files: [[UInt8]]
            if let picture = request.picture {
                files = [picture]
            } else {
                files = try request.files.map { file in
                    try token.throwIfCancelled()
                    return [UInt8](try Data(contentsOf: file))
                }
            }
            let pictures = try PdfFromPictures.create(files, codec, request.setup)
            return MadePdf(bytes: pictures.bytes, pages: pictures.pages, unreadable: pictures.unreadable.count, tooLarge: pictures.skippedFrames)
        case .office:
            let url = request.files[0]
            try token.throwIfCancelled()
            if FileKinds.isOldOffice(url) { throw PdfReadException(.unsupported, "The file is in an older Office format.") }
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > mostOfficeBytes { throw PdfReadException(.unsupported, "The file is over the size limit.") }
            let source = OfficeFontSource(installed: fonts, bundled: BundledFontSource())
            let bytes = [UInt8](try Data(contentsOf: url))
            let made: OfficePdf
            switch FileKinds.officeApp(url) {
            case .excel: made = try OfficeConverter.fromExcel(bytes, source, fileName: url.lastPathComponent)
            case .powerPoint: made = try OfficeConverter.fromPowerPoint(bytes, source, codec)
            default: made = try OfficeConverter.fromWord(bytes, source, codec)
            }
            return MadePdf(bytes: made.bytes, pages: made.pages, unreadable: made.missing.count, skipped: made.skipped)
        case .text:
            let text = try PdfFromText.create(request.text, fonts: fonts, setup: request.setup, size: request.fontSize)
            return MadePdf(bytes: text.bytes, pages: text.pages, unreadable: text.missing.count)
        case .web:
            preconditionFailure("A web page is made by CreateJob, which waits on the web view.")
        }
    }
}

@MainActor
public enum CreateJob {
    public static func run(_ host: ToolHost, _ codec: ImageCodec, _ fonts: FontSource?, _ request: CreateRequest,
                           web: WebPageRenderer? = nil) async throws {
        var made: MadePdf?
        do {
            try await host.runBusy(L10n.t("Creating")) { token in
                if request.source == .web {
                    made = try await makeWebPage(request, web, token)
                } else {
                    made = try await ToolDocuments.run(token) { try PdfMaker.make(request, codec, fonts, token) }
                }
            }
        } catch let error where error is ArgumentException || error is InvalidOperationException || error is WebPageError || error is PdfReadException || Problems.isFileSystem(error) {
            host.showProblem(CreateProblems.failed(error, request))
            return
        }
        guard let made else { return }

        await host.openNew(made.bytes, title: request.title, password: nil, certificate: nil)
        if request.source == .office {
            host.showNotice(L10n.t("Made without Office"), OfficeNotice.text(made, FileKinds.officeApp(request.files[0])), nil)
            return
        }
        var parts: [String] = []
        if made.unreadable > 0 {
            parts.append(request.source == .pictures
                ? L10n.plural(made.unreadable, one: "{0} picture could not be read.", other: "{0} pictures could not be read.")
                : L10n.t("Some letters have no shape in the font and were left out."))
        }
        if made.tooLarge > 0 {
            parts.append(L10n.plural(made.tooLarge, one: "{0} picture was too large and was left out.", other: "{0} pictures were too large and were left out."))
        }
        if made.leftOutRemote {
            parts.append(L10n.t("Pictures and styles from the internet are not loaded, so they are missing from the PDF."))
        }
        if !parts.isEmpty { host.showNotice(L10n.t("Some left out"), parts.joined(separator: " "), nil) }
    }
}

extension CreateJob {
    private static func makeWebPage(_ request: CreateRequest, _ web: WebPageRenderer?, _ token: CancelToken) async throws -> MadePdf {
        guard let web, let file = request.files.first else { throw WebPageError.couldNotLoad }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > WebPageRules.mostBytes { throw WebPageError.tooBig }
        let remote = try await ToolDocuments.run(token) {
            WebPageRules.namesRemoteParts(TextFiles.decode([UInt8](try Data(contentsOf: file))))
        }
        try token.throwIfCancelled()
        let layout = WebPageLayout(request.setup)
        let rendered = try await ToolDocuments.runAsync(token) { try await web.render(file, layout) }
        return MadePdf(bytes: rendered.bytes, pages: rendered.pages, unreadable: 0, leftOutRemote: remote)
    }
}

enum CreateProblems {
    static func failed(_ error: Error, _ request: CreateRequest) -> Problem {
        let source = request.source
        let app = source == .office ? FileKinds.officeApp(request.files[0]) : nil
        let excel = app == .excel
        let slides = app == .powerPoint
        let excel = source == .office && FileKinds.officeApp(request.files[0]) == .excel
        if source == .web {
            switch error as? WebPageError ?? .couldNotLoad {
            case .tooBig: return Problem(L10n.t("Page is too big"), L10n.t("The web page file is over 20 MB. Pick a smaller one."))
            case .timedOut: return Problem(L10n.t("Page took too long"), L10n.t("The web page did not finish loading. Pick a simpler page."))
            case .tooLong: return Problem(L10n.t("Page is too long"), L10n.t("The web page would make more than 2000 pages. Pick a shorter one."))
            case .couldNotLoad: return Problem(L10n.t("Page cannot be read"), L10n.t("The web page could not be read. Check that it is an HTML file and that no other program has it open."))
            }
        }
        if let error = error as? PdfReadException {
            if source == .office && FileKinds.isOldOffice(request.files[0]) {
                return Problem(L10n.t("Older Office file is not supported"), L10n.t("Save it as .docx, .xlsx or .pptx first."))
            }
            if slides {
                return error.problem == .damaged
                    ? Problem(L10n.t("PowerPoint file cannot be read"), L10n.t("The file is damaged or is not a PowerPoint presentation. Pick a .pptx file."))
                    : Problem(L10n.t("PowerPoint file is not supported"), L10n.t("The presentation cannot be made into a PDF. Only .pptx files up to 100 MB with a slide to show can be; older .ppt files must be saved as .pptx first."))
            }
            if excel {
                return error.problem == .damaged
                    ? Problem(L10n.t("Excel file cannot be read"), L10n.t("The file is damaged or is not an Excel workbook. Pick an .xlsx file."))
                    : Problem(L10n.t("Excel file is not supported"), L10n.t("The workbook cannot be made into a PDF. Only .xlsx files up to 100 MB with something to print can be; older .xls and .xlsb files must be saved as .xlsx first."))
            }
            return error.problem == .damaged
                ? Problem(L10n.t("Word file cannot be read"), L10n.t("The file is damaged or is not a Word document. Pick a .docx file."))
                : Problem(L10n.t("Word file is not supported"), L10n.t("Only .docx files up to 100 MB can be made into a PDF. Older .doc files must be saved as .docx first."))
        }
        if source == .office && !(error is InvalidOperationException || error is ArgumentException) {
            return Problems.isNoAccess(error)
                ? Problem(L10n.t("No access"), L10n.t("The system does not let Lazy PDF read the file. Check who may open it."))
                : Problem(excel ? L10n.t("Excel file cannot be read") : slides ? L10n.t("PowerPoint file cannot be read") : L10n.t("Word file cannot be read"), L10n.t("The file could not be read. Close any program that has it open and try again."))
        }
        if error is InvalidOperationException {
            return Problem(L10n.t("No font for this text"), L10n.t("No font on this computer can draw the text. Remove the letters it cannot show."))
        }
        if error is ArgumentException {
            return source == .pictures
                ? Problem(L10n.t("No picture to use"), L10n.t("None of the pictures could be read. Pick JPEG, PNG, TIFF, BMP, GIF or HEIC files."))
                : Problem(L10n.t("Margin is too wide"), L10n.t("The margin leaves no room on the page. Pick a smaller margin."))
        }
        if Problems.isNoAccess(error) {
            return Problem(L10n.t("No access"), L10n.t("The system does not let Lazy PDF read one of the pictures. Check who may open it."))
        }
        return Problem(L10n.t("Picture cannot be read"), L10n.t("One of the pictures could not be read. Close any program that has it open and try again."))
    }
}
