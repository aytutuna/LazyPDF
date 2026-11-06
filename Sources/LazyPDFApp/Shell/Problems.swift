import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Documents/Problems.cs.

/// A title that says what is wrong and a sentence that says what to do.
public struct Problem: Equatable {
    public let title: String
    public let text: String

    public init(_ title: String, _ text: String) {
        self.title = title
        self.text = text
    }
}

/// The C# InvalidDataException: a file that was read but holds nothing the app can use.
public struct InvalidDataException: Error, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Turns what the engine and the file system raise into words for the info bar.
public enum Problems {
    public static func open(_ error: Error, _ name: String) -> Problem {
        if let read = error as? PdfReadException {
            switch read.problem {
            case .notPdf:
                return Problem(L10n.t("Not a PDF"), L10n.t("{0} is not a PDF file. Pick a PDF, a picture or a text file.", name))
            case .damaged:
                return Problem(L10n.t("File is damaged"), L10n.t("{0} cannot be repaired. Try an earlier copy of it.", name))
            case .unsupported:
                return Problem(L10n.t("Not supported yet"), L10n.t("{0} uses something Lazy PDF cannot read yet.", name))
            default:
                return Problem(L10n.t("File is locked"), L10n.t("{0} needs a password or certificate that was not given.", name))
            }
        }
        if StoreFiles.isNoSuchFile(error) {
            return Problem(L10n.t("File not found"), L10n.t("{0} is not there any more. It may have been moved or deleted.", name))
        }
        if isNoAccess(error) {
            return Problem(L10n.t("No access"), L10n.t("The system does not let Lazy PDF read {0}. Check who may open it.", name))
        }
        if isFileSystem(error) {
            return Problem(L10n.t("File cannot be read"), L10n.t("{0} could not be read. Close any program that has it open and try again.", name))
        }
        if error is InvalidDataException {
            return Problem(L10n.t("Nothing to open"), L10n.t("{0} has no picture Lazy PDF can read.", name))
        }
        if error is InvalidOperationException {
            return Problem(L10n.t("Nothing to open"), L10n.t("No font on this computer can draw the text of {0}.", name))
        }
        return Problem(L10n.t("File cannot be opened"), L10n.t("{0} could not be opened.", name))
    }

    /// What Core's `PdfPermissionException` means in a tool: the file's own permissions forbid the change.
    public static func restricted() -> Problem {
        Problem(L10n.t("This file cannot be changed"), L10n.t("Its permissions do not allow it. Open it with the owner password."))
    }

    public static func save(_ error: Error, _ name: String) -> Problem {
        if error is PdfReadException {
            return Problem(L10n.t("Not saved"), L10n.t("The new {0} did not read back correctly, so the old one was kept. Your changes are still open.", name))
        }
        if isNoAccess(error) {
            return Problem(L10n.t("Not saved"), L10n.t("The system does not let Lazy PDF write {0}. Save it under another name or in another folder.", name))
        }
        return Problem(L10n.t("Not saved"), L10n.t("{0} could not be written. Check that the disk has room and that nothing else has the file open. Your changes are still open.", name))
    }

    static func isNoAccess(_ error: Error) -> Bool {
        let denied = [CocoaError.Code.fileReadNoPermission.rawValue, CocoaError.Code.fileWriteNoPermission.rawValue]
        return matches(error) {
            ($0.domain == NSCocoaErrorDomain && denied.contains($0.code))
                || ($0.domain == NSPOSIXErrorDomain && ($0.code == Int(EACCES) || $0.code == Int(EPERM)))
        }
    }

    // The C# IOException: anything the file system raised.
    static func isFileSystem(_ error: Error) -> Bool {
        matches(error) { $0.domain == NSCocoaErrorDomain || $0.domain == NSPOSIXErrorDomain }
    }

    private static func matches(_ error: Error, _ test: (NSError) -> Bool) -> Bool {
        let nsError = error as NSError
        if test(nsError) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error { return matches(underlying, test) }
        return false
    }
}
