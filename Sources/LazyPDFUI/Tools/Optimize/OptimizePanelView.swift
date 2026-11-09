#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of OptimizeModel; follows windows/LazyPDF.App/Tools/Optimize/OptimizePanel.xaml.

struct OptimizePanelView: View {
    let model: OptimizeModel

    var body: some View {
        @Bindable var model = model
        ToolForm {
            LabelledField(L10n.t("Where the space goes")) {
                ReasonText(model.total)
                    .accessibilityAddTraits(.updatesFrequently)
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.name)
                            Spacer()
                            Text(row.size).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressView(value: row.share).accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.summary)
                }
            }
            LabelledField(L10n.t("Size and quality")) {
                Picker(L10n.t("Size and quality"), selection: $model.preset) {
                    Text(L10n.t("Small")).tag(SizePreset.small)
                    Text(L10n.t("Balanced")).tag(SizePreset.balanced)
                    Text(L10n.t("High")).tag(SizePreset.high)
                    Text(L10n.t("Custom")).tag(SizePreset.custom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if !model.presetNote.isEmpty { ReasonText(model.presetNote) }
            }
            if model.preset == .custom { custom(model) }
            Toggle(L10n.t("Convert to grayscale"), isOn: $model.grayscale)
            Toggle(L10n.t("Fast web view"), isOn: $model.fastWebView)
            ReasonText(L10n.t("Page one shows before the whole file has loaded."))
            OutputChoiceView(output: model.output)
        }
    }

    @ViewBuilder
    private func custom(_ model: OptimizeModel) -> some View {
        @Bindable var model = model
        LabelledField(L10n.t("Picture resolution")) {
            Picker(L10n.t("Picture resolution"), selection: $model.dpiIndex) {
                ForEach(Array(model.dpiLabels.enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
            }
            .labelsHidden()
        }
        LabelledField(L10n.t("Picture quality")) {
            HStack {
                Slider(value: Binding(get: { Double(model.quality) }, set: { model.quality = Int($0) }), in: 30...95, step: 5)
                    .accessibilityLabel(L10n.t("Picture quality"))
                Text("\(model.quality)").monospacedDigit().frame(width: 32, alignment: .trailing)
            }
        }
        Toggle(L10n.t("Trim fonts"), isOn: $model.trimFonts)
        Toggle(L10n.t("Make black and white pictures 1-bit"), isOn: $model.blackWhite)
        Toggle(L10n.t("Remove application data"), isOn: $model.dropAppData)
        Toggle(L10n.t("Remove private keys"), isOn: $model.dropPrivateKeys)
    }
}
#endif
