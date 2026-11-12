#if os(iOS)
import UIKit
import UniformTypeIdentifiers
import LazyPDFApp

// What ToolHost offers the tools on the iPhone and iPad: the document picker for reading and for saving, and the pasteboard.
// UIKit presents them over whatever is up, the tool's own sheet included.

@MainActor
final class IOSToolServices: ToolFilePicker, ToolFileExporter, ToolClipboard {
    private var delegate: PickerDelegate?

    func pickFiles(_ kinds: [ToolFileKind], multiple: Bool) async -> [ToolFile] {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.types(kinds), asCopy: false)
        picker.allowsMultipleSelection = multiple
        return await present(picker).map { ToolFile(url: $0.url, access: $0.access) }
    }

    func pickFolder() async -> ToolFile? {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        return await present(picker).first.map { ToolFile(url: $0.url, access: $0.access) }
    }

    func export(_ files: [URL]) async -> ToolExport {
        if files.isEmpty { return ToolExport() }
        let saved = await present(UIDocumentPickerViewController(forExporting: files, asCopy: true))
        for file in saved { file.access?.stop() }
        return ToolExport(saved: saved.map(\.url))
    }

    func pictureFile() -> [UInt8]? {
        UIPasteboard.general.image?.pngData().map { [UInt8]($0) }
    }

    func text() -> String? {
        UIPasteboard.general.string
    }

    func kind() -> ClipboardKind {
        let board = UIPasteboard.general
        return board.hasStrings ? .text : board.hasImages ? .picture : .nothing
    }

    private func present(_ picker: UIDocumentPickerViewController) async -> [PickedFile] {
        guard var top = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.keyWindow?.rootViewController else {
            return []
        }
        while let next = top.presentedViewController { top = next }
        let presenter = top
        let chosen: [PickedFile] = await withCheckedContinuation { continuation in
            // The picker keeps its delegate weakly.
            delegate = PickerDelegate { continuation.resume(returning: $0) }
            picker.delegate = delegate
            presenter.present(picker, animated: true)
        }
        delegate = nil
        return chosen
    }

    private static func types(_ kinds: [ToolFileKind]) -> [UTType] {
        var found: [UTType] = []
        for kind in kinds {
            switch kind {
            case .pdf: found.append(.pdf)
            case .picture: found += FileKinds.pictureExtensions.compactMap { UTType(filenameExtension: $0) }
            case .text: found += FileKinds.textExtensions.compactMap { UTType(filenameExtension: $0) }
            case .webPage: found += FileKinds.webPageExtensions.compactMap { UTType(filenameExtension: $0) }
            case .word: found += FileKinds.wordExtensions.compactMap { UTType(filenameExtension: $0) }
            case .certificate: found += ["p12", "pfx"].compactMap { UTType(filenameExtension: $0) }
            case .any: return [.item]
            }
        }
        return found
    }
}
#endif
