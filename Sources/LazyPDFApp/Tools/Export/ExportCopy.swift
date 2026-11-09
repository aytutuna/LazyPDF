import Foundation

// Follows Exporter.Unique and Save of windows/LazyPDF.App/Tools/Export/Exporter.cs for the last step on the Mac: putting the
// finished files where the person said.

public enum ExportCopy {
    /// One file to the name the person gave in a save panel, which has already asked about replacing it.
    public static func replace(_ file: URL, with target: URL) -> ToolExport {
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.copyItem(at: file, to: target)
            return ToolExport(saved: [target])
        } catch {
            return ToolExport(failed: [target], denied: isDenied(error))
        }
    }

    /// Files into a folder that may hold others. A name that is taken becomes `name (2).ext`; nothing there is replaced.
    public static func into(_ folder: URL, _ files: [URL]) -> ToolExport {
        let manager = FileManager.default
        var result = ToolExport()
        for file in files {
            let target = Exporter.unique(folder, file.lastPathComponent)
            do {
                try manager.copyItem(at: file, to: target)
                result.saved.append(target)
            } catch {
                result.failed.append(target)
                if isDenied(error) { result.denied = true }
            }
        }
        return result
    }

    private static func isDenied(_ error: Error) -> Bool {
        let code = (error as NSError).code
        return code == NSFileWriteNoPermission || code == NSFileWriteVolumeReadOnly
    }
}
