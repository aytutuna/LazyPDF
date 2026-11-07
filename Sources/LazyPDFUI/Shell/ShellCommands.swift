#if canImport(SwiftUI)
import Foundation
import LazyPDFApp

/// What the window asks of the platform shell because it needs a system panel or a security-scoped grant: choosing files,
/// naming a copy, printing. The shell starts access to a chosen file before it opens it, as AppViewModel.open expects.
public struct ShellCommands {
    public var open: @MainActor () -> Void
    public var create: @MainActor () -> Void
    public var batch: @MainActor () -> Void

    /// Asks for a name and saves the tab there; true when it was saved.
    public var saveAs: @MainActor (DocumentTab) async -> Bool
    public var saveCompact: @MainActor (DocumentTab) -> Void
    public var print: @MainActor (DocumentTab) -> Void

    /// Opens files dropped on the window; nil lets the window open them without a grant of their own.
    public var openFiles: (@MainActor ([URL]) -> Void)?

    public init(open: @escaping @MainActor () -> Void = {}, create: @escaping @MainActor () -> Void = {},
                batch: @escaping @MainActor () -> Void = {}, saveAs: @escaping @MainActor (DocumentTab) async -> Bool = { _ in false },
                saveCompact: @escaping @MainActor (DocumentTab) -> Void = { _ in },
                print: @escaping @MainActor (DocumentTab) -> Void = { _ in },
                openFiles: (@MainActor ([URL]) -> Void)? = nil) {
        self.open = open
        self.create = create
        self.batch = batch
        self.saveAs = saveAs
        self.saveCompact = saveCompact
        self.print = print
        self.openFiles = openFiles
    }
}
#endif
