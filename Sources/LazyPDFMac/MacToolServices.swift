#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import LazyPDFApp

// What ToolHost offers the tools on the Mac: the open and save panels, and the pasteboard. A url from a panel carries the
// sandbox grant for as long as the app runs, so the files come back with no access of their own to stop.

@MainActor
final class MacToolServices: ToolFilePicker, ToolFileExporter, ToolClipboard {
    func pickFiles(_ kinds: [ToolFileKind], multiple: Bool) async -> [ToolFile] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.types(kinds)
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls.map { ToolFile(url: $0) } : []
    }

    func pickFolder() async -> ToolFile? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url.map { ToolFile(url: $0) } : nil
    }

    // One file is named in a save panel, which asks before it replaces one; several go into a folder the person picks, beside
    // whatever is there, and never over it.
    func export(_ files: [URL]) async -> ToolExport {
        guard let first = files.first else { return ToolExport() }
        if files.count == 1 {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = first.lastPathComponent
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let target = panel.url else { return ToolExport() }
            return ExportCopy.replace(first, with: target)
        }
        guard let folder = await pickFolder()?.url else { return ToolExport() }
        return ExportCopy.into(folder, files)
    }

    func pictureFile() -> [UInt8]? {
        let board = NSPasteboard.general
        guard let data = board.data(forType: .png) ?? board.data(forType: .tiff) else { return nil }
        return [UInt8](data)
    }

    func text() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func kind() -> ClipboardKind {
        let board = NSPasteboard.general
        if board.string(forType: .string)?.isEmpty == false { return .text }
        return board.canReadItem(withDataConformingToTypes: [UTType.png.identifier, UTType.tiff.identifier]) ? .picture : .nothing
    }

    private static func types(_ kinds: [ToolFileKind]) -> [UTType] {
        var found: [UTType] = []
        for kind in kinds {
            switch kind {
            case .pdf: found.append(.pdf)
            case .picture: found += FileKinds.pictureExtensions.compactMap { UTType(filenameExtension: $0) }
            case .text: found += FileKinds.textExtensions.compactMap { UTType(filenameExtension: $0) }
            case .webPage: found += FileKinds.webPageExtensions.compactMap { UTType(filenameExtension: $0) }
            case .office: found += FileKinds.officeExtensions.compactMap { UTType(filenameExtension: $0) }
            case .certificate: found += ["p12", "pfx"].compactMap { UTType(filenameExtension: $0) }
            case .any: return []
            }
        }
        return found
    }
}
#endif
