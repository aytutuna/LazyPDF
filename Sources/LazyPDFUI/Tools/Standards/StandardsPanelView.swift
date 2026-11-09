#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of StandardsModel; follows windows/LazyPDF.App/Tools/Standards/StandardsPanel.xaml.

struct StandardsPanelView: View {
    let model: StandardsModel

    var body: some View {
        ToolForm {
            Picker(L10n.t("Mode"), selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                Text(L10n.t("Check")).tag(StandardsMode.check)
                Text(L10n.t("Convert")).tag(StandardsMode.convert)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.modeNote)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            LabelledField(L10n.t("Level")) {
                Picker(L10n.t("PDF/A level"), selection: Binding(get: { model.levelIndex }, set: { model.setLevel($0) })) {
                    ForEach(Array(StandardsModel.levels.enumerated()), id: \.offset) { Text($0.element.name()).tag($0.offset) }
                }
                .labelsHidden()
                ReasonText(model.levelNote)
            }
            if !model.losses.isEmpty {
                Label(model.losses, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if model.showsResult { result }
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.verdict)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits([.isHeader, .updatesFrequently])
            ReasonText(model.caveat)
            ForEach(model.rows) { row in
                IssueRowView(model: model, row: row)
            }
            if !model.rest.isEmpty { ReasonText(model.rest).padding(.top, 8) }
        }
        .padding(.top, 8)
    }
}

private struct IssueRowView: View {
    let model: StandardsModel
    let row: IssueRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.message).fixedSize(horizontal: false, vertical: true)
            ReasonText(row.place)
            ReasonText(row.clause)
            if row.hasPlaces {
                Button(row.placeText) { model.visit(row) }
                    .frame(minHeight: 44)
                    .accessibilityLabel(row.placeText)
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.summary)
    }
}
#endif
