#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// The panels of the tools (windows/LazyPDF.App/Tools/ToolCatalog.cs, the Create of each ToolInfo). The catalog lists the tools;
// this finds the model and the view of one. Each group of tools has a file of its own in Registry/, so that the people
// porting different groups never edit the same file.

/// What a registry file knows when it makes a panel.
struct ToolContext {
    let info: ToolInfo
    let folders: AppFolders
}

/// A tool's model and its view, made together. The shell attaches the model to the document; the view only reads it.
public struct ToolPanel {
    public let model: ToolPanelModel
    public let view: AnyView

    /// What takes the stage's place while the model holds it (`ToolHost.holdStage`): Pages shows its page grid there.
    public let stage: AnyView?

    public init<Model: ToolPanelModel, Content: View>(_ model: Model, @ViewBuilder view: (Model) -> Content) {
        self.model = model
        self.view = AnyView(view(model))
        stage = nil
    }

    public init<Model: ToolPanelModel, Content: View, Stage: View>(_ model: Model, @ViewBuilder stage: (Model) -> Stage,
                                                                      @ViewBuilder view: (Model) -> Content) {
        self.model = model
        self.view = AnyView(view(model))
        self.stage = AnyView(stage(model))
    }
}

@MainActor
enum ToolRegistry {
    /// The panel of the tool `id`; nil for a tool whose group has not ported it yet, which then shows its title and summary.
    static func panel(for id: String, _ context: ToolContext) -> ToolPanel? {
        markup(id, context) ?? content(id, context) ?? pages(id, context) ?? forms(id, context)
            ?? security(id, context) ?? analysis(id, context) ?? convert(id, context) ?? document(id, context)
    }
}
#endif
