#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of SanitizeModel; follows windows/LazyPDF.App/Tools/Sanitize/SanitizePanel.xaml.

struct SanitizePanelView: View {
    let model: SanitizeModel

    var body: some View {
        ToolForm {
            LabelledField(L10n.t("What was found")) {
                ReasonText(model.found)
                    .accessibilityAddTraits(.updatesFrequently)
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(row.label, isOn: Binding(get: { row.isChecked }, set: { model.setChecked(row, $0) }))
                            .disabled(!row.canTick)
                        if !row.note.isEmpty { ReasonText(row.note) }
                    }
                }
            }
            OutputChoiceView(output: model.output)
        }
    }
}
#endif
