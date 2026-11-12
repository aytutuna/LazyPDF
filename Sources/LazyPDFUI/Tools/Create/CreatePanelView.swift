#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
#endif
import LazyPDFApp
import LazyPDFKit

// The view of CreateModel; follows windows/LazyPDF.App/Tools/Create/CreatePanel.xaml. The sheet of CreateSheet and the tool of
// the strip both show it.

struct CreatePanelView: View {
    let model: CreateModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        ToolForm {
            LabelledField(L10n.t("Make a PDF from")) {
                Picker(L10n.t("Make a PDF from"), selection: Binding(get: { model.from }, set: { model.choose($0) })) {
                    Text(L10n.t("Blank pages")).tag(CreateFrom.blank)
                    Text(L10n.t("Pictures")).tag(CreateFrom.pictures)
                    Text(L10n.t("Text")).tag(CreateFrom.text)
                    Text(L10n.t("Clipboard")).tag(CreateFrom.clipboard)
                    if model.offersWebPage { Text(L10n.t("Web page")).tag(CreateFrom.webPage) }
                }
                .labelsHidden()
            }
            switch model.from {
            case .blank: blank(model)
            case .pictures: pictures(model)
            case .text: text(model)
            case .webPage: webPage(model)
            case .clipboard: Label(model.clipboardState, systemImage: "doc.on.clipboard").font(.caption).foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            }
            if let blocker = model.blocker {
                Label(blocker, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if model.showsSetup { setup(model) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL).map { ToolFile(url: $0, access: SecurityScopedAccess.start($0)) }
            if files.isEmpty { return false }
            model.drop(files)
            return true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.peekClipboard() }
        }
        #if os(macOS)
        // The sheet hangs from an AppKit window outside any scene, so its scene phase never changes.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.peekClipboard() }
        #endif
    }

    private func blank(_ model: CreateModel) -> some View {
        @Bindable var model = model
        return LabelledField(L10n.t("Number of pages")) {
            TextField(L10n.t("Number of pages"), text: $model.blankPages)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 100, alignment: .leading)
                .onChange(of: model.blankPages) { model.inputChanged() }
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
        }
    }

    @ViewBuilder
    private func pictures(_ model: CreateModel) -> some View {
        Button { Task { await model.addPictures() } } label: { Label(L10n.t("Add pictures"), systemImage: "plus") }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.pictures) { item in
                Button { model.selection = item.id } label: {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .padding(.horizontal, 6)
                        .background(model.selection == item.id ? Color.accentColor.opacity(0.25) : Color.clear)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.name)
                .accessibilityAddTraits(model.selection == item.id ? .isSelected : [])
            }
        }
        .frame(minHeight: 64, alignment: .top)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
        .accessibilityLabel(L10n.t("Pictures"))
        HStack {
            Button { model.move(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(!model.canMoveUp)
                .accessibilityLabel(L10n.t("Move up"))
            Button { model.move(1) } label: { Image(systemName: "chevron.down") }
                .disabled(!model.canMoveDown)
                .accessibilityLabel(L10n.t("Move down"))
            Button { model.removeSelected() } label: { Image(systemName: "trash") }
                .disabled(model.selection == nil)
                .accessibilityLabel(L10n.t("Remove"))
        }
    }

    @ViewBuilder
    private func text(_ model: CreateModel) -> some View {
        @Bindable var model = model
        LabelledField(L10n.t("Text for the pages")) {
            TextEditor(text: $model.typedText)
                .frame(minHeight: 120, maxHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                .accessibilityLabel(L10n.t("Text for the pages"))
                .onChange(of: model.typedText) { model.inputChanged() }
        }
        Button { Task { await model.openTextFile() } } label: { Label(L10n.t("Open a text file"), systemImage: "doc.text") }
    }

    @ViewBuilder
    private func webPage(_ model: CreateModel) -> some View {
        Button { Task { await model.pickWebPage() } } label: { Label(L10n.t("Choose a web page file"), systemImage: "globe") }
        if let page = model.webPage {
            Text(page.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
        }
        Label(L10n.t("Scripts do not run and nothing is loaded from the internet."), systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func setup(_ model: CreateModel) -> some View {
        @Bindable var model = model
        LabelledField(L10n.t("Paper")) {
            Picker(L10n.t("Paper"), selection: $model.paper) {
                Text("A4").tag(CreatePaper.a4)
                Text("A3").tag(CreatePaper.a3)
                Text("A5").tag(CreatePaper.a5)
                Text(L10n.t("Letter")).tag(CreatePaper.letter)
                Text(L10n.t("Legal")).tag(CreatePaper.legal)
                Text(L10n.t("Custom size")).tag(CreatePaper.custom)
                if model.makesPictures { Text(L10n.t("Size of the picture")).tag(CreatePaper.picture) }
            }
            .labelsHidden()
        }
        if model.showsCustomSize {
            LabelledField(L10n.t("Width ({0})", model.unit)) {
                TextField(L10n.t("Width ({0})", model.unit), text: $model.customWidth).textFieldStyle(.roundedBorder).numberField()
            }
            LabelledField(L10n.t("Height ({0})", model.unit)) {
                TextField(L10n.t("Height ({0})", model.unit), text: $model.customHeight).textFieldStyle(.roundedBorder).numberField()
            }
        }
        LabelledField(L10n.t("Orientation")) {
            Picker(L10n.t("Orientation"), selection: $model.orientation) {
                Text(L10n.t("Automatic")).tag(CreateOrientation.automatic)
                Text(L10n.t("Portrait")).tag(CreateOrientation.portrait)
                Text(L10n.t("Landscape")).tag(CreateOrientation.landscape)
            }
            .labelsHidden()
            .disabled(!model.orientationEnabled)
        }
        if model.showsMargin {
            LabelledField(L10n.t("Margin")) {
                Picker(L10n.t("Margin"), selection: $model.margin) {
                    Text(L10n.t("None")).tag(0.0)
                    Text(L10n.t("Narrow")).tag(18.0)
                    Text(L10n.t("Normal")).tag(36.0)
                    Text(L10n.t("Wide")).tag(72.0)
                }
                .labelsHidden()
            }
        }
        if model.makesText {
            LabelledField(L10n.t("Text size")) {
                Picker(L10n.t("Text size"), selection: $model.fontSize) {
                    ForEach(CreateModel.fontSizes, id: \.self) { Text("\(Int($0)) pt").tag($0) }
                }
                .labelsHidden()
            }
        }
    }
}

/// The Create dialog of the Home tile: the panel with Create and Cancel under it. Create closes it, then makes the document.
public struct CreateSheet: View {
    @State private var model: CreateModel
    let close: () -> Void

    public init(host: AppViewModel, close: @escaping () -> Void) {
        _model = State(initialValue: CreateModel(host: host, codec: ImageIOCodec(), fonts: CoreTextFontSource(), settings: host.settings, web: WebKitPageRenderer()))
        self.close = close
    }

    init(model: CreateModel, close: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.close = close
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text(L10n.t("Create a PDF"))
                .font(.headline)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)
            ScrollView { CreatePanelView(model: model) }
            Divider()
            HStack {
                Spacer()
                Button(L10n.t("Cancel"), role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("Create")) {
                    guard let request = model.request() else { return }
                    close()
                    Task { await model.create(request) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRun)
            }
            .padding(12)
        }
        #if os(macOS)
        .frame(width: 400, height: 580)
        #endif
    }
}
#endif
