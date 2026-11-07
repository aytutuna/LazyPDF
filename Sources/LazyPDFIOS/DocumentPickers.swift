#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import LazyPDFApp

/// A file the person picked, with the access to it that the system gave and the shell has to stop.
public struct PickedFile {
    public let url: URL
    public let access: FileAccess?
}

/// The types the open picker offers: PDFs, and the pictures and text the app turns into one (FileKinds).
public let openableTypes: [UTType] = [.pdf]
    + (FileKinds.pictureExtensions + FileKinds.textExtensions).compactMap { UTType(filenameExtension: $0) }

/// The document picker for opening files where they are (not as copies), several at once. An empty list is a cancel.
public struct OpenPicker: UIViewControllerRepresentable {
    private let picked: ([PickedFile]) -> Void

    public init(picked: @escaping ([PickedFile]) -> Void) {
        self.picked = picked
    }

    public func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: openableTypes, asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    public func makeCoordinator() -> PickerDelegate {
        PickerDelegate(picked)
    }
}

/// The document picker for saving: it takes `file`, a finished copy in the app's folders, to the place the person picks.
/// The picked file is the one saved there; an empty list is a cancel.
public struct ExportPicker: UIViewControllerRepresentable {
    private let file: URL
    private let picked: ([PickedFile]) -> Void

    public init(file: URL, picked: @escaping ([PickedFile]) -> Void) {
        self.file = file
        self.picked = picked
    }

    public func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    public func makeCoordinator() -> PickerDelegate {
        PickerDelegate(picked)
    }
}

public final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let picked: ([PickedFile]) -> Void

    init(_ picked: @escaping ([PickedFile]) -> Void) {
        self.picked = picked
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        picked(urls.map { PickedFile(url: $0, access: SecurityScopedAccess.start($0)) })
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        picked([])
    }
}

/// The share sheet, for handing a file to another app (Lazy Print, Mail, Files).
public struct ShareSheet: UIViewControllerRepresentable {
    private let files: [URL]

    public init(files: [URL]) {
        self.files = files
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: files, applicationActivities: nil)
    }

    public func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
