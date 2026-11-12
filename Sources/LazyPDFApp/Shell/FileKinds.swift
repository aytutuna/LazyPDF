import Foundation

// Follows windows/LazyPDF.App/Services/FileKinds.cs: what a file is by its name, for the open panel and for turning
// pictures and text into a PDF.

public enum OfficeApp: Sendable { case word, excel, powerPoint }

public enum FileKinds {
    public static let pictureExtensions = ["jpg", "jpeg", "png", "tif", "tiff", "bmp", "gif", "heic", "heif"]
    public static let textExtensions = ["txt"]
    public static let webPageExtensions = ["html", "htm"]

    /// The Office files that can be made into a PDF, and the program each is made by; a new kind is one more entry.
    private static let officeApps: [String: OfficeApp] = ["docx": .word, "xlsx": .excel, "pptx": .powerPoint]
    public static var officeExtensions: [String] { officeApps.keys.sorted() }

    public static func isPicture(_ url: URL) -> Bool {
        pictureExtensions.contains(url.pathExtension.lowercased())
    }

    public static func officeApp(_ url: URL) -> OfficeApp? {
        officeApps[url.pathExtension.lowercased()]
    }

    /// The binary formats before Office 2007, which cannot be read and must be saved in the new ones first.
    public static func isOldOffice(_ url: URL) -> Bool {
        ["doc", "xls", "ppt"].contains(url.pathExtension.lowercased())
    }

    public static func isText(_ url: URL) -> Bool {
        textExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isWebPage(_ url: URL) -> Bool {
        webPageExtensions.contains(url.pathExtension.lowercased())
    }
}
