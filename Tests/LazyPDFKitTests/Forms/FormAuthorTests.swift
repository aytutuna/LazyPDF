import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Forms/FormAuthorTests.cs: the same cases. Left out: the PdfPig field counts (PigFields),
// which have no Swift twin. The font source is the synthetic font (A, B, space, ğ, İ and À), so the Turkish text is made of those.

final class FormAuthorTests: XCTestCase {
    private let box = PdfRect(50, 700, 250, 720)

    private func blank(_ fonts: FontSource? = nil) throws -> PdfForm {
        PdfForm.read(try AnnotationFixtures.blank(), fonts)
    }

    func test_aTextFieldGetsAWidgetAnAppearanceAndAFormToLiveIn() throws {
        let form = try blank()

        let field = try form.addField(FieldSpec(.text, "first", 0, box, value: "Ada", flags: .required, tooltip: "Given name"))

        XCTAssertEqual(field.name, "first")
        XCTAssertEqual(field.value, "Ada")
        XCTAssertEqual(field.tooltip, "Given name")
        XCTAssertTrue(field.has(.required))
        XCTAssertEqual(field.widgets[0].rect, box)
        XCTAssertEqual(field.widgets[0].pageIndex, 0)
        XCTAssertEqual(try FormFixtures.drawn(form.document, field.widgets[0]), "Ada")
        let annots = try XCTUnwrap(form.document.array(form.document.pages[0].dictionary, "Annots"))
        XCTAssertTrue(annots.items.contains { ($0 as? PdfReference) == field.reference })
        let reopened = PdfForm.read(try AnnotationFixtures.reopen(form.document))
        XCTAssertEqual(reopened.find("first")?.value, "Ada")
    }

    func test_everyKindCanBeAddedAndReadBack() throws {
        let form = try blank()
        var y = 700.0
        func next() -> PdfRect {
            y -= 40
            return PdfRect(50, y, 250, y + 30)
        }

        try form.addField(FieldSpec(.text, "t", 0, next(), flags: [.multiline, .password]))
        try form.addField(FieldSpec(.text, "comb", 0, next(), value: "123", flags: .comb, maxLength: 8))
        try form.addField(FieldSpec(.checkBox, "c", 0, next(), value: "On", exportValue: "On"))
        try form.addField(FieldSpec(.radio, "r", 0, next(), value: "one", exportValue: "one"))
        try form.addField(FieldSpec(.pushButton, "go", 0, next(), background: [0.8], borderStyle: .beveled, caption: "Send"))
        try form.addField(FieldSpec(.comboBox, "combo", 0, next(), value: "Bee", defaultValue: "a", options: [FieldOption("a"), FieldOption("b", "Bee")]))
        try form.addField(FieldSpec(.listBox, "list", 0, next(), value: "x; z", options: [FieldOption("x"), FieldOption("y"), FieldOption("z")], flags: .multiSelect))
        try form.addField(FieldSpec(.signature, "sig", 0, next()))

        let read = PdfForm.read(try AnnotationFixtures.reopen(form.document))
        XCTAssertEqual(read.fields.map { $0.kind }, [.text, .text, .checkBox, .radio, .pushButton, .comboBox, .listBox, .signature])
        XCTAssertTrue(try XCTUnwrap(read.find("t")).has(.password))
        XCTAssertEqual(read.find("comb")?.value, "123")
        XCTAssertEqual(read.find("comb")?.maxLength, 8)
        XCTAssertTrue(try XCTUnwrap(read.find("c")).isChecked)
        XCTAssertEqual(read.find("r")?.value, "one")
        XCTAssertEqual(read.find("combo")?.value, "b")
        XCTAssertEqual(read.find("combo")?.defaultValue, "a")
        XCTAssertEqual(read.find("list")?.selected, ["x", "z"])
        XCTAssertEqual(try FormFixtures.drawn(read.document, try XCTUnwrap(read.find("go")).widgets[0]), "Send")
    }

    func test_radioGroupGrowsWithAddWidget() throws {
        let form = try blank()
        try form.addField(FieldSpec(.radio, "size", 0, PdfRect(50, 700, 64, 714), exportValue: "S"))
        var field = try XCTUnwrap(form.find("size"))

        try form.addWidget(field, 0, PdfRect(100, 700, 114, 714), "M")
        try form.addWidget(try XCTUnwrap(form.find("size")), 0, PdfRect(150, 700, 164, 714), "L")
        try form.setValue("size", "M")

        field = try XCTUnwrap(form.find("size"))
        XCTAssertEqual(field.widgets.map { $0.onState }, ["S", "M", "L"])
        XCTAssertEqual(field.widgets.map { form.document.name($0.dictionary, "AS") }, ["Off", "M", "Off"])
        XCTAssertEqual(field.value, "M")
        try AnnotationFixtures.reopen(form.document)
    }

