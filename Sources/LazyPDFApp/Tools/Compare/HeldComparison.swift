import Foundation

// Follows windows/LazyPDF.App/Tools/Compare/HeldComparison.cs.

/// A finished comparison, kept for the tab it was run on so that switching tabs or writing the report does not lose it.
/// `revision` is the state of the open file the rows refer to. The other file's access ends with the `ToolFile`.
@MainActor
public final class HeldComparison {
    public let session: CompareSession
    public let file: ToolFile?
    public let openIsNew: Bool
    public let revision: Int

    /// The side by side sheet, while it is open.
    public var window: CompareWindowModel?

    public init(_ session: CompareSession, file: ToolFile?, openIsNew: Bool, revision: Int) {
        self.session = session
        self.file = file
        self.openIsNew = openIsNew
        self.revision = revision
    }

    public func dispose() {
        window?.close()
        window = nil
        session.dispose()
    }
}
