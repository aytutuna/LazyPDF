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

    // One file is named in a save panel; several go into a folder the person picks. An existing name is replaced, which the
    // save panel has already asked about.
    func export(_ files: [URL]) async -> [URL] {
        guard let first = files.first else { return [] }
        let manager = FileManager.default
        if files.count == 1 {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = first.lastPathComponent
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let target = panel.url else { return [] }
            return copy(first, to: target, manager) ? [target] : []
        }
        guard let folder = await pickFolder()?.url else { return [] }
        return files.compactMap { file in
            let target = folder.appendingPathComponent(file.lastPathComponent)
            return copy(file, to: target, manager) ? target : nil
        }
    }

    private func copy(_ file: URL, to target: URL, _ manager: FileManager) -> Bool {
        do {
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.copyItem(at: file, to: target)
            return true
        } catch {
            return false
        }
    }

    func pictureFile() -> [UInt8]? {
        let board = NSPasteboard.general
        guard let data = board.data(forType: .png) ?? board.data(forType: .tiff) else { return nil }
        return [UInt8](data)
    }

    func text() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    private static func types(_ kinds: [ToolFileKind]) -> [UTType] {
        var found: [UTType] = []
        for kind in kinds {
            switch kind {
            case .pdf: found.append(.pdf)
            case .picture: found += FileKinds.pictureExtensions.compactMap { UTType(filenameExtension: $0) }
            case .text: found += FileKinds.textExtensions.compactMap { UTType(filenameExtension: $0) }
            case .certificate: found += ["p12", "pfx"].compactMap { UTType(filenameExtension: $0) }
            case .any: return []
            }
        }
        return found
    }
}
#endif