    func test_aTextFieldCanBeShownInTwoPlaces() throws {
        let form = try blank()
        try form.addField(FieldSpec(.text, "twice", 0, box))

        try form.addWidget(try XCTUnwrap(form.find("twice")), 1, PdfRect(10, 10, 110, 30))
        try form.setValue("twice", "same")

        let field = try XCTUnwrap(form.find("twice"))
        XCTAssertEqual(field.widgets.map { $0.pageIndex }, [0, 1])
        for w in field.widgets { XCTAssertEqual(try FormFixtures.drawn(form.document, w), "same") }
        XCTAssertEqual(PdfForm.read(try AnnotationFixtures.reopen(form.document)).find("twice")?.value, "same")
    }

    func test_dottedNamesMakeParentsAndNamesAreUnique() throws {
        let form = try blank()
        try form.addField(FieldSpec(.text, "person.first", 0, box))
        try form.addField(FieldSpec(.text, "person.last", 0, PdfRect(50, 660, 250, 680)))

        XCTAssertEqual(form.fields.map { $0.name }, ["person.first", "person.last"])
        XCTAssertEqual(form.document.array(form.acroForm, "Fields")?.items.count, 1)
        for name in ["person.first", "person", "person.first.x"] {
            XCTAssertThrowsError(try form.addField(FieldSpec(.text, name, 0, box)), name) { error in
                XCTAssertTrue(error is InvalidOperationException, name)
            }
        }
        assertArgumentException(try form.addField(FieldSpec(.text, "bad.", 0, box)))
        assertArgumentException(try form.addField(FieldSpec(.text, "ok", 9, box)))
        assertArgumentException(try form.addField(FieldSpec(.text, "ok", 0, PdfRect(1, 1, 1, 5))))
        assertArgumentException(try form.addField(FieldSpec(.text, "a..b", 0, box)))
        XCTAssertEqual(PdfForm.read(try AnnotationFixtures.reopen(form.document)).fields.count, 2)
    }

    func test_movingAndResizingRedrawTheAppearance() throws {
        let form = try blank()
        let field = try form.addField(FieldSpec(.text, "a", 0, box, value: "text"))

        try form.move(field.widgets[0], 10, -100)
        try form.resize(try XCTUnwrap(form.find("a")).widgets[0], PdfRect(60, 600, 360, 640))

        let widget = try XCTUnwrap(form.find("a")).widgets[0]
        XCTAssertEqual(widget.rect, PdfRect(60, 600, 360, 640))
        let ap = try XCTUnwrap(form.document.dict(widget.dictionary, "AP"))
        let stream = try XCTUnwrap(form.document.resolve(ap["N"]) as? PdfStream)
        let size = try XCTUnwrap(form.document.array(stream.dictionary, "BBox")).items.map { ($0 as? PdfNumber)?.value }
        XCTAssertEqual(size, [0, 0, 300, 40])
        XCTAssertEqual(try FormFixtures.drawn(form.document, widget), "text")
        assertArgumentException(try form.resize(widget, PdfRect(1, 1, 1, 1)))
    }

    func test_removingAFieldTakesItsWidgetsAndEmptyParents() throws {
        let form = try blank()
        try form.addField(FieldSpec(.text, "g.one", 0, box))
        try form.addField(FieldSpec(.text, "keep", 0, PdfRect(50, 600, 250, 620)))
        try form.addField(FieldSpec(.radio, "r", 0, PdfRect(50, 500, 64, 514), exportValue: "a"))
        try form.addWidget(try XCTUnwrap(form.find("r")), 0, PdfRect(80, 500, 94, 514), "b")

        try form.remove(try XCTUnwrap(form.find("g.one")))
        XCTAssertEqual(form.fields.map { $0.name }, ["keep", "r"])
        XCTAssertEqual(form.document.array(form.acroForm, "Fields")?.items.count, 2)

        try form.remove(try XCTUnwrap(form.find("r")).widgets[1])
        XCTAssertEqual(try XCTUnwrap(form.find("r")).widgets.count, 1)
        try form.remove(try XCTUnwrap(form.find("r")).widgets[0])
        XCTAssertNil(form.find("r"))
        XCTAssertEqual(form.document.array(form.document.pages[0].dictionary, "Annots")?.items.count, 1)
        XCTAssertEqual(PdfForm.read(try AnnotationFixtures.reopen(form.document)).fields.count, 1)
    }

