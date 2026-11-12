import Foundation

// Follows windows/LazyPDF.App/Services/FileKinds.cs: what a file is by its name, for the open panel and for turning
// pictures and text into a PDF.

public enum FileKinds {
    public static let pictureExtensions = ["jpg", "jpeg", "png", "tif", "tiff", "bmp", "gif", "heic", "heif"]
    public static let textExtensions = ["txt"]
    public static let webPageExtensions = ["html", "htm"]

    public static func isPicture(_ url: URL) -> Bool {
        pictureExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isText(_ url: URL) -> Bool {
        textExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isWebPage(_ url: URL) -> Bool {
        webPageExtensions.contains(url.pathExtension.lowercased())
    }
}
