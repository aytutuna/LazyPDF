#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of PdfUaModel; follows windows/LazyPDF.App/Tools/PdfUa/PdfUaPanel.xaml.

struct PdfUaPanelView: View {
    let model: PdfUaModel

    var body: some View {
        ToolForm {
            Text(model.intro)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            ReasonText(model.personNote)
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
            if model.canMark {
                ReasonText(model.markNote).padding(.top, 8)
                Button(L10n.t("Mark as PDF/UA")) { Task { await model.mark() } }
                    .frame(minHeight: 44)
            }
            ForEach(model.rows) { row in
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
            if !model.rest.isEmpty { ReasonText(model.rest).padding(.top, 8) }
        }
        .padding(.top, 8)
    }
}
#endif
