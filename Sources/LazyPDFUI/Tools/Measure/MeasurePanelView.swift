#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of MeasureModel; follows windows/LazyPDF.App/Tools/Measure/MeasurePanel.xaml.

struct MeasurePanelView: View {
    let model: MeasureModel

    var body: some View {
        ToolForm {
            ReasonText(model.hint)
                .accessibilityAddTraits(.updatesFrequently)
            ReasonText(model.summary)
            kindPicker
            drawingSection
            scaleSection
            optionsSection
            waitingSection
        }
    }

    private var kindPicker: some View {
        LabelledField(L10n.t("Measure")) {
            Picker(L10n.t("Measure"), selection: Binding<MeasureKind?>(get: { model.kind }, set: { if let next = $0 { model.pick(next) } })) {
                ForEach(MeasureKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(Optional(kind))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var scaleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabelledField(L10n.t("On the page")) {
                HStack {
                    number(L10n.t("Length on the page"), model.pageValue) { model.setPageValue($0) }
                    units(L10n.t("Unit on the page"), MeasureModel.pageUnits, model.pageUnit) { model.setPageUnit($0) }
                }
            }
            LabelledField(L10n.t("Stands for")) {
                HStack {
                    number(L10n.t("Real length"), model.realValue) { model.setRealValue($0) }
                    units(L10n.t("Real unit"), MeasureModel.realUnits, model.realUnit) { model.setRealUnit($0) }
                }
            }
            if model.scaleProblem {
                Label(L10n.t("Enter a scale above zero."), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(L10n.t("Snap to text and lines"), isOn: Binding(get: { model.snapOn }, set: { model.setSnap($0) }))
            Toggle(L10n.t("Straight lines"), isOn: Binding(get: { model.straight }, set: { model.setStraight($0) }))
        }
    }

    private var drawingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { model.startOver() } label: {
                    Text(L10n.t("Start over")).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canStartOver)
                .help(L10n.t("Start over (Esc)"))
                .accessibilityLabel(L10n.t("Start the shape over"))
                Button { model.takeBack() } label: {
                    Text(L10n.t("Take back corner")).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canStartOver)
                .help(L10n.t("Take back the last corner (Backspace)"))
                .accessibilityLabel(L10n.t("Take back the last corner"))
            }
            Button { model.finish() } label: {
                Text(L10n.t("Finish")).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canFinish)
            .accessibilityLabel(L10n.t("Finish shape"))
            Text(model.readout)
                .font(.title3)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(L10n.t("Current measurement"))
                .accessibilityValue(model.readout)
        }
    }

    private var waitingSection: some View {
        LabelledField(L10n.t("Waiting to be added")) {
            if model.rows.isEmpty {
                ReasonText(L10n.t("Nothing measured yet."))
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.rows) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.item.title).font(.body)
                            Text(row.value).font(.callout)
                            Text(row.place).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.spoken)
                        Spacer()
                        Button { model.remove(row) } label: {
                            Image(systemName: "xmark.circle").frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(row.removeName)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.t("Measurements"))
        }
    }

    private func number(_ label: String, _ value: String, _ set: @escaping (String) -> Void) -> some View {
        TextField(label, text: Binding(get: { value }, set: set))
            .textFieldStyle(.roundedBorder)
            .frame(minHeight: 44)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
    }

    private func units(_ label: String, _ all: [LengthUnit], _ chosen: LengthUnit, _ set: @escaping (LengthUnit) -> Void) -> some View {
        Picker(label, selection: Binding(get: { chosen }, set: set)) {
            ForEach(all, id: \.self) { Text($0.symbol).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .frame(minHeight: 44)
    }
}
#endif
