#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of PagesModel; follows windows/LazyPDF.App/Panels/Pages/PagesSidePanel.xaml.

public struct PagesPanelView: View {
    let model: PagesModel
    @Environment(\.displayScale) private var displayScale

    public init(model: PagesModel) {
        self.model = model
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    ForEach(model.thumbs) { thumb in
                        PageThumbView(thumb: thumb, isCurrent: thumb.index == model.current) { model.select(thumb.index) }
                            .id(thumb.index)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.current) { _, page in
                if page >= 0 { proxy.scrollTo(page, anchor: .center) }
            }
        }
        .onAppear { model.setScale(displayScale) }
        .onChange(of: displayScale) { _, scale in model.setScale(scale) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Page thumbnails"))
    }
}

struct PageThumbView: View {
    let thumb: PageThumb
    let isCurrent: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 4) {
                picture
                    .frame(width: thumb.width, height: thumb.height)
                    .background(Color.white)
                    .overlay(Rectangle().fill(Color.accentColor.opacity(isCurrent ? 0.2 : 0)))
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: isCurrent ? 3 : 0))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                Text(thumb.label)
                    .font(.caption)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .onAppear { thumb.load() }
        .onDisappear { thumb.release() }
        .accessibilityLabel(thumb.name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder
    private var picture: some View {
        if let image = thumb.shown.flatMap(PanelImage.make) {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }
}
#endif
