#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of CommentsModel; follows windows/LazyPDF.App/Panels/Comments/CommentsSidePanel.xaml.

public struct CommentsPanelView: View {
    let model: CommentsModel
    @State private var filter = ""
    @State private var reply = ""
    @State private var exporting = false
    @State private var summary = BytesDocument()

    private static let statuses: [ReviewStatus] = [.none, .accepted, .rejected, .cancelled, .completed]

    public init(model: CommentsModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            controls
            if model.isEmpty {
                PanelNote(model.emptyText).frame(maxHeight: .infinity, alignment: .top)
            } else {
                list
            }
            if let row = model.selectedRow {
                detail(row)
            }
        }
        .fileExporter(isPresented: $exporting, document: summary, contentType: .plainText, defaultFilename: model.summaryName) {
            model.summarySaved($0)
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack {
                TextField(L10n.t("Filter"), text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.t("Filter comments"))
                    .help(L10n.t("Filter by text or author"))
                    .onChange(of: filter) { _, text in model.setQuery(text) }
                Button { export() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help(L10n.t("Save a summary of the comments"))
                .accessibilityLabel(L10n.t("Export summary"))
            }
            HStack {
                Picker(L10n.t("Group by"), selection: Binding(get: { model.grouping }, set: { model.setGrouping($0) })) {
                    Text(L10n.t("By page")).tag(CommentOrder.page)
                    Text(L10n.t("By author")).tag(CommentOrder.author)
                    Text(L10n.t("By type")).tag(CommentOrder.type)
                }
                .help(L10n.t("Group by"))
                Picker(L10n.t("Show status"), selection: Binding(get: { model.statusFilter }, set: { model.setStatusFilter($0) })) {
                    Text(L10n.t("Any status")).tag(ReviewStatus?.none)
                    ForEach(Self.statuses, id: \.self) { Text(AnnotationText.statusName($0)).tag(Optional($0)) }
                }
                .help(L10n.t("Show status"))
            }
            .labelsHidden()
        }
        .padding(12)
    }

    private var list: some View {
        List(selection: Binding(get: { model.selected }, set: { model.select($0) })) {
            ForEach(model.groups) { group in
                Section(group.name) {
                    ForEach(group.rows) { row in
                        CommentRowView(row: row)
                            .tag(row.id)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(row.summary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel(L10n.t("Comments"))
        .onChange(of: model.selected) { _, _ in
            if let row = model.selectedRow { model.go(row) }
        }
    }

    private func detail(_ row: CommentRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.replies.enumerated()), id: \.offset) { _, text in
                    Text(text).font(.callout)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.t("Replies"))
            Picker(L10n.t("Status"), selection: Binding(get: { row.comment.status }, set: { model.setStatus($0) })) {
                ForEach(Self.statuses, id: \.self) { Text(AnnotationText.statusName($0)).tag($0) }
            }
            TextEditor(text: $reply)
                .frame(height: 56)
                .accessibilityLabel(L10n.t("Reply"))
            HStack {
                Spacer()
                Button(L10n.t("Reply")) {
                    if model.reply(reply) { reply = "" }
                }
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(L10n.t("Send reply"))
            }
        }
        .disabled(!model.canAnswer)
        .padding(12)
        .background(.quaternary.opacity(0.4))
    }

    private func export() {
        guard let text = model.summaryText() else { return }
        summary = BytesDocument(bytes: Array(text.utf8))
        exporting = true
    }
}

private struct CommentRowView: View {
    let row: CommentRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title).fontWeight(.semibold).lineLimit(1)
            if !row.text.isEmpty {
                Text(row.text).lineLimit(3)
            }
            Text(row.location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
#endif