    func test_renamingChangesTheFullNameAndMayMoveTheField() throws {
        let form = try blank()
        try form.addField(FieldSpec(.text, "old", 0, box, value: "v", defaultValue: "d"))
        try form.addField(FieldSpec(.text, "grp.a", 0, PdfRect(50, 650, 250, 670)))

        try form.rename(try XCTUnwrap(form.find("old")), "new")
        XCTAssertEqual(form.find("new")?.value, "v")
        XCTAssertNil(form.find("old"))

        try form.rename(try XCTUnwrap(form.find("new")), "grp.b")
        XCTAssertEqual(form.fields.map { $0.name }.sorted(), ["grp.a", "grp.b"])
        XCTAssertEqual(form.find("grp.b")?.defaultValue, "d")

        try form.rename(try XCTUnwrap(form.find("grp.a")), "solo")
        try form.rename(try XCTUnwrap(form.find("grp.b")), "solo2")
        XCTAssertEqual(form.fields.map { $0.name }.sorted(), ["solo", "solo2"])
        XCTAssertEqual(form.document.array(form.acroForm, "Fields")?.items.count, 2)
        XCTAssertThrowsError(try form.rename(try XCTUnwrap(form.find("solo")), "solo2")) { error in
            XCTAssertTrue(error is InvalidOperationException)
        }
        XCTAssertEqual(PdfForm.read(try AnnotationFixtures.reopen(form.document)).fields.map { $0.name }.sorted(), ["solo", "solo2"])
    }

    func test_flagsTooltipOptionsAndDefaultsCanBeChangedLater() throws {
        let form = try blank()
        try form.addField(FieldSpec(.comboBox, "c", 0, box, options: [FieldOption("a")]))
        var field = try XCTUnwrap(form.find("c"))

        try form.setFlag(field, .readOnly, true)
        try form.setFlag(try XCTUnwrap(form.find("c")), .required, true)
        form.setTooltip(try XCTUnwrap(form.find("c")), "pick one")
        try form.setOptions(try XCTUnwrap(form.find("c")), [FieldOption("a"), FieldOption("b", "Bee")])
        form.setDefaultValue(try XCTUnwrap(form.find("c")), "b")

        field = try XCTUnwrap(form.find("c"))
        XCTAssertTrue(field.has([.readOnly, .required, .combo]))
        XCTAssertEqual(field.tooltip, "pick one")
        XCTAssertEqual(field.options.count, 2)
        XCTAssertEqual(field.defaultValue, "b")
        try form.setFlag(field, .readOnly, false)
        XCTAssertFalse(try XCTUnwrap(form.find("c")).has(.readOnly))
        assertArgumentException(try form.setFlag(field, .radio, true))
        try form.reset()
        XCTAssertEqual(form.find("c")?.value, "b")
    }

    func test_turkishValuesOfNewFieldsUseAnEmbeddedFont() throws {
        let form = try blank(try AnnotationFixtures.ArialSource())

        let field = try form.addField(FieldSpec(.text, "tr", 0, box, value: "AİB ğA"))

        XCTAssertEqual(try FormFixtures.drawn(form.document, field.widgets[0]), "AİB ğA")
        try AnnotationFixtures.reopen(form.document)
    }

    func test_tabOrderFollowsRowsColumnsOrTheAnnotationList() throws {
        let form = try blank()
        try form.addField(FieldSpec(.text, "bottomLeft", 0, PdfRect(50, 100, 150, 120)))
        try form.addField(FieldSpec(.text, "topRight", 0, PdfRect(300, 400, 400, 420)))
        try form.addField(FieldSpec(.text, "topLeft", 0, PdfRect(50, 401, 150, 421)))
        try form.addField(FieldSpec(.text, "bottomRight", 0, PdfRect(300, 100, 400, 120)))
        func sequence() -> [String] { form.tabSequence(0).map { $0.field?.name ?? "" } }

        XCTAssertEqual(form.getTabOrder(0), .annotations)
        XCTAssertEqual(sequence(), ["bottomLeft", "topRight", "topLeft", "bottomRight"])

        form.setTabOrder(0, .row)
        XCTAssertEqual(sequence(), ["topLeft", "topRight", "bottomLeft", "bottomRight"])
        XCTAssertEqual(form.document.name(form.document.pages[0].dictionary, "Tabs"), "R")

        form.setTabOrder(0, .column)
        XCTAssertEqual(sequence(), ["topLeft", "bottomLeft", "topRight", "bottomRight"])

        let widgets = form.tabSequence(0)
        form.reorderWidgets(0, widgets.reversed())
        XCTAssertEqual(form.getTabOrder(0), .annotations)
        XCTAssertEqual(sequence(), ["bottomRight", "topRight", "bottomLeft", "topLeft"])
        let reopened = PdfForm.read(try AnnotationFixtures.reopen(form.document))
        XCTAssertEqual(reopened.tabSequence(0).map { $0.field?.name ?? "" }, ["bottomRight", "topRight", "bottomLeft", "topLeft"])
    }

    func test_authoringDropsAStaticXfaAndDynamicIsRefused() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [] /XFA [(template) 12 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        let form = PdfForm.read(try PdfDocument.open(pdf.finish()))

        assertReadFails(try form.addField(FieldSpec(.text, "x", 0, box)))
    }
}
