#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of StampsModel; follows windows/LazyPDF.App/Tools/Stamps/StampsPanel.xaml. The stamp is previewed on the pages as the
// form changes; the runs already in the file are a list under the form, where one is picked to update or remove.

struct StampsPanelView: View {
    let model: StampsModel

    var body: some View {
        ToolForm {
            LabelledField(L10n.t("Add")) {
                Picker(L10n.t("Kind of stamp"), selection: Binding(get: { model.form.mode }, set: { model.setMode($0) })) {
                    Text(L10n.t("Watermark")).tag(StampMode.watermark)
                    Text(L10n.t("Background")).tag(StampMode.background)
                    Text(L10n.t("Header and footer")).tag(StampMode.headerFooter)
                    Text(L10n.t("Bates numbers")).tag(StampMode.bates)
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let problem = model.problem {
                Label {
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            }
            switch model.form.mode {
            case .watermark: watermark
            case .background: background
            case .headerFooter: bands
            case .bates: bates
            }
            if model.form.mode == .watermark || model.form.mode == .background { pictureControls }
            if model.form.mode == .watermark || model.form.mode == .background { opacityControls }
            if model.form.mode != .background { fontControls }
            pagesControls
            if !model.runs.isEmpty { runsList }
        }
        .disabled(model.isBusy)
    }

    private func bind<T>(_ path: WritableKeyPath<StampForm, T>) -> Binding<T> {
        Binding(get: { model.form[keyPath: path] }, set: { new in model.edit { $0[keyPath: path] = new } })
    }

    private func names(_ names: [String], _ label: String, _ path: WritableKeyPath<StampForm, Int>) -> some View {
        Picker(label, selection: bind(path)) {
            ForEach(names.indices, id: \.self) { Text(names[$0]).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func slider(_ title: String, _ label: String, _ path: WritableKeyPath<StampForm, Double>, _ range: ClosedRange<Double>,
                        _ readout: String, step: Double = 1) -> some View {
        LabelledField(title) {
            HStack {
                Slider(value: bind(path), in: range, step: step).accessibilityLabel(label)
                Text(readout).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 52, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }

    private func field(_ title: String, _ label: String, _ path: WritableKeyPath<StampForm, String>) -> some View {
        LabelledField(title) {
            TextField(label, text: bind(path)).textFieldStyle(.roundedBorder).autocorrectionDisabled()
        }
    }

    private var places: [String] {
        [L10n.t("Top left"), L10n.t("Top"), L10n.t("Top right"), L10n.t("Left"), L10n.t("Centre"), L10n.t("Right"),
         L10n.t("Bottom left"), L10n.t("Bottom"), L10n.t("Bottom right")]
    }

    // MARK: Kinds

    private var watermark: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabelledField(L10n.t("Text")) {
                TextField(L10n.t("Watermark text"), text: bind(\.watermarkText), axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
            slider(L10n.t("Size"), L10n.t("Watermark size"), \.scale, 10...100, L10n.t("{0} %", Int(model.form.scale)))
            slider(L10n.t("Turn"), L10n.t("Watermark angle"), \.turn, -90...90, L10n.t("{0}°", Int(model.form.turn)))
            LabelledField(L10n.t("Place")) { names(places, L10n.t("Watermark place"), \.place) }
            Toggle(L10n.t("Behind the page text"), isOn: bind(\.behind))
        }
    }

    private var background: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabelledField(L10n.t("Colour")) { names(model.backColorNames, L10n.t("Background colour"), \.backColor) }
            LabelledField(L10n.t("Picture fit")) {
                names([L10n.t("Cover the page"), L10n.t("Fit inside the page"), L10n.t("Stretch to the page")], L10n.t("Picture fit"), \.fit)
            }
        }
    }

    private var pictureControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { Task { await model.pickPicture() } } label: {
                    Text(L10n.t("Pick a picture")).frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                Spacer()
                if model.pictureName != nil {
                    Button { model.removePicture() } label: { Text(L10n.t("Remove picture")).frame(minHeight: 44) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }
            if let name = model.pictureName { ReasonText(name).lineLimit(1) }
        }
    }

    private var opacityControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            slider(L10n.t("Opacity"), L10n.t("Opacity"), \.opacity, 5...100, L10n.t("{0} %", Int(model.form.opacity)), step: 5)
            Toggle(L10n.t("Readers can hide it"), isOn: bind(\.layer))
        }
    }

    private var bands: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel(L10n.t("Header"))
            field(L10n.t("Left"), L10n.t("Header left"), \.headerLeft)
            field(L10n.t("Centre"), L10n.t("Header centre"), \.headerCentre)
            field(L10n.t("Right"), L10n.t("Header right"), \.headerRight)
            FieldLabel(L10n.t("Footer"))
            field(L10n.t("Left"), L10n.t("Footer left"), \.footerLeft)
            field(L10n.t("Centre"), L10n.t("Footer centre"), \.footerCentre)
            field(L10n.t("Right"), L10n.t("Footer right"), \.footerRight)
            ReasonText(model.tokensHint)
            field(L10n.t("First page number"), L10n.t("First page number"), \.firstNumber)
            field(L10n.t("Date format"), L10n.t("Date format"), \.dateFormat)
        }
    }

    private var bates: some View {
        VStack(alignment: .leading, spacing: 10) {
            field(L10n.t("Before"), L10n.t("Before the number"), \.prefix)
            field(L10n.t("After"), L10n.t("After the number"), \.suffix)
            field(L10n.t("Digits"), L10n.t("Digits"), \.digits)
            field(L10n.t("Start at"), L10n.t("Start at"), \.start)
            LabelledField(L10n.t("Place")) {
                names(Array(places.prefix(3)) + Array(places.suffix(3)), L10n.t("Bates number place"), \.batesPlace)
            }
        }
    }

    private var fontControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabelledField(L10n.t("Font")) { names(model.families, L10n.t("Font"), \.family) }
            HStack(spacing: 16) {
                Toggle(L10n.t("Bold"), isOn: bind(\.bold))
                Toggle(L10n.t("Italic"), isOn: bind(\.italic))
            }
            LabelledField(L10n.t("Colour")) { names(model.colorNames, L10n.t("Text colour"), \.color) }
            if model.form.mode == .headerFooter || model.form.mode == .bates {
                slider(L10n.t("Text size"), L10n.t("Text size"), \.textSize, 6...36, L10n.t("{0} pt", Int(model.form.textSize)))
                slider(L10n.t("Margin"), L10n.t("Margin"), \.margin, 12...144, L10n.t("{0} pt", Int(model.form.margin)))
            }
        }
    }

