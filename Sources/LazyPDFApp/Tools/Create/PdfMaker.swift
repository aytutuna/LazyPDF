import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Create/PdfMaker.cs, CreateJob.cs and CreateProblems.cs.

public enum CreateSource { case blank, pictures, text }

/// `files` are picture files to read, in page order; `picture` is one already in memory that stands for them: the pasteboard's.
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

/// `unreadable` counts the pictures that could not be read, or the letters the font lacks.
public struct MadePdf {
    public let bytes: [UInt8]
    public let pages: Int
    public let unreadable: Int
}

public enum PdfMaker {
    public static let mostBlankPages = 500

    /// The engine calls take no token, so a cancel is only seen between the files read.
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
            return MadePdf(bytes: pictures.bytes, pages: pictures.pages, unreadable: pictures.unreadable.count)
        case .text:
            let text = try PdfFromText.create(request.text, fonts: fonts, setup: request.setup, size: request.fontSize)
            return MadePdf(bytes: text.bytes, pages: text.pages, unreadable: text.missing.count)
        }
    }
}

@MainActor
public enum CreateJob {
    public static func run(_ host: ToolHost, _ codec: ImageCodec, _ fonts: FontSource?, _ request: CreateRequest) async throws {
        var made: MadePdf?
        do {
            try await host.runBusy(L10n.t("Creating")) { token in
                made = try await ToolDocuments.run(token) { try PdfMaker.make(request, codec, fonts, token) }
            }
        } catch let error where error is ArgumentException || error is InvalidOperationException || Problems.isFileSystem(error) {
            host.showProblem(CreateProblems.failed(error, request.source))
            return
        }
        guard let made else { return }

        await host.openNew(made.bytes, title: request.title, password: nil, certificate: nil)
        if made.unreadable == 0 { return }
        let text = request.source == .pictures
            ? L10n.plural(made.unreadable, one: "{0} picture could not be read.", other: "{0} pictures could not be read.")
            : L10n.t("Some letters have no shape in the font and were left out.")
        host.showNotice(L10n.t("Some left out"), text, nil)
    }
}

enum CreateProblems {
    static func failed(_ error: Error, _ source: CreateSource) -> Problem {
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
