import Foundation
import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Follows windows/LazyPDF.App.Tests/Tools/comment/CommentFixtures.cs: a document with a tab of its own, and a marker over it.
// The viewer stand-in of the Windows file is a ViewerModel here.

@MainActor
final class CommentFixture {
    let tab: DocumentTab

    init(pages: Int = 1) throws {
        tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text(pages)), renderer: FakeRenderer(), url: nil, title: "a.pdf")
    }

    var document: PdfDocument { tab.document }

    var marker: Marker {
        Marker(tab.document, FakeFonts(), author: "Ana", date: DateTimeOffset(2026, 11, 4, 10, 0, 0))
    }

    var geometry: PageGeometry { PageGeometry(document.pages[0]) }

    func marks(_ page: Int = 0) -> [PdfAnnotation] {
        PdfAnnotations.read(document, document.pages[page])
    }
}

let red = MarkStyle(color: [0.9, 0.1, 0.1])

func pt(_ x: Double, _ y: Double) -> ViewPoint { ViewPoint(x, y) }