    private var pagesControls: some View {
        LabelledField(L10n.t("On pages")) {
            Picker(L10n.t("Pages to stamp"), selection: bind(\.pages)) {
                Text(L10n.t("All pages")).tag(PageSet.all)
                Text(L10n.t("Odd pages")).tag(PageSet.odd)
                Text(L10n.t("Even pages")).tag(PageSet.even)
                Text(L10n.t("Pages I type")).tag(PageSet.typed)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.form.pages == .typed {
                TextField(L10n.t("Page range"), text: bind(\.pagesText))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
        }
    }

    // MARK: Runs

    private var runsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(L10n.t("Already on this file"))
            VStack(spacing: 2) {
                ForEach(model.runs) { row in
                    let on = model.selected == row
                    Button { model.select(row) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).lineLimit(1)
                            ReasonText(row.details).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 8)
                        .background(on ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.summary)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .accessibilityLabel(L10n.t("Stamps on this file"))
            if model.selected != nil { ReasonText(L10n.t("Change the settings above and update it. Pick a picture again if it had one.")) }
            HStack(spacing: 8) {
                Button { Task { await model.removeSelected() } } label: {
                    Text(L10n.t("Remove")).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(model.selected == nil)
                .accessibilityLabel(L10n.t("Remove the selected stamp"))
                Button { Task { await model.removeAll() } } label: {
                    Text(L10n.t("Remove all")).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(L10n.t("Remove all stamps"))
            }
            if model.selected != nil {
                Button { model.addNewInstead() } label: { Text(L10n.t("Add a new one instead")).frame(minHeight: 44) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.top, 8)
    }
}
#endif
