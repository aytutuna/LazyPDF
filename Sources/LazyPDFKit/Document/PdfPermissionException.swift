import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfPermissionException.cs: the file restricts itself and was not opened
// with the rights to change it this way.

public struct PdfPermissionException: Error, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
